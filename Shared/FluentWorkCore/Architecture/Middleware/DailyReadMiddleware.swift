import FactoryKit
import FluentWorkNetworking
import Foundation
import os
import TGReduxKit

/// Polling interval for the pending-status case. Backend typically finishes within
/// a few seconds; we keep the cadence low to avoid hammering the service while still
/// surfacing the ready state promptly.
private let dailyReadPollInterval: Duration = .seconds(3)

/// Total number of polling attempts before we surface a fallback to the preset content.
private let dailyReadMaxPollAttempts = 20

/// Middleware that bridges daily-read actions to the network: loads today's daily
/// read (with polling for the pending case), drives AI 朗读 playback, and submits
/// follow-read attempts.
///
/// V1.1 guard: this middleware never reads or forwards `read_score` — the I10 hard
/// constraint is that follow-read never displays scoring in the MVP.
public func dailyReadMiddleware(container: Container) -> Middleware<AppState, AppAction> {
  return { store, action, next in
    guard case .dailyRead(let dailyReadAction) = action else {
      return next(action)
    }

    let client = container.dailyReadClient()
    let audioPlayer = container.dailyReadAudioPlayer()
    let cacheStore = container.dailyReadCacheStore()

    switch dailyReadAction {
    case .loadTriggered:
      let scope = cacheScope(for: store.state)
      let base = next(action)
      let dispatchBox = DailyReadDispatchBox(dispatch: { store.dispatch($0) })
      return .merge(
        base,
        .task(id: AppTaskID.dailyReadHydrate) {
          do {
            let snapshot = try await cacheStore.loadSnapshot(scope: scope)
            guard !Task.isCancelled else { return nil }
            return .dailyRead(.hydrateFromCache(snapshot))
          } catch is CancellationError {
            return nil
          } catch {
            guard !Task.isCancelled else { return nil }
            return .dailyRead(.hydrateFromCache(nil))
          }
        },
        .task(id: AppTaskID.dailyReadLoad) {
          await pollDailyReadUntilReady(
            client: client,
            cacheStore: cacheStore,
            scope: scope,
            dispatchBox: dispatchBox
          )
        }
      )

    case .playTapped:
      guard let audioURL = store.state.dailyRead.dailyRead?.audioURL,
        let url = URL(string: audioURL),
        !audioURL.isEmpty,
        store.state.dailyRead.audioPhase != .playing
      else {
        return next(action)
      }
      let base = next(action)
      return .merge(
        base,
        .task(id: AppTaskID.dailyReadAudio) {
          do {
            try await audioPlayer.load(url: url)
            await audioPlayer.play()
            return .dailyRead(.audioPlaybackStarted)
          } catch {
            guard !Task.isCancelled else { return nil }
            return .dailyRead(.audioFailed(dailyReadErrorMessage(error)))
          }
        }
      )

    case .pauseTapped:
      guard store.state.dailyRead.audioPhase == .playing else {
        return next(action)
      }
      let base = next(action)
      return .merge(
        base,
        .task(id: AppTaskID.dailyReadAudio) {
          await audioPlayer.pause()
          return .dailyRead(.audioPaused)
        }
      )

    case .followReadSubmitted:
      guard let dailyReadID = store.state.dailyRead.dailyRead?.id,
        !dailyReadID.isEmpty,
        store.state.dailyRead.followReadPhase == .recording
      else {
        return next(action)
      }
      let base = next(action)
      return .merge(
        base,
        .task(id: AppTaskID.dailyReadFollowRead) {
          do {
            _ = try await client.submitFollowRead(
              dailyReadID: dailyReadID,
              audioURL: nil
            )
            guard !Task.isCancelled else { return nil }
            return .dailyRead(.followReadSucceeded)
          } catch is CancellationError {
            return nil
          } catch {
            guard !Task.isCancelled else { return nil }
            return .dailyRead(.followReadFailed(dailyReadErrorMessage(error)))
          }
        }
      )

    default:
      return next(action)
    }
  }
}

