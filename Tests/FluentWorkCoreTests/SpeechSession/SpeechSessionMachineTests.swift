import Foundation
import Testing
@testable import FluentWorkCore

@Test func sessionStartTapFromIdleCreatesSessionEffect() {
    var state = SpeechSessionState.initial
    let effects = SpeechSessionMachine.reduce(&state, event: .sessionStartTap)

    #expect(state.phase == .connecting)
    #expect(effects.contains(.createSession))
    #expect(effects.contains(.trackTransition(from: .idle, to: .connecting, stage: nil)))
}

// MARK: - The readiness gate
//
// `.connecting` ended on `.socketReady` alone until 2026-09-20, so a session
// could open for talking in front of a microphone that had never produced a
// buffer. On device the tap delivered nothing for a whole 2.07s utterance and
// its first buffer landed 284ms after the first playback; the room said
// 「正在转写」 the whole time (`102_` §2–4). These pin the two facts as
// separate, both required, and order-independent.

@Test func socketReadyAloneLeavesConnectingWaitingForCapture() {
    var state = SpeechSessionState(phase: .connecting)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .connecting)
    #expect(state.socketReady == true)
    #expect(state.isReadyToSpeak == false)
    #expect(effects.isEmpty)
}

@Test func captureLiveAloneLeavesConnectingWaitingForSocket() {
    var state = SpeechSessionState(phase: .connecting)
    let effects = SpeechSessionMachine.reduce(&state, event: .captureLive)

    #expect(state.phase == .connecting)
    #expect(state.captureLive == true)
    #expect(state.isReadyToSpeak == false)
    #expect(effects.isEmpty)
}

@Test func socketReadyThenCaptureLiveOpensTheSession() {
    var state = SpeechSessionState(phase: .connecting)
    SpeechSessionMachine.reduce(&state, event: .socketReady)
    let effects = SpeechSessionMachine.reduce(&state, event: .captureLive)

    #expect(state.phase == .aiSpeaking)
    #expect(state.isReadyToSpeak == true)
    #expect(effects.contains(.trackTransition(from: .connecting, to: .aiSpeaking, stage: nil)))
}

/// The order is not part of the contract — a device can prove either half first,
/// and the tap's first buffer regularly arrives before the socket handshake
/// finishes. Only "both" is load-bearing.
@Test func captureLiveThenSocketReadyOpensTheSession() {
    var state = SpeechSessionState(phase: .connecting)
    SpeechSessionMachine.reduce(&state, event: .captureLive)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .aiSpeaking)
    #expect(state.isReadyToSpeak == true)
    #expect(effects.contains(.trackTransition(from: .connecting, to: .aiSpeaking, stage: nil)))
}

/// A new session re-proves both halves. Carrying either forward would let the
/// previous session's socket or microphone stand in for this one's, which is the
/// same silent-open bug one session later.
@Test func sessionStartTapClearsReadinessEvidence() {
    var state = SpeechSessionState(phase: .idle, socketReady: true, captureLive: true)
    SpeechSessionMachine.reduce(&state, event: .sessionStartTap)

    #expect(state.phase == .connecting)
    #expect(state.socketReady == false)
    #expect(state.captureLive == false)
    #expect(state.isReadyToSpeak == false)
}

/// A reconnect must not reopen the hole from the other side: the socket coming
/// back says nothing about the microphone.
@Test func reconnectWhileConnectingDoesNotSkipTheCaptureGate() {
    var state = SpeechSessionState(phase: .connecting, isReconnecting: true)
    SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .connecting)
    #expect(state.isReconnecting == false)
    #expect(state.socketReady == true)
}

@Test func duplicateCaptureLiveWhileActiveIsIdempotent() {
    var state = SpeechSessionState(phase: .aiSpeaking, socketReady: true, captureLive: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .captureLive)

    #expect(state.phase == .aiSpeaking)
    #expect(state.captureLive == true)
    #expect(effects.isEmpty)
}

@Test func duplicateSocketReadyWhileActiveIsIdempotent() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .aiSpeaking)
    #expect(state.isReconnecting == false)
    #expect(effects.isEmpty)
}

@Test func socketReadyWhileReconnectingFromAISpeakingDiscardsTurn() {
    var state = SpeechSessionState(phase: .aiSpeaking, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.trackTransition(from: .aiSpeaking, to: .waitingUser, stage: nil)))
}

