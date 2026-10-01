#if DEBUG
import Foundation

/// 转写替身：`FW_MOCK_ASR=<要说的话>`（多句用 `|` 分开）。
///
/// ## 为什么必须与 `FW_MOCK_MIC` 配对
///
/// `FW_MOCK_MIC` 喂的是 **1kHz 正弦**，Apple Speech 从正弦里转不出任何一个字。
/// 所以只有麦克风替身的时候，「闪测采集链路」**只能靠人对着手机说话验** ——
/// 而那正是 `MockAudioEngine` 当初要消掉的东西（人声每句不一样、环境噪声还会影响 VAD）。
///
/// 这一条把剩下那一半也替掉：采集是脚本化的音频，转写是脚本化的文本。
/// 于是「机器起采集 → 收一句话 → 转写 → 派 `.answerCaptured` → 提交判定」这条链
/// **无人值守**就能跑完。
///
/// ## 它不假装听懂
///
/// 它**完全不看 PCM** —— 这是刻意的：替身如果对音频做点什么（长度、能量），
/// 验出来的就是「替身的音频处理」而不是那条链。它按脚本一句一句地给，
/// 一句用一次，用完**停在最后一句**（重复出同一句，比突然返回空更好读：
/// 空会让 `.answerCaptured` 不被派，看起来像链路断了）。
public actor ScriptedClientASRTranscriber: ClientASRTranscriber {

    public struct Script: Sendable, Equatable {
        public var utterances: [String]

        public init(utterances: [String]) {
            self.utterances = utterances
        }

        /// 从环境变量读脚本。没设 `FW_MOCK_ASR` 就返回 `nil`（替身不生效）。
        public static func fromEnvironment(
            _ environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> Script? {
            guard let raw = environment["FW_MOCK_ASR"], !raw.isEmpty else { return nil }
            let parts =
                raw
                .split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            guard !parts.isEmpty else { return nil }
            return Script(utterances: parts)
        }
    }

    private let script: Script
    private var cursor = 0

    public init(script: Script) {
        self.script = script
    }

    public func transcribe(pcm: AsyncStream<Data>) async throws -> String {
        // 把音频**收干净再回答**。不收的话调用方那条流永远关不掉，
        // 而「谁负责关」会变成两处猜。收的动作本身不带任何判断。
        for await _ in pcm {}

        let index = min(cursor, script.utterances.count - 1)
        cursor = min(cursor + 1, script.utterances.count - 1)
        return script.utterances[index]
    }
}
#endif