/// Pumps `DailyReadAudioPlayer` events back into the Redux store.
///
/// The observer task starts when the middleware is constructed (the first
/// action that flows through it). This keeps the player latched to the store
/// for the lifetime of the process and avoids depending on a single-shot
/// trigger like `.appLaunched`.
public func dailyReadAudioObserver(container: Container) -> Middleware<AppState, AppAction> {
  let audioPlayer = container.dailyReadAudioPlayer()
  let tracker = container.tracker()
  let startedBox = ObserverStartedBox()

  return { store, action, next in
    let base = next(action)

    guard startedBox.tryMarkStarted() else { return base }
    let dispatchBox = DailyReadDispatchBox(dispatch: { store.dispatch($0) })

    return .merge(
      base,
      .task(id: AppTaskID.dailyReadAudioObserver) {
        for await event in audioPlayer.events() {
          guard !Task.isCancelled else { return nil }
          switch event {
          case .playbackTimeUpdated(let time):
            await dispatchBox.dispatch(.dailyRead(.playbackTimeUpdated(time)))
          case .durationLoaded(let duration):
            await dispatchBox.dispatch(.dailyRead(.audioDurationLoaded(duration)))
          case .finished:
            await dispatchBox.dispatch(.dailyRead(.audioFinished))
          case .failed(let message):
            // 播放失败**要留痕**，不能只到屏幕（评审 R10 的同一条纪律）。
            // origin 把「每日一读的播放器」与「说的房间的音频栈」分开：
            // 两者的 message 形状很像，事后读日志时唯一的区别就是这一维。
            //
            // detail 用**屏幕上看的那一句**：两份不同的文案会各自漂移，
            // 而这里要的是「事后能读到用户当时看到了什么」。
            tracker.track(
              event: "dailyRead_audio_failed",
              properties: ["origin": "dailyRead.audio", "detail": message]
            )
            await dispatchBox.dispatch(.dailyRead(.audioFailed(message)))
          }
        }
        return nil
      }
    )
  }
}

/// One-shot guard for the audio observer middleware.
///
/// `OSAllocatedUnfairLock` replaces the former `NSLock` — sync calls
/// keep the existing `Middleware` contract happy and read more cleanly
/// than manual `lock()` / `defer { unlock() }` pairs.
/// `tryMarkStarted()` is atomic so two middleware entries cannot both
/// observe "not started" and launch a second observer task.
/// - Note: `internal` for unit testing.
internal final class ObserverStartedBox: Sendable {
  private let storage = OSAllocatedUnfairLock<Bool>(initialState: false)

  func isStarted() -> Bool { storage.withLock { $0 } }

  /// Returns true only for the first caller. Later calls return false.
  @discardableResult
  func tryMarkStarted() -> Bool {
    storage.withLock {
      if $0 { return false }
      $0 = true
      return true
    }
  }
}

private func pollDailyReadUntilReady(
  client: DailyReadClientProtocol,
  cacheStore: DailyReadCacheStoreProtocol,
  scope: String,
  dispatchBox: DailyReadDispatchBox
) async -> AppAction? {
  for attempt in 0..<dailyReadMaxPollAttempts {
    do {
      let response = try await client.loadToday()
      guard !Task.isCancelled else { return nil }
      switch response.status {
      case .pending:
        guard attempt < dailyReadMaxPollAttempts - 1 else {
          // Out of polling budget — apply final response so reducer falls back
          // to preset content (status is still pending but cap reached).
          return .dailyRead(.applyResponse(response))
        }
        try? await Task.sleep(for: dailyReadPollInterval)
        guard !Task.isCancelled else { return nil }
        continue
      case .ready:
        // 存快照的时机与语料库一致：在加载 task 里、成功动作回派之前。
        // `genDate` 一起存，所以下次离线时屏幕上写的日期是这份内容自己的日期。
        //
        // 缓存写失败不许让加载失败：内容是真的、马上就要上屏，缓存的全部价值只是
        // 让下一次进来好看一点；磁盘满了不应该把能看的列表变成错误页。
        if let dailyRead = response.dailyRead {
          try? await cacheStore.saveSnapshot(
            CachedDailyReadSnapshot(genDate: response.genDate, dailyRead: dailyRead),
            scope: scope
          )
        }
        return .dailyRead(.applyResponse(response))
      case .failed:
        return .dailyRead(.applyResponse(response))
      }
    } catch is CancellationError {
      return nil
    } catch {
      guard !Task.isCancelled else { return nil }
      return .dailyRead(.loadFailed(dailyReadErrorMessage(error)))
    }
  }
  return nil
}

/// Bridges `@MainActor` store dispatch into a `@Sendable` task.
final class DailyReadDispatchBox: @unchecked Sendable {
  private let dispatch: @MainActor (AppAction) -> Void

  init(dispatch: @escaping @MainActor (AppAction) -> Void) {
    self.dispatch = dispatch
  }

  func dispatch(_ action: AppAction) async {
    await dispatch(action)
  }
}

/// 失败说人话。**不把 `localizedDescription` 端上去**。
///
/// 加载 / 播放 / 跟读提交三个失败点**共用一句**：具体是哪一步没说清由屏幕的相位去说
/// （它本来就在说），这句话要负责的是「学员能做什么」。
func dailyReadErrorMessage(_ error: Error) -> String {
  if let apiError = error as? APIError {
    switch apiError {
    case .network:
      return "网络没连上，每日一读暂时用不了，请稍后重试。"
    case .decoding:
      return "每日一读这次没能完成，请稍后再试。"
    case let .backend(_, message) where !message.isEmpty:
      // 服务端自己给的话原样转达（与 `accountAuthErrorMessage` 同一条规矩）。
      return message
    default:
      break
    }
  }
  return "每日一读这次没能完成，请稍后再试。"
}
