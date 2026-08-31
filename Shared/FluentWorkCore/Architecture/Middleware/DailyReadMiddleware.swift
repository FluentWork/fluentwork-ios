import FactoryKit
import FluentWorkNetworking
import Foundation
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
public func dailyReadMiddleware(container: Container? = nil) -> Middleware<AppState, AppAction> {
  let resolvedContainer = container ?? Container.shared

  return { store, action, next in
    guard case .dailyRead(let dailyReadAction) = action else {
      return next(action)
    }

    let client = resolvedContainer.dailyReadClient()
    let audioPlayer = resolvedContainer.dailyReadAudioPlayer()

    switch dailyReadAction {
    case .loadTriggered:
      let base = next(action)
      let dispatchBox = DailyReadDispatchBox(dispatch: { store.dispatch($0) })
      return .merge(
        base,
        .task(id: AppTaskID.dailyReadLoad) {
          await pollDailyReadUntilReady(
            client: client,
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
            return .dailyRead(.audioFailed(error.localizedDescription))
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
            return .dailyRead(.followReadFailed(error.localizedDescription))
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
public func dailyReadAudioObserver(container: Container? = nil) -> Middleware<AppState, AppAction> {
  let resolvedContainer = container ?? Container.shared
  let audioPlayer = resolvedContainer.dailyReadAudioPlayer()
  let startedBox = ObserverStartedBox()

  return { store, action, next in
    let base = next(action)

    guard !startedBox.isStarted() else { return base }

    startedBox.markStarted()
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
            await dispatchBox.dispatch(.dailyRead(.audioFailed(message)))
          }
        }
        return nil
      }
    )
  }
}

/// One-shot guard for the audio observer middleware.
private final class ObserverStartedBox: @unchecked Sendable {
  private let lock = NSLock()
  private var started = false

  func isStarted() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return started
  }

  func markStarted() {
    lock.lock()
    defer { lock.unlock() }
    started = true
  }
}

private func pollDailyReadUntilReady(
  client: DailyReadClientProtocol,
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
      case .ready, .failed:
        return .dailyRead(.applyResponse(response))
      }
    } catch is CancellationError {
      return nil
    } catch {
      guard !Task.isCancelled else { return nil }
      return .dailyRead(.loadFailed(error.localizedDescription))
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