/// The evaluation timer exists to stop a late badge from stranding the turn. It
/// says nothing about the audio, and the two run on unrelated clocks: assistant
/// speech arrives as one burst at turn end and takes as long to play as the
/// reply is long, while `evaluationWait` is a fixed 20s.
///
/// Ending the turn on that timer cut the tail off every reply longer than 20s.
/// Measured on a physical device: 276 frames (27.6s of audio) delivered in 88ms,
/// playback stopped 20.6s later — the 20s evaluation timeout, to the decimal.
///
/// The sibling branch proves which one is the odd one out: a badge that arrives
/// in time (`evaluationReceived`) lands in the same phase *without* stopping
/// playback. And barge-in stops it on both paths that mean it — `vadSpeechStart`
/// / `holdStart` from this phase, and from `aiSpeaking` — so silence never
/// depended on the timer.
@Test func evaluationTimeoutEndsTheTurnWithoutCuttingPlayback() {
    var state = SpeechSessionState(phase: .processing, processingStage: .evaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .evaluationTimedOut)

    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.stopPlayback) == false)
}

/// VAD barge-in 只停本地播放，**不发** interrupt。
///
/// `.vadSpeechStart` 只由 `audioEventPump` 派发，而 pump 在派发它**之前**就已经同步
/// 发过 interrupt 了——必须早于 `user.speech.start`，否则网关会重置上一轮的 interrupt
/// 记账（2026-09-12 事故）。本事件是 start **之后**才派发的，所以从这里再发一次必定
/// 晚于 start，达不到目的。
///
/// 这条测试原先断言 `.sendInterrupt` **存在**，等于把那次重复钉成了契约。「一次
/// barge-in 只发一次、且在 start 之前」现在由接线级的
/// `bargeInFromTheVADPathSendsExactlyOneInterrupt` 钉住——它走的是真实 pump 路径，
/// 比这里的手工 reduce 更接近生产。
@Test func vadDuringAISpeakingStopsPlaybackWithoutASecondInterrupt() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)

    #expect(state.phase == .recording)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.sendInterrupt) == false)
}

/// `holdStart` 走的是另一条路：不经 pump，也没有配对的 `user.speech.start`，
/// 所以这条路上的 interrupt 是唯一的一次，必须留。
@Test func holdDuringAISpeakingStillSendsTheInterrupt() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .holdStart)

    #expect(state.phase == .recording)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.sendInterrupt))
}

/// `.waitingUser` 是第三条「用户开口时可能还有声音」的路径，它必须停播。
///
/// 徽章可以在回复音频**还在播**的时候到达：`.processing/.evaluation` 收到
/// `evaluationReceived` → `.waitingUser`（`SpeechSessionMachine.swift:81-83`），
/// 而那条路径**没有**停播——`:96-99` 的注释自己承认「Next utterance may overlap
/// leftover TTS after ai.turn.end」。
///
/// 只停播、**不发 interrupt**：`ai.turn.end` 已经到了，服务端这一轮已结束，没有
/// 可打断的流；剩下的是已到达客户端、排在播放器里的音频，那是本地的事。这与
/// `.evaluation` 那条 arm 的政策一致（`:161-166` 同样只有 `.stopPlayback`）。
///
/// 这条测试原先不存在——`.waitingUser` 的 effects 从来没被断言过，这正是它
/// 能一直不停播的原因。
@Test func vadFromWaitingUserStopsLeftoverPlayback() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)

    #expect(state.phase == .recording)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.sendInterrupt) == false)
}

/// `aiAnswer` 与 `waitingUser` **前提不同**，不能共用一条 arm。
///
/// `aiAnswer` 只有一条来路：`(.recording, .recordingTimedOut)`（`SpeechSessionMachine
/// .swift:174-187`，`state.processingStage = .aiAnswer` 全仓唯一写入点）。而
/// `.recording` 只从「可能有声在播」的相位进入，每个这样的入口都带 `.stopPlayback`
/// （`.aiSpeaking` 的两条 arm、`.waitingUser` 的两条 arm、`.processing/.evaluation`
/// 的两条 arm）。所以停在 `aiAnswer` 时，上一轮的声音已经清过了。
///
/// 本轮的声音也还没到：`aiAnswer` 里若收到 `aiFirstAudioChunk` 就会升到
/// `.aiSpeaking`（`:234-236`），所以还停在 `aiAnswer` 意味着首块音频尚未到达。
/// `SpeechSessionState.discardsTurnOnReconnect`（`SpeechSessionState.swift:257`）
/// 用的是同一个判断——`processingStage != .aiAnswer` 才丢弃在途轮次。
///
/// 这条把「不该停」也钉住，免得将来有人为了修 `waitingUser` 把 `.stopPlayback`
/// 顺手加到整条合并 arm 上，而多停一次没有测试会响。
@Test func abortLandingPadHasNothingLeftToStop() {
    var state = SpeechSessionState(phase: .processing, processingStage: .aiAnswer)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)

    #expect(state.phase == .recording)
    // 相位变了，所以 `trackTransition` 一定在（`SpeechSessionMachine.swift:342-357`）。
    // 断言的是「没有第二个效果」，不是「effects 为空」。
    #expect(effects.contains(.stopPlayback) == false)
    #expect(effects.contains(.sendInterrupt) == false)
}

@Test func vadSpeechEndMovesRecordingToProcessingASR() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
    #expect(state.userTurnCount == 1)
}

