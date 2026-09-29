import FactoryKit
import Testing

@testable import FluentWorkCore

/// 测试进程**不该**往开发者真实的磁盘位置写。
///
/// 五个本地存储（语料库三件套 + 历史 / 每日一读两个缓存）在生产里是 JSON 落盘版；
/// 在测试进程里必须解析成内存版。少了这道判别，后果不是「多写一个文件」：
///
/// - 上一个测试存下的快照会被**下一个测试**读到 —— 实测症状是别的测试偶尔红。
///   2026-09-29 就是这么发现缺口的一例：`dailyReadMiddlewarePollsPendingUntilReady`
///   断言 `callCount == 3`，而 `phase == .ready` 在网络还没跑完时就已经成立，
///   因为前一个测试把 `daily-read-anonymous.json` 留在了真实的
///   `~/Library/Application Support/FluentWork/CorpusState/` 里；
/// - 反过来，测试也会**写脏开发者的机器**，而这些残留文件又会变成下一次的输入。
///
/// 这条钉的是**性质**（「测试进程里解析出来的必须是内存版」），不是某种具体写法 ——
/// 换判据、换实现类型都照样成立。与 `AudioEngineResolutionTests` 同一个形状。
@MainActor
@Test func testsResolveInMemoryStoresRatherThanDiskBackedOnes() {
    let container = Container()
    container.reset()

    #expect(
        container.corpusCacheStore() is InMemoryCorpusCacheStore,
        "语料库快照会写进开发者真实的 Application Support 目录"
    )
    #expect(
        container.corpusOutboxStore() is InMemoryCorpusOutboxStore,
        "语料库 outbox 会写进开发者真实的 Application Support 目录"
    )
    #expect(
        container.corpusSyncMetadataStore() is InMemoryCorpusSyncMetadataStore,
        "语料库同步元数据会写进开发者真实的 Application Support 目录"
    )
    #expect(
        container.sessionHistoryCacheStore() is InMemorySessionHistoryCacheStore,
        "历史快照会写进开发者真实的 Application Support 目录"
    )
    #expect(
        container.dailyReadCacheStore() is InMemoryDailyReadCacheStore,
        "每日一读快照会写进开发者真实的 Application Support 目录"
    )
}
