import Foundation
import FluentWorkNetworking
import TGReduxKit

// MARK: - Turn timeline (design 22: A 回合时间线 + B 二段式反馈)

public enum TurnTimelineSpeaker: String, Equatable, Sendable {
    case user
    case ai
}

public enum TurnTimelineItemStatus: String, Equatable, Sendable {
    /// User turn opened but authoritative server ASR has not arrived yet.
    case listening
    case streaming
    case finalized
}

public struct BadgeHitRef: Equatable, Sendable, Hashable {
    public let badge: String
    public let phraseBlockID: String?
    public let tier: BadgeFeedEntry.Tier

    public init(badge: String, phraseBlockID: String?, tier: BadgeFeedEntry.Tier) {
        self.badge = badge
        self.phraseBlockID = phraseBlockID
        self.tier = tier
    }
}

public struct TurnTimelineItem: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var turnID: String?
    public let speaker: TurnTimelineSpeaker
    public var text: String
    public var status: TurnTimelineItemStatus
    public var hits: [BadgeHitRef]

    public init(
        id: UUID = UUID(),
        turnID: String?,
        speaker: TurnTimelineSpeaker,
        text: String,
        status: TurnTimelineItemStatus,
        hits: [BadgeHitRef] = []
    ) {
        self.id = id
        self.turnID = turnID
        self.speaker = speaker
        self.text = text
        self.status = status
        self.hits = hits
    }

    /// One turn of a *stored* transcript, rendered into the same timeline.
    ///
    /// `status` is `.finalized` because it is: these turns came off the server
    /// having been written down, so there is nothing still arriving and nothing
    /// to show as listening. `turnID` stays nil — these turns have no live turn
    /// to be correlated with, and inventing one would let a badge land on a
    /// conversation from last week.
    public init(utterance: SessionUtterance) {
        self.init(
            turnID: nil,
            speaker: utterance.speaker == "user" ? .user : .ai,
            text: utterance.text,
            status: .finalized
        )
    }
}

public struct SpeakingRoomState: Equatable, Sendable, State {
    public var session: SpeechSessionState
    public var liveTranscript: String
    public var isBootstrapReady: Bool
    public var lastBadge: String?
    public var badgeHits: Int
    /// Session bound by the active `DefaultSpeechSessionClient`, captured on
    /// session end so the UI can navigate to that session's review page.
    public var lastSessionID: String?
    /// In-session turn timeline (design 22). Display-only; never enters the
    /// SpeechSession machine.
    public var timeline: [TurnTimelineItem]
    /// The past session this room was entered to continue, if any.
    ///
    /// It belongs to the **room entry**, not to the session: it is written when
    /// the room opens and overwritten by the next entry (nil for a plain one),
    /// which is why nothing "consumes" it. A one-shot flag would have to be
    /// cleared at exactly the right moment, and the moment it would have to be
    /// cleared — a successful session start — is the one thing that can fail.
    ///
    /// It is an id, not context. The server decides whether the transcript
    /// behind it may be read (`77_` P0-10), and the client never sees it.
    public var continueFromSessionID: String?

    public var phase: SpeechSessionPhase { session.phase }
    /// Which backend pipeline step is running, while `phase == .processing`.
    /// The phase alone no longer distinguishes them.
    public var processingStage: ProcessingStage? { session.processingStage }
    public var failureReason: String? { session.failureReason }

    public init(
        session: SpeechSessionState = .initial,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        lastSessionID: String? = nil,
        timeline: [TurnTimelineItem] = [],
        continueFromSessionID: String? = nil
    ) {
        self.session = session
        self.liveTranscript = liveTranscript
        self.isBootstrapReady = isBootstrapReady
        self.lastBadge = lastBadge
        self.badgeHits = badgeHits
        self.lastSessionID = lastSessionID
        self.timeline = timeline
        self.continueFromSessionID = continueFromSessionID
    }

    /// Test / Host helper mirroring the previous phase-centric initializer.
    ///
    /// `processingStage` is separate because `.processing` does not imply which
    /// pipeline step — a caller that wants the room to look like it is in the
    /// LLM stage has to say so.
    public init(
        phase: SpeechSessionPhase,
        processingStage: ProcessingStage? = nil,
        liveTranscript: String = "",
        isBootstrapReady: Bool = false,
        lastBadge: String? = nil,
        badgeHits: Int = 0,
        failureReason: String? = nil,
        lastSessionID: String? = nil,
        timeline: [TurnTimelineItem] = [],
        continueFromSessionID: String? = nil
    ) {
        self.init(
            session: SpeechSessionState(
                phase: phase,
                failureReason: failureReason,
                processingStage: processingStage
            ),
            liveTranscript: liveTranscript,
            isBootstrapReady: isBootstrapReady,
            lastBadge: lastBadge,
            badgeHits: badgeHits,
            lastSessionID: lastSessionID,
            timeline: timeline,
            continueFromSessionID: continueFromSessionID
        )
    }
}