/// The ASR → LLM hop advances the pipeline **without changing phase**.
///
/// Before the merge these were two phases and the hop was a transition. It is
/// now a stage change inside one phase — which is the whole point of the
/// convergence, and also the reason the transition effect has to carry the
/// stage: with `from == to`, `stage` is the only thing that says it moved.
@Test func serverASRReceivedAdvancesThePipelineFromASRToLLM() {
    var state = SpeechSessionState(phase: .processing, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(
        &state,
        event: .serverASRReceived(text: "hello", turnID: "turn-1")
    )

    #expect(state.phase == .processing)
    #expect(state.processingStage == .llm)
    // The advance is still reported, as a stage move rather than a phase hop.
    #expect(
        effects.contains(.trackTransition(from: .processing, to: .processing, stage: .llm))
    )
}

/// The stage guard is what keeps a hop legal from the step it is legal from.
/// The phase alone can no longer say where the pipeline is, so an out-of-order
/// event must be a no-op rather than a silent jump.
@Test func pipelineHopsAreRejectedFromTheWrongStage() {
    // `.review` is reached from `.llm`, never straight from `.asr`.
    var fromASR = SpeechSessionState(phase: .processing, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(&fromASR, event: .processingStageReached(.review))
    #expect(fromASR.processingStage == .asr)
    #expect(effects.isEmpty)

    // `.llm` is reached from `.asr`; re-delivering it from `.llm` is a no-op.
    var fromLLM = SpeechSessionState(phase: .processing, processingStage: .llm)
    let repeatEffects = SpeechSessionMachine.reduce(&fromLLM, event: .processingStageReached(.llm))
    #expect(fromLLM.processingStage == .llm)
    #expect(repeatEffects.isEmpty)
}

@Test func aiFirstAudioChunkMovesProcessingASRToAISpeaking() {
    var state = SpeechSessionState(phase: .processing, processingStage: .asr)
    _ = SpeechSessionMachine.reduce(&state, event: .aiFirstAudioChunk)
    #expect(state.phase == .aiSpeaking)
}

@Test func networkDegradedEntersDegradedTextImmediately() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkDegraded)

    #expect(state.phase == .degradedText)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .degradedText, stage: nil)))
}

@Test func networkLostStartsReconnectWindowWithoutLeavingPhase() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkLost)

    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting)
    #expect(effects.contains(.startReconnectWindow))
}

@Test func reconnectTimeoutEntersDegradedText() {
    var state = SpeechSessionState(phase: .waitingUser, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectTimedOut)

    #expect(state.phase == .degradedText)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .degradedText, stage: nil)))
}

@Test func systemInterruptSuspendsThenResumesToWaitingUser() {
    var state = SpeechSessionState(phase: .recording)
    let suspendEffects = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.phase == .recording)
    #expect(state.suspendedPhase == .recording)
    #expect(suspendEffects.contains(.stopPlayback))

    // Active events are ignored while suspended.
    let ignored = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.phase == .recording)
    #expect(state.suspendedPhase == .recording)
    #expect(ignored.isEmpty)

    let resumeEffects = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .waitingUser)
    #expect(state.suspendedPhase == nil)
    #expect(resumeEffects.contains(.trackTransition(from: .recording, to: .waitingUser, stage: nil)))
}

@Test func systemInterruptFromDegradedTextPreservesDegradedText() {
    var state = SpeechSessionState(phase: .degradedText)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .degradedText)

    _ = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .degradedText)
    #expect(state.suspendedPhase == nil)
}

@Test func systemInterruptEndedIsNoOpWithoutSuspend() {
    var state = SpeechSessionState(phase: .degradedText)
    let effects = SpeechSessionMachine.reduce(&state, event: .systemInterruptEnded)
    #expect(state.phase == .degradedText)
    #expect(effects.isEmpty)
}

@Test func forceCloseFromWaitingUserEndsSession() {
    var state = SpeechSessionState(phase: .waitingUser)
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .ended)
    #expect(state.isReconnecting == false)
    #expect(state.suspendedPhase == nil)
    #expect(effects.contains(.forceClose))
    #expect(effects.contains(.trackTransition(from: .waitingUser, to: .ended, stage: nil)))
}

@Test func forceCloseFromIdleIsNoOp() {
    var state = SpeechSessionState.initial
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .idle)
    #expect(effects.isEmpty)
}

@Test func forceCloseFromRemainingActivePhasesEndsSession() {
    let phases: [SpeechSessionPhase] = [
        .aiSpeaking,
        .waitingUser,
        .recording,
        .processing,
        .degradedText,
    ]
    for phase in phases {
        var state = SpeechSessionState(phase: phase)
        let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
        #expect(state.phase == .ended, "expected ended from \(phase)")
        #expect(state.isReconnecting == false, "expected reconnect cleared from \(phase)")
        #expect(state.suspendedPhase == nil, "expected suspend cleared from \(phase)")
        #expect(effects.contains(.forceClose), "expected forceClose effect from \(phase)")
    }
}

