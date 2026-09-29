#!/usr/bin/env python3
"""从设计稿快照生成 FluentWorkUI 的图标资产（F7）。

## 为什么是「生成」而不是「手抄」

图标有两个来源，而它们必须永远一致：

  1. **稿子**（`docs/design/2026-09-26-prd-v16-ux/index.html`）—— 29 个 `<symbol>`：
     26 个 app 图标 + 3 个状态栏系统字形。app 图标才是设计权威；
  2. **仓里的 asset catalog** —— 编译真正吃进去的副本。

手抄一次就会漂移一次，而且漂移是**静默**的：改一个坐标点，编译照样过，只有肉眼看
才发现图标不对。所以副本由脚本生成，并由 `Tests/.../UI/IconAssetTests.swift`
逐字比对几何——手抄/手改会被抓（那是本阶段所有资产的既定做法：`DESIGN.md` 里
的可执行真源是代码，代码由判据守）。

## 用法

    Scripts/generate-icons.py            # 生成（幂等：重复跑产物逐字节一致）

脚本**拥有** `Shared/FluentWorkUI/Resources/Assets.xcassets/` 下的全部 `*.imageset`：
每次运行会先清掉它们再重写。不要手改那边的文件——改了会在下一次运行时消失，
而且当场就有判据会红。

顺带产出 `docs/design/icon-gallery.html`（26 个图标的对照图，供肉眼比对）。
它和 catalog 同源，所以不可能漂移；同样不要手改。

## 归一化（与稿子的差异，只有这两处）

- `stroke="currentColor"` → `stroke="#000"`。`currentColor` 是 CSS 关键字，
  离开页面上下文没有意义；asset catalog 用 `template-rendering-intent: template`
  按 alpha 通道当蒙版、由调用方着色，所以描边要的是「不透明」，颜色本身无所谓。
- 补上 `xmlns` / `width` / `height`：`<symbol>` 由 `<use>` 引用，不需要这些；
  独立 SVG 文件需要。

**几何数据一个字都不动**——判据比的就是它。
"""

from __future__ import annotations

import json
import pathlib
import re
import shutil
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
SNAPSHOT = REPO / "docs" / "design" / "2026-09-26-prd-v16-ux" / "index.html"
CATALOG = REPO / "Shared" / "FluentWorkUI" / "Resources" / "Assets.xcassets"

# 怎么区分 app 图标与稿子状态栏里的系统字形（信号/Wi-Fi/电量）：
#
# **按结构推导，不按名单**。这 29 个 symbol 分成两类，而且在属性上分得很干净：
#
#   app 图标     fill="none" stroke="currentColor" stroke-width="1.5" …   ← 线性描边
#   系统字形     fill="currentColor"（没有 stroke）                          ← 实心填充
#
# 硬编码一张「这 3 个是系统字形」的名单也能跑，但它会**静默过期**：稿子哪天换了一组
# 字形，名单不会说话。推导则永远不会过期，代价是规则本身要写清楚（上面就是）。
# 「稿子里所有实心 symbol 恰好是那 3 个已知系统字形」这条更强的断言在判据那侧
# （`IconAssetTests`），所以新增一个实心 symbol 会被当场抓住，而不是静默跳过。
def is_app_icon(attrs: dict[str, str]) -> bool:
    return "stroke" in attrs


STRICT_COLOR = "#000"

SYMBOL_RE = re.compile(r"<symbol\b([^>]*)>(.*?)</symbol>", re.S)
ATTR_RE = re.compile(r'([a-zA-Z-]+)="([^"]*)"')


def parse_symbols(html: str) -> list[tuple[str, dict[str, str], str]]:
    """按出现顺序取全部 `<symbol>`：`(id, 属性表, 内联内容)`。"""
    found: list[tuple[str, dict[str, str], str]] = []
    for attrs_text, body in SYMBOL_RE.findall(html):
        attrs = dict(ATTR_RE.findall(attrs_text))
        symbol_id = attrs.pop("id", None)
        if symbol_id is None:
            raise SystemExit("遇到没有 id 的 <symbol>，脚本需要更新")
        found.append((symbol_id, attrs, body.strip()))
    if not found:
        raise SystemExit(f"从 {SNAPSHOT} 里一个 <symbol> 都没解析出来——快照换了或选择器失配")
    return found


