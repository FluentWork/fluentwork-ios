import Foundation
import Testing

@testable import FluentWorkUI

/// 图标资产的守卫（F7）。
///
/// ## 要防的是什么
///
/// 图标有两份：稿子里的 `<symbol>`（设计权威）与 asset catalog 里的 SVG（编译真正吃进去的）。
/// 它们是**同一个东西的两个副本**，所以它们的漂移是**静默**的 —— 改一个坐标点，
/// 编译照样过、测试照样绿，只有肉眼看才发现图标不对。
///
/// 所以副本由 `Scripts/generate-icons.py` 生成，这里逐字比对：任何人手改 SVG、
/// 手抄一个图标、或往稿子里加图标却忘了同步，都会当场红。
///
/// ## 「哪些是 app 图标」是**推导**出来的，不是列出来的
///
/// 稿子里 29 个 `<symbol>` 在属性上分成干净的两类：
///
/// | | 属性 | 是什么 |
/// |---|---|---|
/// | 26 个 | `fill="none" stroke="currentColor" stroke-width="1.5"` | app 图标（线性描边） |
/// | 3 个 | `fill="currentColor"`、没有 `stroke` | 状态栏系统字形（实心） |
///
/// 判据用同一条推导。好处是**它不会过期**：一张硬编码的「这 3 个是系统字形」名单，
/// 在稿子换了一组字形之后不会说话；而推导 + 下面那条「实心符号恰好是这 3 个」的断言，
/// 既抓得住新增的实心符号（会多出来），也抓得住过期的（会少掉）。
///
/// 稿子只被解析一次（`Draft.symbols`），26 个图标共用结果。
@Suite struct IconAssetTests {

    // MARK: - 集合关系（三条，两两闭合）