@Test func forceCloseWhileSuspendedEndsSession() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)
    #expect(state.phase == .ended)
    #expect(state.suspendedPhase == nil)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.forceClose))
}

@Test func speechSessionPhaseIsActiveMatchesLivePhases() {
    #expect(SpeechSessionPhase.connecting.isActive)
    #expect(SpeechSessionPhase.waitingUser.isActive)
    #expect(SpeechSessionPhase.processing.isActive)
    #expect(!SpeechSessionPhase.idle.isActive)
    #expect(!SpeechSessionPhase.ended.isActive)
    #expect(!SpeechSessionPhase.failed.isActive)
}

/// 结束练习确认框挂在只在 live 相位存在的按钮上时，`.ended` 会拆掉呈现者，
/// `isPresented` 留在 true。下一场 `connecting` 的按钮一出现，框就再弹一次。
/// Host 必须在相位离开 live 时把 flag **写回 false**，不能只靠计算属性。
@Test func endSessionConfirmationDoesNotResurfaceOnTheNextLivePhase() {
    #expect(SpeechSessionPhase.aiSpeaking.presentingEndSessionConfirmation(true))
    #expect(!SpeechSessionPhase.aiSpeaking.presentingEndSessionConfirmation(false))

    var presented = true
    presented = SpeechSessionPhase.ended.presentingEndSessionConfirmation(presented)
    #expect(!presented)

    presented = SpeechSessionPhase.connecting.presentingEndSessionConfirmation(presented)
    #expect(!presented)

    #expect(!SpeechSessionPhase.idle.presentingEndSessionConfirmation(true))
    #expect(!SpeechSessionPhase.failed.presentingEndSessionConfirmation(true))
}

/// 2026-09-12 真机：confirmationDialog 挂在随 `.ended` 重建的 bottom bar 后面，
/// 会闪出第二个框再自动消失。合法挂点是封面内部、且包在相位相关 chrome *之前* 的房间 destination。
@Test func endSessionConfirmationDialogMustSitInsideTheCover() {
    #expect(!EndSessionConfirmationDialogSite.liveSessionButton.isValid)
    #expect(!EndSessionConfirmationDialogSite.fullScreenCoverPresenter.isValid)
    #expect(EndSessionConfirmationDialogSite.speakingRoomDestination.isValid)
}

@Test func speechSessionPhaseLabelsCoverV20WaitsAndExistingStages() {
    // The evaluation wait and the abort landing pad are stages now. Their
    // cross-service tags must not change: the backend log is keyed on them.
    #expect(ProcessingStage.evaluation.stageTag == "waiting_for_evaluation")
    #expect(ProcessingStage.aiAnswer.stageTag == "waiting_for_ai_answer")
    #expect(!SpeechSessionPhase.waitingUser.isProcessing)
    #expect(SpeechSessionPhase.processing.isProcessing)

    let labels = Dictionary(uniqueKeysWithValues: SpeechSessionPhase.allCases.map { ($0, $0.label) })
    #expect(labels[.idle] == "idle")
    #expect(labels[.connecting] == "orchestration")
    #expect(labels[.waitingUser] == "waiting_user")
    #expect(labels[.recording] == "vad_capture")
    #expect(labels[.processing] == "processing")
    // The pipeline step is no longer a phase, so its cross-service tag
    // comes from the stage. These are the strings the three merged
    // phases used to emit, so backend log correlation is unchanged.
    #expect(ProcessingStage.asr.stageTag == "asr")
    #expect(ProcessingStage.llm.stageTag == "llm")
    #expect(ProcessingStage.review.stageTag == "review")
    #expect(ProcessingStage.allCases.count == 5)
    #expect(labels[.aiSpeaking] == "tts")
    #expect(labels[.degradedText] == "text_fallback")
    #expect(labels[.ended] == "ended")
    #expect(labels[.failed] == "failed")
    #expect(Set(labels.values).count == SpeechSessionPhase.allCases.count)
}

@Test func illegalCombinationsAreIgnored() {
    let cases: [(SpeechSessionPhase, SpeechSessionEvent)] = [
        (.idle, .socketReady),
        (.idle, .vadSpeechStart),
        (.failed, .socketReady),
        (.failed, .networkLost),
        (.ended, .sessionStartTap),
        (.processing, .vadSpeechStart),
        (.processing, .recordingTimedOut),
        (.waitingUser, .aiFirstAudioChunk),
    ]

    for (phase, event) in cases {
        var state = SpeechSessionState(phase: phase, failureReason: phase == .failed ? "x" : nil)
        let before = state
        let effects = SpeechSessionMachine.reduce(&state, event: event)
        #expect(state == before, "expected no-op for \(phase) + \(event)")
        #expect(effects.isEmpty, "expected no effects for \(phase) + \(event)")
    }
}

