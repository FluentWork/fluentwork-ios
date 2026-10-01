import Foundation
import FluentWorkNetworking

public enum DrillRoundMachine {
    @discardableResult
    public static func reduce(
        _ state: inout DrillRoundState,
        event: DrillRoundEvent
    ) -> [DrillRoundEffect] {
        switch (state.phase, event) {
        case (.idle, .start(let size)):
            state.policy.roundSize = size
            state.phase = .loading
            return [.fetchRound(size: size)]

        case (.loading, .roundLoaded(let round)):
            guard !round.cards.isEmpty else {
                state.planned = 0
                state.position = 0
                state.current = nil
                state.queue = []
                state.phase = .empty
                return []
            }
            state.planned = round.cards.count
            state.position = 1
            state.current = DrillPrompt(card: round.cards[0])
            state.queue = round.cards.dropFirst().map(DrillPrompt.init(card:))
            state.phase = .ready
            return [.scheduleReadiness(seconds: state.policy.readinessSeconds)]

        case (.loading, .roundLoadFailed(let message)):
            state.phase = .failed(message: message)
            return [.cancelTimers]

        case (.ready, .readinessElapsed(let date)):
            state.readinessEndedAt = date
            state.phase = .answering
            // 两件事一起发，顺序说明了它们的关系：**采集是正路，定时器是兜底**。
            // 「作答 5 秒从开始录音起算」＋「response_ms 计时起点是准备期结束」这两句
            // 只有在这里同时成立 —— 录音就是在准备期结束那一刻开始的。
            return [
                .captureAnswer(seconds: state.policy.answerSeconds),
                .scheduleAnswerDeadline(seconds: state.policy.answerSeconds),
            ]

        case (.answering, .answerCaptured(let text, let date)):
            return submit(&state, asrText: text, at: date)

        case (.answering, .answerDeadlineReached):
            return submit(&state, asrText: "", responseMS: deadlineMS(state))

        case (.ready, .skipTapped(let date)):
            requeueCurrent(&state)
            return submit(&state, asrText: "", at: date)

        case (.answering, .skipTapped(let date)):
            requeueCurrent(&state)
            return submit(&state, asrText: "", at: date)

        case (.judging, .verdictReceived(let verdict)):
            state.lastVerdict = verdict
            state.phase = .verdict
            if verdict.judged {
                if verdict.pass {
                    state.passedAttempts += 1
                    state.unresolved.remove(verdictBlockID(state))
                } else {
                    state.unresolved.insert(verdictBlockID(state))
                    requeueCurrent(&state)
                }
            }
            if verdict.promoted {
                state.automatedDelta += 1
            }
            return [.cancelTimers]

        case (.judging, .attemptFailed(let message)):
            state.phase = .failed(message: message)
            return [.cancelTimers, .stopListening]

        case (.verdict, .retryTapped) where state.awaitingConfirmation:
            guard let submission = state.lastSubmission else { return [] }
            state.phase = .judging
            return [
                .submitAttempt(
                    blockID: submission.blockID,
                    asrText: submission.asrText,
                    responseMS: submission.responseMS
                )
            ]

        case (.verdict, .advanceTapped):
            guard !state.queue.isEmpty else {
                state.phase = .settled
                // 这一轮问完了：把采集的认领还回去（与第一次 `captureAnswer` 成对）。
                return [.stopListening]
            }
            state.current = state.queue.removeFirst()
            state.position += 1
            state.lastVerdict = nil
            state.lastAppeal = nil
            state.lastSubmission = nil
            state.readinessEndedAt = nil
            state.phase = .ready
            return [.scheduleReadiness(seconds: state.policy.readinessSeconds)]

        case (.verdict, .appealTapped):
            guard state.canAppeal, let verdict = state.lastVerdict else { return [] }
            return [.appeal(recordID: verdict.recordID)]

        case (.verdict, .appealResolved(let outcome)):
            guard !outcome.alreadyAppealed else { return [] }
            state.lastAppeal = outcome
            guard outcome.restored else { return [] }
            undoAttempt(&state, blockID: outcome.blockID)
            return []

        case (_, .exitTapped) where state.phase != .idle:
            state.phase = .idle
            state.current = nil
            state.queue = []
            state.lastVerdict = nil
            state.lastAppeal = nil
            state.lastSubmission = nil
            state.readinessEndedAt = nil
            return [.cancelTimers, .stopListening]

        default:
            return []
        }
    }

    private static func verdictBlockID(_ state: DrillRoundState) -> String {
        state.lastSubmission?.blockID ?? state.current?.blockID ?? ""
    }

    private static func deadlineMS(_ state: DrillRoundState) -> Int {
        Int((state.policy.answerSeconds * 1000).rounded())
    }

    private static func elapsedMS(_ state: DrillRoundState, at date: Date) -> Int? {
        guard let start = state.readinessEndedAt else { return nil }
        return max(0, Int((date.timeIntervalSince(start) * 1000).rounded()))
    }

    private static func submit(
        _ state: inout DrillRoundState,
        asrText: String,
        at date: Date
    ) -> [DrillRoundEffect] {
        let responseMS = elapsedMS(state, at: date) ?? 0
        return submit(&state, asrText: asrText, responseMS: responseMS)
    }

    private static func submit(
        _ state: inout DrillRoundState,
        asrText: String,
        responseMS: Int
    ) -> [DrillRoundEffect] {
        guard let prompt = state.current else { return [] }
        let submission = DrillSubmission(
            blockID: prompt.blockID,
            asrText: asrText,
            responseMS: responseMS
        )
        state.lastSubmission = submission
        state.answeredAttempts += 1
        state.phase = .judging
        return [
            .submitAttempt(
                blockID: submission.blockID,
                asrText: submission.asrText,
                responseMS: submission.responseMS
            )
        ]
    }

    private static func requeueCurrent(_ state: inout DrillRoundState) {
        guard let prompt = state.current else { return }
        let used = state.requeues[prompt.blockID, default: 0]
        guard used < state.policy.maxRequeuesPerCard else { return }
        state.requeues[prompt.blockID] = used + 1
        state.queue.append(prompt)
    }

    private static func undoAttempt(_ state: inout DrillRoundState, blockID: String) {
        if let verdict = state.lastVerdict {
            if verdict.pass {
                state.passedAttempts = max(0, state.passedAttempts - 1)
            }
            if verdict.promoted {
                state.automatedDelta = max(0, state.automatedDelta - 1)
            }
        }
        state.unresolved.remove(blockID)
        if let index = state.queue.firstIndex(where: { $0.blockID == blockID }),
            state.requeues[blockID, default: 0] > 0
        {
            state.queue.remove(at: index)
            state.requeues[blockID] = state.requeues[blockID, default: 0] - 1
        }
    }
}