    /// 代码声明的图标 ↔ 磁盘上的 imageset。**双向**。
    ///
    /// 单向只挡一半：只查「声明的都有文件」会漏掉仓里多出来的孤儿 imageset，
    /// 而那正是「生成器漏删」或「有人手工塞了一个」的样子。
    @Test func theDeclaredIconsAreExactlyTheImagesetsOnDisk() throws {
        let declared = Set(DesignTokens.Icon.allCases.map(\.rawValue))
        let onDisk = try Self.imagesetNames()

        #expect(
            declared.count >= 26,
            "只声明了 \(declared.count) 个图标 —— 反空洞下限是 26（稿子里的 app 图标数）"
        )
        #expect(
            onDisk.count >= 26,
            "只找到 \(onDisk.count) 个 imageset —— 扫描根或目录结构变了（守卫在看空气）"
        )

        let missing = declared.subtracting(onDisk).sorted()
        #expect(
            missing.isEmpty,
            """
            `DesignTokens.Icon` 声明了这些图标，但磁盘上没有对应的 imageset：
            \(missing.joined(separator: "\n"))
            跑 `Scripts/generate-icons.py`（不要手抄）。
            """
        )

        let orphans = onDisk.subtracting(declared).sorted()
        #expect(
            orphans.isEmpty,
            """
            磁盘上有这些 imageset，但没有 `DesignTokens.Icon` 指向它们：
            \(orphans.joined(separator: "\n"))
            要么稿子里已经没有它们了（重跑生成器会清掉），要么是手工塞进来的。
            """
        )
    }

    /// 代码声明的图标 ↔ 稿子里声明了描边的 `<symbol>`。**双向**。
    ///
    /// 这条把上面那条的另一端接到稿子上：磁盘 ↔ 代码、代码 ↔ 稿子
    /// ⇒ 磁盘 ↔ 稿子（第三条不单独断言，它是前两条的推论）。
    @Test func theDeclaredIconsAreExactlyTheDraftStrokedSymbols() throws {
        let declared = Set(DesignTokens.Icon.allCases.map(\.rawValue))
        let stroked = Set(Draft.symbols.filter { $0.attributes["stroke"] != nil }.map(\.id))

        #expect(stroked.count >= 26, "只从稿子里解析出 \(stroked.count) 个描边 symbol —— 解析器失配")

        let notShipped = stroked.subtracting(declared).sorted()
        #expect(
            notShipped.isEmpty,
            """
            稿子里这些描边 symbol 没有对应的 `DesignTokens.Icon`：
            \(notShipped.joined(separator: "\n"))
            往枚举里加一个 case，然后在视图里用 `DesignTokens.Icon.<case>` 而不是字符串。
            """
        )

        let notInDraft = declared.subtracting(stroked).sorted()
        #expect(
            notInDraft.isEmpty,
            """
            这些 `DesignTokens.Icon` case 在稿子里找不到对应的描边 symbol：
            \(notInDraft.joined(separator: "\n"))
            稿子换了图标集时，旧 case 要一起删掉。
            """
        )
    }

    /// 稿子里**实心**的 symbol 恰好是那 3 个状态栏系统字形。不多也不少。
    ///
    /// 这条是上面那条推导的前提。它同时封住两个方向：
    ///
    /// - 稿子新增一个实心 symbol ⇒ 不在名单里 ⇒ 红。**不能让它被静默跳过** ——
    ///   有些图标本来就是实心的，那要改的是推导规则，不是悄悄漏掉；
    /// - 名单里的某个消失了 ⇒ 红（过期条目就是一句谎话）。
    @Test func theDraftFilledSymbolsAreExactlyTheDocumentedSystemGlyphs() throws {
        let filled = Set(Draft.symbols.filter { $0.attributes["stroke"] == nil }.map(\.id))

        let documented: [String: String] = [
            "i-sig": "状态栏信号强度",
            "i-wifi": "状态栏 Wi-Fi",
            "i-batt": "状态栏电量",
        ]

        let unexpected = filled.subtracting(documented.keys).sorted()
        #expect(
            unexpected.isEmpty,
            """
            稿子里出现了没见过的实心 symbol：\(unexpected.joined(separator: ", "))
            如果它们其实是 app 图标，生成器「有 stroke 才是图标」这条推导就要改；
            如果确实是状态栏字形，把它们连同理由一起加进这个名单。
            """
        )

        let stale = Set(documented.keys).subtracting(filled).sorted()
        #expect(
            stale.isEmpty,
            """
            这个名单里有稿子中已不存在的 id，属于过期豁免，请删掉：
            \(stale.map { "\($0)（\(documented[$0]!)）" }.joined(separator: "\n"))
            """
        )
    }

    // MARK: - 几何逐字保真

    /// 磁盘上的 SVG 必须**逐字包含**稿子里那个 symbol 的内容。
    ///
    /// 故意用字面比对（`contains`），不做规范化 —— 规范化会自己引入一套解析，
    /// 而那正是「两个实现之间」最容易藏漂移的地方。生成器不重排内容，
    /// 所以字面比对成立；哪天要重排，就得同时改这里，那正是应该发生的对话。
    @Test func everyShippedIconReproducesItsDraftPathDataVerbatim() throws {
        let catalog = try Self.catalogDirectory()
        var checked = 0
        var failures: [String] = []

        for icon in DesignTokens.Icon.allCases {
            let svg = try Self.svg(for: icon, in: catalog)
            guard let symbol = Draft.symbols.first(where: { $0.id == icon.rawValue }) else {
                failures.append("\(icon.rawValue)：稿子里根本没有这个 symbol")
                continue
            }

            if !svg.contains(symbol.body) {
                failures.append(
                    """
                    \(icon.rawValue) 的几何数据与稿子不一致
                        磁盘上：\(svg)
                        稿子里：<symbol …>\(symbol.body)</symbol>
                    """
                )
            }
            checked += 1
        }

        #expect(
            failures.isEmpty,
            """
            这些图标与稿子不一致（重跑 `Scripts/generate-icons.py`，不要手改 SVG）：
            \(failures.joined(separator: "\n"))
            """
        )
        #expect(checked >= 26, "只比对了 \(checked) 个图标 —— 反空洞下限是 26")
    }

    /// 表现属性也要逐字带过来（几何一致但丢了 `stroke-linecap` 会被这条抓住）。
    ///
    /// 差异只允许生成器明说的那一处：`currentColor` → `#000`，
    /// 另加独立 SVG 必需的 `xmlns` / `width` / `height`。
    @Test func everyShippedIconCarriesTheDraftPresentationAttributes() throws {
        let catalog = try Self.catalogDirectory()
        var failures: [String] = []

        for icon in DesignTokens.Icon.allCases {
            let svg = try Self.svg(for: icon, in: catalog)
            guard let symbol = Draft.symbols.first(where: { $0.id == icon.rawValue }) else { continue }

            let carried = Self.attributes(inOpeningTagOf: svg)
            var expected = symbol.attributes
            expected.removeValue(forKey: "id")
            if expected["stroke"] == "currentColor" {
                expected["stroke"] = Self.templateStroke
            }

            let comparables = ["xmlns", "width", "height"]
            let missingAdditions = comparables.filter { carried[$0] == nil }
            if !missingAdditions.isEmpty {
                failures.append("\(icon.rawValue)：少了 \(missingAdditions.joined(separator: ", "))")
            }

            let comparable = carried.filter { !comparables.contains($0.key) }
            if comparable != expected {
                failures.append(
                    """
                    \(icon.rawValue) 的表现属性与稿子不一致
                        磁盘上：\(comparable.sorted { $0.key < $1.key })
                        稿子里：\(expected.sorted { $0.key < $1.key })
                    """
                )
            }
        }

        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    // MARK: - 资源本身要能被当模板用

    /// 每个 imageset 都要声明「保留矢量」+「当模板着色」。
    ///
    /// 少了前者，图标被放大时是位图拉伸（稿子给的是 24pt 线性描边，
    /// 描边宽度必须随尺寸线性变化才不糊）。少了后者，图标会是用 `#000` 画的死黑色 ——
    /// 而稿子里写的是 `currentColor`，语义是「跟随文字颜色」。
    @Test func everyImagesetIsATemplateVectorPreservingIcon() throws {
        let catalog = try Self.catalogDirectory()
        var checked = 0
        var failures: [String] = []

        for icon in DesignTokens.Icon.allCases {
            let contentsURL = catalog
                .appending(path: "\(icon.rawValue).imageset")
                .appending(path: "Contents.json")
            let data = try Data(contentsOf: contentsURL)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let properties = json["properties"] as? [String: Any],
                let images = json["images"] as? [[String: Any]]
            else {
                failures.append("\(icon.rawValue)：Contents.json 结构不对")
                continue
            }

            if properties["preserves-vector-representation"] as? Bool != true {
                failures.append("\(icon.rawValue)：没有打开 preserves-vector-representation（放大会糊）")
            }
            if properties["template-rendering-intent"] as? String != "template" {
                failures.append("\(icon.rawValue)：不是 template 渲染 —— 就不会跟随 foregroundStyle")
            }
            if !images.contains(where: { $0["filename"] as? String == "\(icon.rawValue).svg" }) {
                failures.append("\(icon.rawValue)：images 没有指向 \(icon.rawValue).svg")
            }
            checked += 1
        }

        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
        #expect(checked >= 26, "只检查了 \(checked) 个 imageset —— 反空洞下限是 26")
    }

    /// `currentColor` 是页面上下文里的关键字，离开稿子就没有意义。
    ///
    /// 它留在 SVG 里的后果不是报错，是**图标画不出来或画成怪颜色** ——
    /// 一个只在运行期、只在真机屏幕上出现的失败。
    @Test func noShippedIconLeavesAPageScopedColorKeywordBehind() throws {
        let catalog = try Self.catalogDirectory()
        var scanned = 0
        var offenders: [String] = []

        for icon in DesignTokens.Icon.allCases {
            if try Self.svg(for: icon, in: catalog).contains("currentColor") {
                offenders.append("\(icon.rawValue).svg")
            }
            scanned += 1
        }

        #expect(scanned >= 26, "只扫到 \(scanned) 个 SVG —— 守卫在看空气")
        #expect(
            offenders.isEmpty,
            """
            这些 SVG 里还留着 `currentColor`（稿子是 HTML 页面，这个值在那里才有意义）：
            \(offenders.joined(separator: "\n"))
            """
        )
    }

    /// 对照图也必须与 catalog 同源。
    ///
    /// `docs/design/icon-gallery.html` 是生成物，但它进仓 —— 而「进仓的生成物」在本项目里
    /// 一律由判据盯着（与上面那 7 条同一纪律）。
    ///
    /// ## 判法为什么是「删干净之后不许剩下 `<svg`」
    ///
    /// 第一版只断言「对照图包含每个图标」，而**变异没咬住**：对照图里每个图标出现 3 次
    /// （32pt 正文色 / 20pt 强调色 / 32pt 品牌色），手工改掉其中 1 份时，
    /// `contains` 在另外 2 份里照样找得到 `true`。
    ///
    /// 现在两面夹：
    ///
    /// - **正面**：每个图标至少要出现一次（少了就红）；
    /// - **反面**：把所有已知 SVG 逐份删掉之后，**对照图里不许再剩下任何 `<svg`** ——
    ///   也就是「对照图里的每个 SVG 都必须逐字等于 catalog 里的某一个」。
    ///   这条对版式无感（不关心出现几次、怎么排版），但任何一份被改过都会被剩下。
    @Test func everySVGInTheGalleryIsExactlyAShippedIcon() throws {
        let catalog = try Self.catalogDirectory()
        let galleryURL = RepositoryScan.repositoryRoot
            .appending(path: "docs/design/icon-gallery.html")
        var remaining = try String(contentsOf: galleryURL, encoding: .utf8)

        var occurrences = 0
        var absent: [String] = []

        for icon in DesignTokens.Icon.allCases {
            let svg = try Self.svg(for: icon, in: catalog)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.contains(svg) {
                absent.append(icon.rawValue)
            }
            while let range = remaining.range(of: svg) {
                remaining.removeSubrange(range)
                occurrences += 1
            }
        }

        #expect(
            absent.isEmpty,
            """
            对照图里没有这些图标（或整张图过期了）：
            \(absent.joined(separator: "\n"))
            重跑 `Scripts/generate-icons.py` —— 对照图与 catalog 是同一次生成的。
            """
        )
        #expect(
            occurrences >= 26,
            "只从对照图里认出 \(occurrences) 份图标 —— 反空洞下限是 26（每个至少一份）"
        )
        #expect(
            !remaining.contains("<svg"),
            """
            对照图里有 SVG 不是 catalog 里的任何一个（手改过，或生成器漏了归一化）。
            剩下的片段：
            \(Self.window(around: "<svg", in: remaining))
            重跑 `Scripts/generate-icons.py`，不要手改这张图。
            """
        )
    }

    // MARK: - 文件读取

    /// 生成器把稿子的 `currentColor` 归一化成的值。
    private static let templateStroke = "#000"

    private static func catalogDirectory() throws -> URL {
        let url = RepositoryScan.repositoryRoot
            .appending(path: "Shared/FluentWorkUI/Resources/Assets.xcassets")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw IconAssetFailure("找不到 asset catalog：\(url.path)")
        }
        return url
    }

    private static func svg(for icon: DesignTokens.Icon, in catalog: URL) throws -> String {
        try String(
            contentsOf: catalog
                .appending(path: "\(icon.rawValue).imageset")
                .appending(path: "\(icon.rawValue).svg"),
            encoding: .utf8
        )
    }

    private static func imagesetNames() throws -> Set<String> {
        let entries = try FileManager.default.contentsOfDirectory(
            at: try catalogDirectory(),
            includingPropertiesForKeys: nil
        )
        return Set(
            entries.filter { $0.pathExtension == "imageset" }
                .map { $0.deletingPathExtension().lastPathComponent }
        )
    }

    /// 取 `needle` 附近的一小段，给失败信息用 —— 大文件整份打出来没法读。
    private static func window(around needle: String, in text: String) -> String {
        guard let range = text.range(of: needle) else { return "（没有找到 `\(needle)`）" }
        let end = text.index(range.lowerBound, offsetBy: 160, limitedBy: text.endIndex)
            ?? text.endIndex
        return String(text[range.lowerBound..<end])
    }
}