@Test func interruptRaceVadThenAITurnEndLeavesRecording() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    _ = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .recording)
    #expect(effects.isEmpty)
}

@Test func holdStartFromWaitingUserStartsRecording() {
    var state = SpeechSessionState(phase: .waitingUser)
    _ = SpeechSessionMachine.reduce(&state, event: .holdStart)
    #expect(state.phase == .recording)

    _ = SpeechSessionMachine.reduce(&state, event: .holdEnd(turnID: nil))
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
}

@Test func aiTurnEndHappyPathGreetingReturnsToWaitingUser() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.trackTransition(from: .aiSpeaking, to: .waitingUser, stage: nil)))
}

@Test func aiTurnEndAfterUserTurnEntersTheEvaluationStage() {
    var state = SpeechSessionState(phase: .aiSpeaking, userTurnCount: 1)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .evaluation)
    #expect(effects.contains(.trackTransition(from: .aiSpeaking, to: .processing, stage: .evaluation)))
}

/// From `.processing` the turn ends **in place**: the phase stays, only the
/// stage moves to the scorer. Previously this was a phase hop out to
/// `waitingForEvaluation`, which is what let a backend timer own a phase.
@Test func aiTurnEndFromProcessingMovesToTheEvaluationStageInPlace() {
    var state = SpeechSessionState(phase: .processing, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(&state, event: .aiTurnEnd)

    #expect(state.phase == .processing)
    #expect(state.processingStage == .evaluation)
    #expect(effects.contains(.trackTransition(from: .processing, to: .processing, stage: .evaluation)))
}

@Test func processingStageReachedMovesLLMToReview() {
    var state = SpeechSessionState(phase: .processing, processingStage: .llm)
    _ = SpeechSessionMachine.reduce(&state, event: .processingStageReached(.review))
    #expect(state.phase == .processing)
    #expect(state.processingStage == .review)
}

@Test func socketReadyWhileReconnectingFromProcessingDiscardsTurn() {
    var state = SpeechSessionState(phase: .processing, isReconnecting: true, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)

    #expect(state.phase == .waitingUser)
    #expect(state.processingStage == nil)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.trackTransition(from: .processing, to: .waitingUser, stage: nil)))
}

@Test func duplicateSocketReadyWhileProcessingWithoutReconnectIsIdempotent() {
    var state = SpeechSessionState(phase: .processing, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(&state, event: .socketReady)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
    #expect(effects.isEmpty)
}

@Test func processingTimeoutsUseCompileTimeDefaults() {
    let timeouts = ProcessingTimeouts.standard
    #expect(timeouts.asr == .seconds(15))
    #expect(timeouts.llm == .seconds(45))
    #expect(timeouts.review == .seconds(30))
    #expect(timeouts.totalCap == .seconds(70))
    #expect(timeouts.evaluationWait == .seconds(20))
}

@Test func recordingTimedOutAbortsTurnWithoutFailingSession() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)

    #expect(state.phase == .processing)
    #expect(state.processingStage == .aiAnswer)
    #expect(state.userTurnCount == 1)
    #expect(state.lastTurnOutcome == .timeout)
    #expect(state.failureReason == nil)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
    #expect(effects.contains(.trackTransition(from: .recording, to: .processing, stage: .aiAnswer)))
    #expect(!effects.contains(.turnTimeoutExpired))
    #expect(!effects.contains(.endSession))
}

@Test func recordingTimedOutWhileSuspendedStillAbortsTurn() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .interruptedBySystem)
    #expect(state.suspendedPhase == .recording)

    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .aiAnswer)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
}

@Test func recordingTimedOutFromWaitingUserIsNoOp() {
    var state = SpeechSessionState(phase: .waitingUser)
    let before = state
    let effects = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state == before)
    #expect(effects.isEmpty)
}

@Test func vadSpeechEndAfterRecordingDoesNotSendTurnAbort() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechEnd(turnID: nil))
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
    #expect(state.lastTurnOutcome == .ok)
    #expect(!effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .timeout)))
}

@Test func holdEndAfterRecordingRecordsOkOutcome() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .holdEnd(turnID: nil))
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
    #expect(state.lastTurnOutcome == .ok)
    #expect(effects.allSatisfy {
        if case .sendTurnAbort = $0 { return false }
        return true
    })
}

@Test func endTapFromRecordingAbortsAsUserAbandoned() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)

    #expect(state.phase == .ended)
    #expect(state.lastTurnOutcome == .userAbandoned)
    #expect(state.userTurnCount == 1)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .userAbandoned)))
    #expect(effects.contains(.endSession))
}

@Test func forceCloseFromRecordingAbortsAsUserAbandoned() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .forceClose)

    #expect(state.phase == .ended)
    #expect(state.lastTurnOutcome == .userAbandoned)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .userAbandoned)))
    #expect(effects.contains(.forceClose))
}