public enum SpeakingRoomAction: Equatable, Sendable, Action {
    /// Domain event for the pure SpeechSession machine (Middleware-owned).
    case session(SpeechSessionEvent)
    /// State snapshot applied after Middleware runs the machine.
    case applySession(SpeechSessionState)
    /// The room was opened.
    ///
    /// `continueFrom` names a past session to carry into the next one — nil for
    /// an ordinary entry, which is what every entry except the list's 继续
    /// button is. `seeding` is that session's transcript, already loaded by the
    /// screen the user came from; passing it in beats re-fetching it, because
    /// the fetch already happened to draw the page they tapped the button on.
    case enterRoom(continueFrom: String?, seeding: [SessionUtterance] = [])
    /// I20 Item 4: tap-to-talk. Middleware asks the engine to emit speech boundaries.
    case manualSpeechBegin
    case manualSpeechEnd
    /// Display-only — must not enter SpeechSessionMachine (§2.2 badgeHit).
    ///
    /// Carries the optional B12 enrichment (`phraseBlockID`, `tier`, `turnID`)
    /// so the cross-cutting reducer can mirror the hit into `badgeFeedback`
    /// with the same `turnID` the backend used for dedupe. Tests + the host
    /// debug screen still pass just a badge string; the optional fields
    /// default to `nil`.
    case badgeHit(
        badge: String,
        phraseBlockID: String? = nil,
        tier: BadgeFeedEntry.Tier? = nil,
        turnID: String? = nil
    )
    /// User speech ended; opens a "我正在听…" timeline item until server ASR
    /// replaces it (design 22 resolved decision).
    case userTurnStarted(turnID: String?)
    /// Incremental assistant text from `ai.text.delta`.
    case aiTurnTextDelta(text: String, turnID: String?)
    /// `ai.turn.end` received — finalize the assistant timeline item.
    case aiTurnFinalized(turnID: String?)
    /// Captures the session id bound by the speech client right before the
    /// transport closes, so the ended-state UI can offer "查看回顾".
    case sessionIDCaptured(String)
    case bootstrapReady(Bool)
    /// Local transcript overlay text; does not drive the session phase machine.
    case userSpeechCaptured(String)
    /// B14: Server-side ASR transcript received via WSS relay from the voice provider.
    /// When this arrives, the middleware immediately calls `sendSpeechBoundary`
    /// with the authoritative server text (for badge hit detection) and dispatches
    /// this action so the reducer updates `liveTranscript` for display.
    case serverASRReceived(text: String, turnID: String?)
    /// B15: ai.turn.end received with explicit backend outcome. When outcome is
    /// .timeout, the middleware dispatches .failed("turn_timeout") to match the
    /// 70s client-side fallback behavior. Nil outcome means pre-B15 protocol.
    /// B15-I3: log_id carries the vendor trace log_id for cross-layer correlation.
    case aiTurnEndReceived(turnID: String?, outcome: WSControlFrame.TurnOutcome?, logID: String?)
}