// MARK: - 稿子快照

/// 稿子里的 `<symbol>` 清单。**只解析一次**，26 个图标共用。
private enum Draft {
    struct Symbol {
        let id: String
        let attributes: [String: String]
        let body: String
    }

    static let symbols: [Symbol] = load()

    private static func load() -> [Symbol] {
        let url = RepositoryScan.repositoryRoot
            .appending(path: "docs/design/2026-09-26-prd-v16-ux/index.html")
        guard let html = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let pattern = try? NSRegularExpression(
            pattern: #"<symbol\b([^>]*)>(.*?)</symbol>"#,
            options: [.dotMatchesLineSeparators]
        )
        guard let pattern else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)

        return pattern.matches(in: html, range: range).compactMap { match in
            guard let attributesRange = Range(match.range(at: 1), in: html),
                let bodyRange = Range(match.range(at: 2), in: html)
            else { return nil }

            let attributes = IconAssetTests.attributes(
                inOpeningTagOf: "<symbol\(String(html[attributesRange]))>"
            )
            guard let id = attributes["id"] else { return nil }
            return Symbol(
                id: id,
                attributes: attributes,
                body: String(html[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }
}

private struct IconAssetFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

extension IconAssetTests {
    /// 取某个标签开标签上的属性。
    static func attributes(inOpeningTagOf markup: String) -> [String: String] {
        let opening = markup.prefix(upTo: markup.firstIndex(of: ">") ?? markup.endIndex)
        let text = String(opening)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)

        var attributes: [String: String] = [:]
        for match in Self.attributePattern.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text),
                let valueRange = Range(match.range(at: 2), in: text)
            else { continue }
            attributes[String(text[keyRange])] = String(text[valueRange])
        }
        return attributes
    }

    private static let attributePattern = try! NSRegularExpression(
        pattern: #"([a-zA-Z-]+)="([^"]*)""#
    )
}