@Test func failedFromRecordingAbortsAsError() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .failed("network"))

    #expect(state.phase == .failed)
    #expect(state.lastTurnOutcome == .error)
    #expect(state.failureReason == "network")
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
    #expect(effects.contains(.endSession))
}

@Test func networkLostFromRecordingAbortsAsErrorAndLeavesRecording() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkLost)

    #expect(state.phase == .waitingUser)
    #expect(state.lastTurnOutcome == .error)
    #expect(state.isReconnecting)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
    #expect(effects.contains(.startReconnectWindow))
}

@Test func networkDegradedFromRecordingAbortsAsError() {
    var state = SpeechSessionState(phase: .recording)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkDegraded)

    #expect(state.phase == .degradedText)
    #expect(state.lastTurnOutcome == .error)
    #expect(effects.contains(.sendTurnAbort(turnID: "turn-1", outcome: .error)))
}

@Test func turnOutcomeRawValuesMatchWireContract() {
    #expect(TurnOutcome.ok.rawValue == "ok")
    #expect(TurnOutcome.timeout.rawValue == "timeout")
    #expect(TurnOutcome.userAbandoned.rawValue == "user_abandoned")
    #expect(TurnOutcome.error.rawValue == "error")
}

@Test func reconnectSucceededClearsReconnectFlag() {
    var state = SpeechSessionState(phase: .waitingUser, isReconnecting: true)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectSucceeded)
    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting == false)
    #expect(effects.isEmpty)
}

@Test func failedEventCapturesReason() {
    var state = SpeechSessionState(phase: .connecting)
    let effects = SpeechSessionMachine.reduce(&state, event: .failed("网络错误"))
    #expect(state.phase == .failed)
    #expect(state.failureReason == "网络错误")
    #expect(effects.contains(.trackTransition(from: .connecting, to: .failed, stage: nil)))
    #expect(effects.contains(.endSession))
}

@Test func degradedTextLoopKeepsPhaseOnSendAndReply() {
    var state = SpeechSessionState(phase: .degradedText)
    let sendEffects = SpeechSessionMachine.reduce(&state, event: .textMessageSent)
    #expect(state.phase == .degradedText)
    #expect(sendEffects.contains(.sendTextMessage))

    let replyEffects = SpeechSessionMachine.reduce(&state, event: .textReplyReceived)
    #expect(state.phase == .degradedText)
    #expect(replyEffects.isEmpty)
}

@Test func aiAnswerStageAcceptsNextUtterance() {
    var state = SpeechSessionState(phase: .recording)
    _ = SpeechSessionMachine.reduce(&state, event: .recordingTimedOut)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .aiAnswer)

    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)
    #expect(effects.contains(.trackTransition(from: .processing, to: .recording, stage: nil)))
}

@Test func aiAnswerStageEndTapEndsSession() {
    var state = SpeechSessionState(phase: .processing, processingStage: .aiAnswer)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.phase == .ended)
    #expect(effects.contains(.endSession))
    #expect(effects.contains(.trackTransition(from: .processing, to: .ended, stage: nil)))
}

@Test func evaluationReceivedLeavesTheEvaluationStage() {
    var state = SpeechSessionState(phase: .processing, processingStage: .evaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .evaluationReceived)
    #expect(state.phase == .waitingUser)
    #expect(effects.contains(.trackTransition(from: .processing, to: .waitingUser, stage: nil)))
}

@Test func evaluationStageEndTapEndsSession() {
    var state = SpeechSessionState(phase: .processing, processingStage: .evaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .endTap)
    #expect(state.phase == .ended)
    #expect(effects.contains(.endSession))
}

/// 结束练习确认框打开时只暂停 TTS，不结束会话。取消要能继续听。
/// `interruptNow` / `.stopPlayback` 会倒掉队列，取消后接不上。
@Test func endSessionConfirmShownPausesPlaybackWithoutEndingTheSession() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    let effects = SpeechSessionMachine.reduce(&state, event: .endSessionConfirmShown)
    #expect(state.phase == .aiSpeaking)
    #expect(effects.contains(.pausePlayback))
    #expect(!effects.contains(.endSession))
    #expect(!effects.contains(.stopPlayback))
}

@Test func endSessionConfirmCancelledResumesPlayback() {
    var state = SpeechSessionState(phase: .aiSpeaking)
    _ = SpeechSessionMachine.reduce(&state, event: .endSessionConfirmShown)
    let effects = SpeechSessionMachine.reduce(&state, event: .endSessionConfirmCancelled)
    #expect(state.phase == .aiSpeaking)
    #expect(effects.contains(.resumePlayback))
    #expect(!effects.contains(.endSession))
}