def to_svg(attrs: dict[str, str], body: str) -> str:
    """把 `<symbol>` 变成独立 SVG。

    属性顺序沿用稿子自身的顺序（只把 `currentColor` 归一化、补 `xmlns/width/height`），
    这样 diff 里看到的就是「稿子说了什么」而不是「脚本重排了什么」。
    """
    ordered: list[tuple[str, str]] = [("xmlns", "http://www.w3.org/2000/svg")]
    for key, value in attrs.items():
        if key.startswith("xmlns:"):
            continue
        value = STRICT_COLOR if value == "currentColor" else value
        if key == "viewBox":
            # 24pt 名义尺寸：DesignTokens.Component 的图标基准就是 24pt。
            ordered.append((key, value))
            width, height = value.split()[2:4]
            ordered.append(("width", width))
            ordered.append(("height", height))
        else:
            ordered.append((key, value))
    rendered = " ".join(f'{k}="{v}"' for k, v in ordered)
    return f"<svg {rendered}>{body}</svg>\n"


def imageset_contents(svg_filename: str) -> str:
    """单个 imageset 的 `Contents.json`。

    `preserves-vector-representation`：保留矢量，按 24pt 精确渲染而不是位图缩放。
    `template-rendering-intent = template`：当作蒙版，由调用方用主题色着色
    （稿子里就是 `currentColor`，所以语义一致）。
    """
    payload = {
        "images": [{"filename": svg_filename, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


def catalog_contents() -> str:
    payload = {"info": {"author": "xcode", "version": 1}}
    return json.dumps(payload, indent=2, ensure_ascii=False) + "\n"


GALLERY = REPO / "docs" / "design" / "icon-gallery.html"

GALLERY_HEAD = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>FluentWork 图标集 · 稿子 2026-09-26</title>
<!-- 本文件由 Scripts/generate-icons.py 生成（与 asset catalog 同源）。不要手改。 -->
<style>
  :root {
    --bg: #1A2226; --elev: #232E33; --line: rgba(232,237,239,.10);
    --text: #E8EDEF; --text-2: #9AABAF;
    --brand: #4A7C82; --accent: #7FB3B8; --training: #C9A45C;
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 32px 24px 56px; background: var(--bg); color: var(--text);
    font: 15px/1.6 -apple-system, "PingFang SC", "SF Pro Text", system-ui, sans-serif;
  }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .sub { color: var(--text-2); font-size: 13px; margin-bottom: 28px; }
  h2 { font-size: 15px; margin: 36px 0 12px; color: var(--text-2); font-weight: 600; }
  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(132px, 1fr)); gap: 12px; }
  .tile {
    margin: 0; padding: 16px 12px 12px; background: var(--elev);
    border: 1px solid var(--line); border-radius: 12px;
    display: flex; flex-direction: column; align-items: center; gap: 10px;
  }
  .row { display: flex; align-items: flex-end; gap: 12px; height: 40px; }
  /* 覆盖 SVG 上的 stroke 表现属性 —— CSS 声明优先于表现属性，这正是
     template-rendering-intent 在 iOS 侧做的事（按调用方颜色着色）。 */
  .row svg { stroke: currentColor; }
  .big { color: var(--text); width: 32px; height: 32px; }
  .small { color: var(--accent); width: 20px; height: 20px; }
  .tint { color: var(--brand); width: 32px; height: 32px; }
  code { color: var(--text-2); font: 12px/1.4 ui-monospace, "SF Mono", monospace; }
  .notes { margin-top: 40px; padding-top: 20px; border-top: 1px solid var(--line);
           color: var(--text-2); font-size: 13px; max-width: 760px; }
  .notes code { color: var(--text); }
  .notes li { margin: 6px 0; }
</style>
</head>
<body>
"""


def gallery(icons: list[tuple[str, dict[str, str], str]]) -> str:
    """一张对照图：26 个图标 × 三种呈现（正文色 32pt / 强调色 20pt / 品牌色 32pt）。

    为什么值得生成：图标是**看**的东西，而判据只能证明几何逐字一致、
    证不了「它长得像不像那个图标」。这张图让人一眼比对稿子（左侧预览的 `index.html`
    里也有同一批 symbol），且与 catalog 同源 ⇒ 不可能漂移。
    """
    tiles = []
    for symbol_id, attrs, body in icons:
        svg = to_svg(attrs, body).strip()
        tiles.append(
            f'      <figure class="tile">\n'
            f'        <div class="row">\n'
            f'          <span class="big">{svg}</span>\n'
            f'          <span class="small">{svg}</span>\n'
            f'          <span class="tint">{svg}</span>\n'
            f"        </div>\n"
            f"        <figcaption><code>{symbol_id}</code></figcaption>\n"
            f"      </figure>"
        )

    return (
        GALLERY_HEAD
        + f"<h1>FluentWork 图标集 · {len(icons)} 个</h1>\n"
        + '<p class="sub">来源：稿子快照 <code>docs/design/2026-09-26-prd-v16-ux/index.html</code>'
        " 的 <code>&lt;symbol&gt;</code> ｜ 编译吃的："
        "<code>Shared/FluentWorkUI/Resources/Assets.xcassets/</code> ｜ 由 "
        "<code>Scripts/generate-icons.py</code> 生成（与 catalog 同源）</p>\n"
        + '<h2>26 个 app 图标 —— 32pt 正文色 / 20pt 强调色 / 32pt 品牌色</h2>\n'
        + '<div class="grid">\n'
        + "\n".join(tiles)
        + "\n    </div>\n"
        + """
<div class="notes">
  <p><strong>三列是同一份资产</strong>，不是三份图。asset catalog 里设了
  <code>template-rendering-intent: template</code>，图标的 alpha 被当蒙版、
  <strong>颜色由调用方给</strong>。这一页用 CSS 覆盖 SVG 的 <code>stroke</code>
  演示的正是 iOS 侧 <code>foregroundStyle</code> 的效果：
  <code>DesignTokens.Icon.home.image</code>。</p>
  <ul>
    <li>放大到 32pt 描边依然锐利（<code>preserves-vector-representation</code>），
      不会像位图那样糊。</li>
    <li>不在这里的：<code>i-sig</code> / <code>i-wifi</code> / <code>i-batt</code>
      —— 它们是稿子状态栏的系统字形（实心填充），由系统绘制，app 不导出。</li>
    <li>改图标：改稿子快照，然后重跑生成器。不要手改
      <code>Assets.xcassets</code> 里的 SVG —— 会被覆盖，且
      <code>IconAssetTests</code> 当场红。</li>
  </ul>
</div>
</body>
</html>
"""
    )



def main() -> int:
    html = SNAPSHOT.read_text(encoding="utf-8")
    symbols = parse_symbols(html)

    icons = [(sid, attrs, body) for sid, attrs, body in symbols if is_app_icon(attrs)]
    glyphs = [sid for sid, attrs, _ in symbols if not is_app_icon(attrs)]

    if not icons:
        raise SystemExit(
            f"从 {SNAPSHOT} 里一个描边 symbol 都没解析出来——快照换了或属性形状变了"
        )

    # 幂等：先清掉本脚本拥有的全部 imageset，再重写。留下的任何 `*.imageset`
    # 都必须是本次生成的（判据另外断言「仓里每个 imageset 都在稿子里」）。
    CATALOG.mkdir(parents=True, exist_ok=True)
    for leftover in sorted(CATALOG.glob("*.imageset")):
        shutil.rmtree(leftover)

    for symbol_id, attrs, body in icons:
        imageset = CATALOG / f"{symbol_id}.imageset"
        imageset.mkdir(parents=True)
        (imageset / f"{symbol_id}.svg").write_text(to_svg(attrs, body), encoding="utf-8")
        (imageset / "Contents.json").write_text(
            imageset_contents(f"{symbol_id}.svg"), encoding="utf-8"
        )

    (CATALOG / "Contents.json").write_text(catalog_contents(), encoding="utf-8")
    GALLERY.write_text(gallery(icons), encoding="utf-8")

    print(f"稿子里 {len(symbols)} 个 <symbol>：生成 {len(icons)} 个图标，"
          f"跳过 {len(glyphs)} 个实心符号（{', '.join(glyphs)}）")
    print(f"落到 {CATALOG.relative_to(REPO)}")
    print(f"对照图 {GALLERY.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
