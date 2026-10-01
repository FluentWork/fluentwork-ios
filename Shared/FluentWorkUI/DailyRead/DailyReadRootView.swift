import SwiftUI

// MARK: - Phase

public enum DailyReadViewPhase: String, Equatable, Sendable {
  case idle
  case loading
  case ready
  case fallbackPreset
  case failed
}

// MARK: - Audio playback state

public enum DailyReadAudioViewPhase: String, Equatable, Sendable {
  case idle
  case loading
  case playing
  case paused
}

// MARK: - Follow-read state

public enum FollowReadViewPhase: Equatable, Sendable {
  case idle
  case recording
  case submitting
  case recorded
  case failed(String)
}

// MARK: - Article content model

public struct DailyReadArticle: Equatable, Sendable, Identifiable {
  public var id: String
  public var title: String
  public var body: String
  public var hasAudio: Bool
  public var sourceBlockCount: Int
  public var estimatedReadingSeconds: Int

  public init(
    id: String,
    title: String,
    body: String,
    hasAudio: Bool,
    sourceBlockCount: Int,
    estimatedReadingSeconds: Int
  ) {
    self.id = id
    self.title = title
    self.body = body
    self.hasAudio = hasAudio
    self.sourceBlockCount = sourceBlockCount
    self.estimatedReadingSeconds = estimatedReadingSeconds
  }
}

// MARK: - View model

public struct DailyReadViewModel: Equatable, Sendable {
  public var phase: DailyReadViewPhase
  public var article: DailyReadArticle?
  public var fallbackBody: String?
  public var genDate: String?
  public var audioPhase: DailyReadAudioViewPhase
  public var audioPlaybackTime: Double
  public var audioDuration: Double
  public var followReadPhase: FollowReadViewPhase
  public var hasFollowRead: Bool
  public var isOffline: Bool
  public var errorMessage: String?
  /// 该给学员盖骨架屏。
  ///
  /// **规则来自 `DailyReadState.showsSkeleton`，这里只做直通** —— 不再按视图相位重写一份。
  /// 它曾经是两份（Core 按状态相位、UI 按视图相位），那份等价只靠
  /// `generating → .loading` 这一条映射撑着，而两处都在长着一副「有东西在读我」的样子：
  /// UI 那一份**根本没人读**（视图当时直接 `case .idle, .loading` 走到了骨架屏）。
  public var showsSkeleton: Bool

  public init(
    phase: DailyReadViewPhase,
    article: DailyReadArticle? = nil,
    fallbackBody: String? = nil,
    genDate: String? = nil,
    audioPhase: DailyReadAudioViewPhase = .idle,
    audioPlaybackTime: Double = 0,
    audioDuration: Double = 0,
    followReadPhase: FollowReadViewPhase = .idle,
    hasFollowRead: Bool = false,
    isOffline: Bool = false,
    showsSkeleton: Bool = false,
    errorMessage: String? = nil
  ) {
    self.phase = phase
    self.article = article
    self.fallbackBody = fallbackBody
    self.genDate = genDate
    self.audioPhase = audioPhase
    self.audioPlaybackTime = audioPlaybackTime
    self.audioDuration = audioDuration
    self.followReadPhase = followReadPhase
    self.hasFollowRead = hasFollowRead
    self.isOffline = isOffline
    self.showsSkeleton = showsSkeleton
    self.errorMessage = errorMessage
  }

  /// V1.1 hard constraint: never surface a score on the UI side.
  public var displayScore: Double? { nil }
}

// MARK: - Root view

public struct DailyReadRootView: View {
  private let model: DailyReadViewModel
  private let onAppear: () -> Void
  private let onRetry: () -> Void
  private let onPlayTapped: () -> Void
  private let onPauseTapped: () -> Void
  private let onFollowReadStarted: () -> Void
  private let onFollowReadSubmitted: () -> Void

  public init(
    model: DailyReadViewModel,
    onAppear: @escaping () -> Void,
    onRetry: @escaping () -> Void = {},
    onPlayTapped: @escaping () -> Void = {},
    onPauseTapped: @escaping () -> Void = {},
    onFollowReadStarted: @escaping () -> Void = {},
    onFollowReadSubmitted: @escaping () -> Void = {}
  ) {
    self.model = model
    self.onAppear = onAppear
    self.onRetry = onRetry
    self.onPlayTapped = onPlayTapped
    self.onPauseTapped = onPauseTapped
    self.onFollowReadStarted = onFollowReadStarted
    self.onFollowReadSubmitted = onFollowReadSubmitted
  }