@Test func endSessionConfirmShownFromIdleIsIgnored() {
    var state = SpeechSessionState.initial
    let effects = SpeechSessionMachine.reduce(&state, event: .endSessionConfirmShown)
    #expect(state == SpeechSessionState.initial)
    #expect(effects.isEmpty)
}

@Test func evaluationStageVadStartsNextTurn() {
    var state = SpeechSessionState(phase: .processing, processingStage: .evaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .vadSpeechStart)
    #expect(state.phase == .recording)
    #expect(effects.contains(.stopPlayback))
    #expect(effects.contains(.trackTransition(from: .processing, to: .recording, stage: nil)))
}

@Test func evaluationTimedOutReturnsToWaitingUserWithoutFailing() {
    var state = SpeechSessionState(phase: .processing, processingStage: .evaluation)
    let effects = SpeechSessionMachine.reduce(&state, event: .evaluationTimedOut)
    #expect(state.phase == .waitingUser)
    #expect(state.failureReason == nil)
    #expect(effects.contains(.trackTransition(from: .processing, to: .waitingUser, stage: nil)))
    #expect(!effects.contains(.endSession))

    // This used to assert `.stopPlayback`, under the reasoning that "leftover
    // TTS is dropped" once the badge is late. That contract does not hold: the
    // timer is a fixed 20s and the audio is as long as the reply, so the
    // "leftover" was un-played speech — measured on device, 276 frames (27.6s)
    // delivered in 88ms and playback killed 20.6s later.
    // See `evaluationTimeoutEndsTheTurnWithoutCuttingPlayback`.
    #expect(effects.contains(.stopPlayback) == false)
}

@Test func evaluationTimedOutFromWaitingUserIsNoOp() {
    var state = SpeechSessionState(phase: .waitingUser)
    let before = state
    let effects = SpeechSessionMachine.reduce(&state, event: .evaluationTimedOut)
    #expect(state == before)
    #expect(effects.isEmpty)
}

@Test func networkLostFromProcessingKeepsPhaseAndStopsPlayback() {
    var state = SpeechSessionState(phase: .processing, processingStage: .asr)
    let effects = SpeechSessionMachine.reduce(&state, event: .networkLost)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .asr)
    #expect(state.isReconnecting)
    #expect(effects.contains(.startReconnectWindow))
    #expect(effects.contains(.stopPlayback))
}

@Test func reconnectSucceededFromProcessingDiscardsTurn() {
    var state = SpeechSessionState(phase: .processing, isReconnecting: true, processingStage: .llm)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectSucceeded)
    #expect(state.phase == .waitingUser)
    #expect(state.isReconnecting == false)
    #expect(effects.contains(.stopPlayback))
}

@Test func reconnectSucceededFromTheAbortLandingPadKeepsIt() {
    var state = SpeechSessionState(phase: .processing, isReconnecting: true, processingStage: .aiAnswer)
    let effects = SpeechSessionMachine.reduce(&state, event: .reconnectSucceeded)
    #expect(state.phase == .processing)
    #expect(state.processingStage == .aiAnswer)
    #expect(state.isReconnecting == false)
    #expect(!effects.contains(.stopPlayback))
}

/// The reconnect-discard policy is **stage-aware**, and that is the whole
/// reason it stopped being a phase property.
///
/// Before the merge the two things it separates had phases of their own: an
/// evaluation wait discards the turn, an abort landing pad does not. Merged
/// into one phase, the distinction has nowhere else to live — and getting it
/// wrong is not cosmetic: stopping playback on `aiAnswer` cuts off an answer
/// the user is still owed.
@Test func reconnectDiscardPolicySeparatesThePipelineFromTheAbortPad() {
    // Pipeline stages and the evaluation wait belong to a turn that will not
    // be replayed.
    #expect(SpeechSessionState(phase: .processing, processingStage: .asr).discardsTurnOnReconnect)
    #expect(SpeechSessionState(phase: .processing, processingStage: .llm).discardsTurnOnReconnect)
    #expect(SpeechSessionState(phase: .processing, processingStage: .review).discardsTurnOnReconnect)
    #expect(SpeechSessionState(phase: .processing, processingStage: .evaluation).discardsTurnOnReconnect)
    #expect(SpeechSessionState(phase: .aiSpeaking).discardsTurnOnReconnect)

    // I21's abort landing pad does not: the user already abandoned that turn,
    // so there is nothing left to discard and its answer is still coming.
    #expect(!SpeechSessionState(phase: .processing, processingStage: .aiAnswer).discardsTurnOnReconnect)
    #expect(!SpeechSessionState(phase: .waitingUser).discardsTurnOnReconnect)
    #expect(!SpeechSessionState(phase: .recording).discardsTurnOnReconnect)
}