public let speakingRoomReducer: Reducer<SpeakingRoomState, SpeakingRoomAction> = { state, action in
    switch action {
    case .session:
        // Interpreted by `speechSessionMiddleware`; reducer ignores raw events.
        break

    case .manualSpeechBegin, .manualSpeechEnd:
        break

    case let .enterRoom(continueFrom, seeding):
        // A room entry only happens when nothing is running — the room is a
        // full-screen cover, so there is no way to reach the list from inside a
        // live session. Which means an entry arriving *during* one is SwiftUI
        // re-firing `onAppear` for the sheet already on screen, and the one
        // thing it must not do is wipe the conversation the user is in the
        // middle of. This guard is what makes `onAppear` safe to make
        // destructive, and it is why the entry — not the session start — is
        // allowed to clear anything at all.
        guard state.session.phase == .idle
            || state.session.phase == .ended
            || state.session.phase == .failed
        else {
            return
        }

        state.continueFromSessionID = continueFrom
        state.liveTranscript = ""
        state.lastBadge = nil
        state.badgeHits = 0
        state.timeline = seeding.map(TurnTimelineItem.init(utterance:))
        // A visit does not inherit the last one's *session*.
        //
        // `lastSessionID` and the machine snapshot used to survive a room
        // entry, so entering from the workbench after an earlier visit showed
        // "本轮已结束，重新开始" for a session that was over — and the id of a
        // session the user had already left was still lying around to be used
        // as a continuation origin.
        state.session = .initial
        state.lastSessionID = nil

    case let .applySession(session):
        // Deliberately does **not** clear the timeline when the session enters
        // `.connecting`. It used to, and that is the whole of what the user
        // reported as 「点击重新开始，前面的内容都没有了」: "start" and "start
        // over" were the same event, so the only way to begin a turn after a
        // session ended was to lose the session. Clearing belongs to the room
        // entry (`.enterRoom`), which is where the user actually chooses
        // between continuing something and starting fresh (`79_` §设计 3).
        state.session = session

    case let .badgeHit(badge, phraseBlockID, tier, turnID):
        state.lastBadge = badge
        state.badgeHits += 1
        guard !badge.isEmpty else { return }
        let hit = BadgeHitRef(
            badge: badge,
            phraseBlockID: phraseBlockID,
            tier: tier ?? .unknown
        )
        let index = state.timeline.indices.reversed().first(where: { idx in
            let item = state.timeline[idx]
            guard item.speaker == .user else { return false }
            if let turnID, let itemTurnID = item.turnID, itemTurnID != turnID {
                return false
            }
            return true
        }) ?? state.timeline.indices.reversed().first(where: {
            state.timeline[$0].speaker == .user
        })
        if let index {
            if !state.timeline[index].hits.contains(where: {
                $0.badge == hit.badge && $0.phraseBlockID == hit.phraseBlockID
            }) {
                state.timeline[index].hits.append(hit)
            }
        }

    case let .userTurnStarted(turnID):
        state.timeline.append(
            TurnTimelineItem(
                turnID: turnID,
                speaker: .user,
                text: "我正在听…",
                status: .listening
            )
        )

    case let .aiTurnTextDelta(text, turnID):
        let delta = text.isEmpty ? "" : text
        if var last = state.timeline.last,
           last.speaker == .ai,
           last.status != .finalized {
            last.text += delta
            state.timeline[state.timeline.count - 1] = last
        } else {
            state.timeline.append(
                TurnTimelineItem(
                    turnID: turnID,
                    speaker: .ai,
                    text: delta,
                    status: .streaming
                )
            )
        }

    case let .aiTurnFinalized(turnID):
        guard let index = state.timeline.indices.last else { return }
        if state.timeline[index].speaker == .ai {
            state.timeline[index].status = .finalized
        }
        if state.timeline[index].turnID == nil, turnID != nil {
            state.timeline[index].turnID = turnID
        }

    case let .sessionIDCaptured(sessionID):
        state.lastSessionID = sessionID

    case let .bootstrapReady(isReady):
        state.isBootstrapReady = isReady

    case let .userSpeechCaptured(transcript):
        state.liveTranscript = transcript

    case let .serverASRReceived(text, turnID):
        state.liveTranscript = text
        // Replace the open "正在听…" placeholder with the authoritative
        // server transcript (matches by turnID when available, else last user).
        let exactMatch = state.timeline.indices.reversed().first(where: { idx in
            let item = state.timeline[idx]
            return item.speaker == .user
                && (turnID == nil || item.turnID == turnID)
        })
        let listeningFallback = state.timeline.indices.reversed().first(where: { idx in
            state.timeline[idx].speaker == .user
                && state.timeline[idx].status == .listening
        })
        if let index = exactMatch ?? listeningFallback {
            state.timeline[index].text = text
            state.timeline[index].status = .finalized
            state.timeline[index].turnID = state.timeline[index].turnID ?? turnID
        } else {
            state.timeline.append(
                TurnTimelineItem(
                    turnID: turnID,
                    speaker: .user,
                    text: text,
                    status: .finalized
                )
            )
        }

    // B15: aiTurnEndReceived is handled in SpeechSessionMiddleware (dispatches
    // .session(.aiTurnEnd) / .aiTurnFinalized when outcome != timeout). The
    // reducer just discards it — it has no display-side effect.
    case .aiTurnEndReceived:
        break
    }
}