  public var body: some View {
    VStack(spacing: 0) {
      DailyReadOfflineBanner(isOffline: model.isOffline)

      ScrollView {
        content
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 16)
          .padding(.vertical, 12)
      }

      if shouldShowPlayerBar {
        DailyReadPlayerBar(
          audioPhase: model.audioPhase,
          playbackTime: model.audioPlaybackTime,
          duration: model.audioDuration,
          onPlayTapped: onPlayTapped,
          onPauseTapped: onPauseTapped
        )
      }
    }
    .navigationTitle("每日一读")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .task {
      onAppear()
    }
  }

  @ViewBuilder
  private var content: some View {
    // **「盖不盖骨架」由 state 的规则说了算**（`DailyReadState.showsSkeleton`，经投影直通）——
    // 不在这里按相位再判一次。以前这里是 `case .idle, .loading:`，那份判断与 Core 那条规则
    // 是同一条规则的两种写法，靠一条判据撑着相等。
    if model.showsSkeleton {
      DailyReadSkeletonView()
    } else {
      switch model.phase {
      case .failed:
        DailyReadFailedView(message: model.errorMessage, onRetry: onRetry)
      case .ready:
        if let article = model.article {
          DailyReadReadyArticleView(
            article: article,
            genDate: model.genDate,
            followReadPhase: model.followReadPhase,
            hasFollowRead: model.hasFollowRead,
            onFollowReadStarted: onFollowReadStarted,
            onFollowReadSubmitted: onFollowReadSubmitted
          )
        } else {
          DailyReadFallbackView(text: model.fallbackBody ?? "")
        }
      case .fallbackPreset:
        DailyReadFallbackView(text: model.fallbackBody ?? "")
      case .idle, .loading:
        // 走不到：那两档必然 `showsSkeleton`。留着是因为 `switch` 必须穷举 ——
        // 而它渲染的与上面同一件事（加载中 → 骨架），所以两支不会各说各话。
        DailyReadSkeletonView()
      }
    }
  }

  private var shouldShowPlayerBar: Bool {
    model.phase == .ready && model.article?.hasAudio == true
  }
}

// MARK: - Sub-views

private struct DailyReadOfflineBanner: View {
  let isOffline: Bool

  var body: some View {
    if isOffline {
      HStack(spacing: 8) {
        Image(systemName: "wifi.slash")
        Text("离线模式 · 显示本地缓存")
          .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 16)
      .padding(.vertical, 6)
      .background(Color.secondary.opacity(0.15))
      .foregroundStyle(.secondary)
    }
  }
}

private struct DailyReadSkeletonView: View {
  var body: some View {
    // **用共用组件**（稿子 §2.4：语料库 / 历史 / 每日一读 / 回顾统一用闪光骨架块）。
    // 此前是手写的 `Capsule` + `Color.secondary.opacity(0.15)`：既不会闪光，也绕过了令牌 ——
    // 四个页面各写一遍骨架，迟早会各长一个样。
    //
    // 形状照着这一屏将要出现的东西摆：先是一块标题，再是正文的行。
    VStack(alignment: .leading, spacing: DesignTokens.Spacing.s4) {
      SkeletonBlock(height: 22, widthRatio: 0.6)

      VStack(alignment: .leading, spacing: DesignTokens.Spacing.s3) {
        SkeletonBlock(height: 14)
        SkeletonBlock(height: 14, widthRatio: 0.92)
        SkeletonBlock(height: 14, widthRatio: 0.78)
      }

      Text("每日一读生成中...")
        .font(DesignTokens.Typography.caption)
        .foregroundStyle(DesignTokens.Color.textSecondary)
    }
  }
}

private struct DailyReadFailedView: View {
  let message: String?
  let onRetry: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("今日一读暂时不可用")
        .font(.headline)
      Text(message ?? "请稍后重试。")
        .foregroundStyle(.secondary)
      Button("重试") {
        onRetry()
      }
      .buttonStyle(.bordered)
    }
  }
}