@Test func isValidTransitionAcceptsLiveGraphAndRejectsIllegalHops() {
    #expect(SpeechSessionMachine.isValidTransition(from: .idle, to: .connecting))
    #expect(SpeechSessionMachine.isValidTransition(from: .waitingUser, to: .recording))
    #expect(SpeechSessionMachine.isValidTransition(from: .recording, to: .processing))
    #expect(SpeechSessionMachine.isValidTransition(from: .processing, to: .aiSpeaking))
    // A finished turn now *enters* `.processing` for its evaluation stage, and
    // the abort landing pad is reached from `.recording` the same way.
    #expect(SpeechSessionMachine.isValidTransition(from: .aiSpeaking, to: .processing))
    #expect(SpeechSessionMachine.isValidTransition(from: .processing, to: .ended))
    #expect(SpeechSessionMachine.isValidTransition(from: .processing, to: .waitingUser))
    #expect(SpeechSessionMachine.isValidTransition(from: .processing, to: .ended))
    #expect(!SpeechSessionMachine.isValidTransition(from: .idle, to: .aiSpeaking))
    #expect(!SpeechSessionMachine.isValidTransition(from: .processing, to: .idle))
    #expect(!SpeechSessionMachine.isValidTransition(from: .ended, to: .waitingUser))
    #expect(!SpeechSessionMachine.isValidTransition(from: .idle, to: .idle))
}

// MARK: - Phase / stage invariant (P1-3)

/// `processingStage` is non-nil **exactly** while `phase == .processing`.
///
/// This is the invariant the convergence rests on. Before it, the stage was a
/// *derived* shadow of the phase and could not disagree with it; now the stage
/// is data, so nothing but this guard stops the two drifting apart — and drift
/// is what would make a stale stage outlive its phase and mislabel the room.
///
/// Driven through a real event sequence rather than asserted on hand-built
/// states: the drift this catches is produced by the reducer's branches, and a
/// hand-built state would only ever test the initializer.
@Test func processingStageIsNonNilExactlyWhileProcessing() {
    var state = SpeechSessionState.initial
    func assertInvariant(_ label: String) {
        let holds = (state.phase == .processing) == (state.processingStage != nil)
        #expect(holds, "phase/stage drifted after \(label): \(state.phase)/\(String(describing: state.processingStage))")
    }
    assertInvariant("initial")

    // Every exit from `.processing` has to be in here. The first version of
    // this script only left via `.aiFirstAudioChunk`, and a mutation that left
    // the stage set on the `.aiTurnEnd` exit — the drift this test exists to
    // catch — passed it. A guard that does not reach the branch it guards is
    // the hollow kind.
    let script: [(String, SpeechSessionEvent)] = [
        ("sessionStartTap", .sessionStartTap),
        ("socketReady", .socketReady),
        ("vadSpeechStart", .vadSpeechStart),
        ("vadSpeechEnd", .vadSpeechEnd(turnID: "turn-1")),
        // Exit 1: pipeline advances, then the turn ends from `.processing`.
        ("serverASRReceived", .serverASRReceived(text: "hello", turnID: "turn-1")),
        ("processingStageReached(.review)", .processingStageReached(.review)),
        ("aiTurnEnd from .processing", .aiTurnEnd),
        ("evaluationReceived", .evaluationReceived),
        // Exit 2: first audio leaves `.processing` for `.aiSpeaking`.
        ("vadSpeechStart#2", .vadSpeechStart),
        ("vadSpeechEnd#2", .vadSpeechEnd(turnID: "turn-2")),
        ("aiFirstAudioChunk", .aiFirstAudioChunk),
        ("aiTurnEnd#2", .aiTurnEnd),
        ("evaluationTimedOut", .evaluationTimedOut),
        ("vadSpeechStart#3", .vadSpeechStart),
        ("vadSpeechEnd#3", .vadSpeechEnd(turnID: "turn-3")),
        // Exit 3: leave `.processing` through the reconnect path.
        ("networkLost", .networkLost),
        ("socketReady while reconnecting", .socketReady),
        // Exit 4: the recording cap aborts the turn and lands on the `aiAnswer`
        // pad — the branch where the stage was being overwritten by the abort
        // helper.
        //
        // Reaching it takes `vadSpeechStart` *from `waitingUser`*: an earlier
        // version of this script stepped through `degradedText` first, where
        // `vadSpeechStart` is a no-op, so it never got back to `.recording`
        // and the branch was never entered. A "walk some events" guard silently
        // covers only the branches the walk happens to reach.
        ("vadSpeechStart#4", .vadSpeechStart),
        ("recordingTimedOut from .recording", .recordingTimedOut),
        // Exit 5: back out of the abort pad into a fresh turn, then degrade.
        ("vadSpeechStart#5", .vadSpeechStart),
        ("vadSpeechEnd#5", .vadSpeechEnd(turnID: "turn-5")),
        ("networkDegraded from .processing", .networkDegraded),
        ("endTap", .endTap),
    ]

    for (label, event) in script {
        _ = SpeechSessionMachine.reduce(&state, event: event)
        assertInvariant(label)
    }
}
