import Testing
import FluentWorkNetworking
import Foundation
@testable import FluentWorkCore

/// `RecordingSink` 的契约：协调器的「播/丢」决策靠它断言。
///
/// ## 这个文件删掉了什么（Stage 4）
///
/// 原先这里还有两个 `EngineAudioSink` 套件（PCM 缓冲构造、入队顺序）。那个 actor
/// 从 Stage 0 起就没有生产接线 —— 真正播放的是 `LiveAudioEngine` 自己，两份实现
/// 各有一份「PCM → AVAudioPCMBuffer → 入队」。删掉重复实现之后，缓冲不变量改由
/// 引擎自己的测试钉住（`LiveAudioEngineTests.playPCMScheduling*`）。
/// Stage 0 测试：验证 AudioSink 抽象的基本行为
///
/// 这些测试锁住从 LiveAudioEngine 迁移出来的核心不变量

final class ErrorBox: @unchecked Sendable {
    var message: String?
}

@Suite("AudioSink 抽象层")
struct AudioSinkTests {
    
    @Test("RecordingSink 记录所有播放调用")
    func recordingSinkCapturesAllCalls() async {
        let sink = RecordingSink()
        
        let pcm1 = Data([0x01, 0x02, 0x03, 0x04])
        let pcm2 = Data([0x05, 0x06])
        
        await sink.play(pcm: pcm1)
        await sink.play(pcm: pcm2)
        
        let calls = await sink.playCalls
        #expect(calls.count == 2)
        #expect(calls[0].pcm == pcm1)
        #expect(calls[1].pcm == pcm2)
        #expect(await sink.totalPCMBytes == 6)
    }
    
    @Test("RecordingSink 记录中断调用")
    func recordingSinkCapturesControlCalls() async {
        let sink = RecordingSink()

        await sink.interruptNow()
        await sink.interruptNow()

        #expect(await sink.interruptCount == 2)
    }
    
    @Test("RecordingSink 可以重置状态")
    func recordingSinkCanReset() async {
        let sink = RecordingSink()
        
        await sink.play(pcm: Data([0x01, 0x02]))
        await sink.interruptNow()
        
        #expect(await sink.playCalls.count == 1)
        #expect(await sink.interruptCount == 1)
        
        await sink.reset()
        
        #expect(await sink.playCalls.isEmpty)
        #expect(await sink.interruptCount == 0)
    }
}