private struct DailyReadFallbackView: View {
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("今日内容准备中")
        .font(.headline)
      Text(text)
        .font(.body)
        .foregroundStyle(.secondary)
    }
  }
}

private struct DailyReadReadyArticleView: View {
  let article: DailyReadArticle
  let genDate: String?
  let followReadPhase: FollowReadViewPhase
  let hasFollowRead: Bool
  let onFollowReadStarted: () -> Void
  let onFollowReadSubmitted: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(article.title)
          .font(.title3.bold())
        Spacer()
        if let genDate {
          Text(genDate)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      articleMeta

      Text(article.body)
        .font(.body)
        .lineSpacing(4)

      followReadSection
    }
  }

  private var articleMeta: some View {
    HStack(spacing: 8) {
      Image(systemName: "clock")
      Text("约 \(article.estimatedReadingSeconds) 秒")
      if article.sourceBlockCount > 0 {
        Text("·")
        Text("引用 \(article.sourceBlockCount) 个语料块")
      }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private var followReadSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("跟读练习")
        .font(.subheadline.bold())

      followReadStatusLine

      HStack(spacing: 12) {
        Button(followReadPhase == .recording ? "停止跟读" : "开始跟读") {
          if followReadPhase == .recording {
            onFollowReadSubmitted()
          } else {
            onFollowReadStarted()
          }
        }
        .buttonStyle(.borderedProminent)
        .disabled(
          hasFollowRead
            || followReadPhase == .submitting
            || followReadPhase == .recorded
        )

        if followReadPhase == .submitting {
          ProgressView()
        }
      }

      Text("MVP 跟读模式只录音与示范对比，不出分。")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.top, 8)
  }

  @ViewBuilder
  private var followReadStatusLine: some View {
    switch followReadPhase {
    case .idle:
      EmptyView()
    case .recording:
      Label("录音中...", systemImage: "mic.fill")
        .font(.caption)
        .foregroundStyle(.red)
    case .submitting:
      Label("正在提交...", systemImage: "arrow.up.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .recorded:
      Label("今日已跟读", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}

private struct DailyReadPlayerBar: View {
  let audioPhase: DailyReadAudioViewPhase
  let playbackTime: Double
  let duration: Double
  let onPlayTapped: () -> Void
  let onPauseTapped: () -> Void

  var body: some View {
    VStack(spacing: 8) {
      if duration > 0 {
        ProgressView(value: playbackTime, total: duration)
          .progressViewStyle(.linear)
      }

      HStack(spacing: 16) {
        audioActionButton

        Spacer()

        Text(audioStatusText)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(.thinMaterial)
  }

  @ViewBuilder
  private var audioActionButton: some View {
    switch audioPhase {
    case .idle, .paused:
      Button {
        onPlayTapped()
      } label: {
        Label("播放 AI 朗读", systemImage: "play.fill")
      }
      .buttonStyle(.borderedProminent)
    case .loading:
      ProgressView()
    case .playing:
      Button {
        onPauseTapped()
      } label: {
        Label("暂停", systemImage: "pause.fill")
      }
      .buttonStyle(.bordered)
    }
  }

  private var audioStatusText: String {
    switch audioPhase {
    case .idle: return "AI 朗读 · 0.8x / 1.0x / 1.2x"
    case .loading: return "加载音频中..."
    case .playing: return "播放中"
    case .paused: return "已暂停"
    }
  }
}

#if DEBUG
  extension DailyReadViewModel {
    public static let preview = DailyReadViewModel(
      phase: .ready,
      article: DailyReadArticle(
        id: "dr-preview",
        title: "一段可以直接用的 standup 汇报",
        body:
          "Yesterday I finished the cache warm-up; today I will start the eviction refactor and unblock the integration test pipeline.",
        hasAudio: true,
        sourceBlockCount: 3,
        estimatedReadingSeconds: 60
      ),
      genDate: "2026-09-01",
      audioPhase: .idle
    )

    public static let previewLoading = DailyReadViewModel(
      phase: .loading
    )

    public static let previewFallback = DailyReadViewModel(
      phase: .fallbackPreset,
      fallbackBody: "欢迎来到每日一读！今天的内容正在准备中。请稍后再来。"
    )

    public static let previewFailed = DailyReadViewModel(
      phase: .failed,
      errorMessage: "网络异常"
    )
  }
#endif
