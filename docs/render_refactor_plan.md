# 帖子渲染引擎重构方案

> 状态:计划中(未实施)
> 上一版:`packages/fluxdo_reader/`(基于 super_editor 的实验,已搁置)
> 设计目标:用自研轻量节点渲染器替代 `flutter_widget_from_html`,解决长帖滚动卡顿、长文选区受限、无法做编辑模式三大根本问题

---

## 0. 文档约定

### 0.1 依据等级标记

| 标记 | 含义 |
|------|------|
| `[定]` | 已拍板,无争议 |
| `[选]` | 多选一,文档中已选定 |
| `[验]` | 待实施时实测确认 |
| `[议]` | 未定,需讨论 |

### 0.2 节点验收等级

| 等级 | 含义 |
|------|------|
| `1:1` | 视觉 + 交互完全等同旧实现,golden 像素差 < 阈值 |
| `近似` | 视觉等同,交互细节有差异(需文档说明) |
| `重做` | 重新设计了交互/视觉,需用户验收 |
| `缺失` | 暂不实现,主项目继续走旧实现 |

---

## 1. 背景

### 1.1 旧实现的问题

**渲染引擎**:`flutter_widget_from_html` (fwfh)

| 问题 | 严重度 | 表现 |
|------|--------|------|
| **滚动卡顿** | 高 | 长帖滚动时 chunk 首次 mount 触发 `CoreBuildTree._addBitsFromNode` 同步全树构造,实测 vsync overhead 90-130ms |
| **选区受限** | 高 | Flutter `SelectionArea` 在虚拟化 Sliver 内会崩溃(flutter/flutter #124078),导致长帖无法跨节点选择 |
| **难做编辑** | 中 | fwfh 是单向 HTML → Widget,无逆向能力,WYSIWYG 编辑要重做 |
| **扩展点笨重** | 中 | `customWidgetBuilder` 只能在 Widget 层 hook,无法在解析阶段干预 |
| **CPU 占用** | 中 | 同步 parseFragment 50-100ms 阻塞 UI,需 isolate 预热缓解 |

### 1.2 前一次尝试(`fluxdo_reader` POC)

**做法**:HTML → AST → `MutableDocument` (super_editor) → 自研 `VirtualizedDocumentLayout`

**失败原因**(基于 audit 与本次 review):

1. **野心过大**:同时改渲染引擎 + 长帖架构 + 选区机制 + 读编统一,任一处问题导致整体不可用
2. **缺对齐机制**:30+ 节点中只有 13 个 1:1 移植,12 个简化丢失细节,9 个完全缺失,且在合并 PR 前无客观判定标准
3. **架构错配**:super_editor 假设 layout 是 Sliver 子节点,与"自带 CustomScrollView"不兼容,Interactor 始终接不上
4. **横切功能丢失**:`selectable_adapter` / `onSelectionChanged` / `screenshotMode` / `contextMenuBuilder` 等系统级功能没有迁移路径

### 1.3 教训

- 必须按节点逐个对齐,而非整体切换
- 必须有客观验收标准(golden + 验收清单),而非主观判断
- 必须支持灰度回滚,任一节点出问题不影响其他
- 不应引入抽象成本过高的第三方框架(super_editor 留下来的 90% 都被绕过)

---

## 2. 设计原则

### 2.1 核心决策

| # | 决策 | 状态 |
|---|------|------|
| D1 | **自研轻量节点渲染器**,放弃 super_editor | `[选]` |
| D2 | **借鉴 fwfh 的扩展点设计**(BuildOp / BuildTree / Flattener / WidgetFactory) | `[定]` |
| D3 | **保留自研选区**(逻辑位置 + 几何缓存)— 这是长文选区的核心,系统 SelectionArea 替代不了 | `[定]` |
| D4 | **不做编辑模式**(本次范围),Node 模型预留扩展性即可 | `[定]` |
| D5 | **Rust 承担 HTML 解析 + Pangu + class 匹配**(html5ever + FFI 一次完成) | `[选]` |
| D6 | **节点级灰度开关**,所有节点 PR 默认 legacy,合并后稳定 1 周才默认 new | `[定]` |
| D7 | **monorepo 直接做**,不独立仓库 | `[定]` |
| D8 | **golden + 运行时对照模式**双重验收 | `[定]` |

> 2026-10-15 注(D7 与现状不符):`packages/fluxdo_render` 最终是独立仓库
> `Lingyan000/fluxdo_render`(上游作者所有)的 git 子模块,cfluxdo 没有 fork,
> 子模块固定在 `f8d834b`。对它的改动要么提给上游,要么先以补丁形式保留在本仓库外,
> 不能直接在子模块里提交后推送。

### 2.2 不变量

整个重构期间,以下不可破坏:

- 长帖虚拟化:每个 chunk 一个 SliverList child,滚出 viewport 回收(主项目已实现,新引擎承袭)
- 帖子内嵌套:回复引用 / spoiler / details 内嵌内容必须能继续渲染(支持递归节点)
- 选区跨节点:同一 post 内任意位置可起选 → 任意位置结束,跨多个 chunk
- 复制能力:选区 → 文本/HTML/markdown,与系统剪贴板正常交互
- emoji 选择:emoji 图片伪造为可选文本(类似旧 `SelectableAdapter`)
- 截图模式:展开所有滚动区域,生成完整 post 图片

---

## 3. 整体架构

### 3.1 分层

```
┌──────────────────────────────────────────────────────────┐
│ 主项目调用方(详情页 / 用户卡 / 嵌套帖 / 通知 / AI 分享)  │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│       fluxdo_render(Dart 包)                              │
│                                                            │
│   ┌─ FluxdoRender widget (整 post 入口)                 │
│   │  ┌─ Sliver 模式(长帖)                              │
│   │  └─ Inline 模式(短帖 / 嵌套)                       │
│   │                                                        │
│   ├─ NodeFactory (Node → Widget,可继承覆盖)             │
│   ├─ NodeOp pipeline (类似 fwfh BuildOp,priority 链式)  │
│   ├─ InlineFlattener (行内压平为 InlineSpan)             │
│   ├─ StyleResolver (style 栈传递,类似 fwfh)             │
│   │                                                        │
│   ├─ SelectionRegistrar (逻辑选区状态机)                 │
│   ├─ NodeGeometryRegistry (虚拟化几何缓存)               │
│   ├─ SelectionLayer (选区高亮渲染)                       │
│   ├─ SelectionGestureRecognizer                          │
│   ├─ SelectionToolbar / SelectionHandles                 │
│   └─ ClipboardExporter (选区 → 文本/HTML/markdown)       │
└──────────────────────────────────────────────────────────┘
                            ↓
┌──────────────────────────────────────────────────────────┐
│       Dart parser in packages/fluxdo_render               │
│                                                            │
│   ParagraphParser.parse(html, opts) → List<BlockNode>      │
│   gallery / pangu / mentions 在主项目接入层复用现有数据       │
└──────────────────────────────────────────────────────────┘
```

### 3.2 Node 模型(草案,阶段 0.7 细化)

```dart
sealed class Node {
  String get id;
}

// 块级
class ParagraphNode extends Node { List<InlineNode> children; }
class HeadingNode extends Node { int level; List<InlineNode> children; }
class CodeBlockNode extends Node { String code; String? language; }
class QuoteCardNode extends Node { String username; String? title; List<Node> body; }
class OneboxNode extends Node { OneboxType type; ...; }
class SpoilerNode extends Node { List<Node> body; }
class DetailsNode extends Node { List<InlineNode> summary; List<Node> body; }
class TableNode extends Node { List<List<TableCell>> rows; }
class PollNode extends Node { PollData data; }
class MathBlockNode extends Node { String latex; }
class IframeNode extends Node { IframeAttrs attrs; }
class CalloutNode extends Node { CalloutType type; List<InlineNode> title; List<Node> body; }
class ImageGridNode extends Node { GridLayout layout; List<ImageRef> images; }
class ImageCarouselNode extends Node { List<ImageRef> images; }
class ChatTranscriptNode extends Node { ...; }
class FootnoteListNode extends Node { ...; }
class HorizontalRuleNode extends Node { }
class ListNode extends Node { ListStyle style; List<ListItemNode> items; }
class LazyVideoNode extends Node { VideoMeta meta; }
class PolicyNode extends Node { ...; }

// 行内
sealed class InlineNode { }
class TextRun extends InlineNode { String text; TextStyle style; }
class LinkRun extends InlineNode { String href; List<InlineNode> children; }
class MentionRun extends InlineNode { String username; String? statusEmojiUrl; }
class EmojiRun extends InlineNode { String name; String url; }
class InlineCodeRun extends InlineNode { String code; }
class InlineSpoilerRun extends InlineNode { List<InlineNode> children; }
class ImageRun extends InlineNode { ImageRef ref; }
class InlineMathRun extends InlineNode { String latex; }
class LineBreakRun extends InlineNode { }
class LocalDateRun extends InlineNode { LocalDateAttrs attrs; }
class LinkClickCountRun extends InlineNode { int count; }
```

### 3.3 主要数据流

```
HTML cooked
   ↓
[Rust] html5ever → RawNode tree (FFI struct)
   ↓
[Dart] RawNode → Node (类型化,做 InlineNode 嵌套展平等)
   ↓ NodeOp pipeline (类似 fwfh BuildOp 的 priority 链)
[Dart] LayoutNode (style 解析完、引用计数 mention 等就位)
   ↓
[Dart] NodeFactory.build(node) → Widget
   ↓
[Flutter] mount / layout / paint
   ↓ 节点 layout 完成时上报几何
[Dart] NodeGeometryRegistry.report(nodeId, rect)
   ↓ 选区查询
[Dart] SelectionRegistrar.getRectFor(LogicalPosition) → Rect (优先在屏精确 rect,否则缓存兜底)
```

---

## 4. 阶段划分

### 阶段 0:底盘建设(2-3 周)

**目标**:把"对齐"和"灰度"基础设施做扎实,后续每个节点都基于此推进。

| # | 任务 | 输出 | 依赖 |
|---|------|------|------|
| 0.1 | 新建 `packages/fluxdo_render/`(Dart 包骨架,空入口) | pubspec + 入口文件 + workspace 接入 | - |
| 0.2 | Rust core PoC(已放弃) | PoC 结论:收益不足以覆盖 FFI/维护成本,解析保留在 Dart `fluxdo_render` | - |
| 0.3 | 输出 `docs/fwfh_borrowing.md`(借鉴清单) | 列出每个借鉴点的接口签名 + 对应实现规划 + 不借鉴点的理由 | - |
| 0.4 | 建立 fixture 库(`packages/fluxdo_render/test/fixtures/`) | 200+ 真实 cooked html,按节点类型分目录,每份配说明文字描述边界 case | - |
| 0.5 | 建立 golden 框架 | `fixture × (legacy | new) = 截图`,像素差对比 + 容差阈值,CI 接入 | 0.4 |
| 0.6 | 建立运行时对照模式 | debug 设置开关"显示新旧渲染差异",同时渲染两份叠加显示差异区 | 0.1 |
| 0.7 | 灰度开关基础设施 | `NodeKind` 枚举 + 三态(legacy/new/both),持久化到 SharedPreferences + 设置页调试入口 | 0.1 |
| 0.8 | Rust html5ever PoC | 实现 `parse_post(html)` 只处理段落/标题/链接/列表,跑 fixture benchmark 对比 Dart `html` 包性能 | 0.2, 0.4 |
| 0.9 | 节点优先级清单 + 验收清单模板 | `docs/node_priority.md`(30+ 节点排优先级排到阶段 1-4)+ 单节点 PR 模板 | 0.3, 0.4, 0.8 |

**阶段 0 退出标准**:

- [ ] 新 `fluxdo_render` 包能 import,空 widget 能渲染 placeholder
- [ ] Rust PoC benchmark 报告出具,决策"用 Rust"或"砍掉走 Dart 路径"
- [ ] Golden 框架跑通一个 demo 节点的 legacy vs new 对比
- [ ] 运行时对照模式可在 debug 模式开启
- [ ] 设置页可切换某个节点的渲染引擎(legacy/new)
- [ ] `docs/node_priority.md` 列出阶段 1-4 的节点清单与排期

---

### 阶段 1:基础节点(2-3 周)

**目标**:覆盖 ~70% 帖子内容的基础节点。一个详情页里如果没有 code/quote/poll 等富节点,这些节点足够把帖子完整渲染出来。

**节点清单**(按优先级):

| 节点 | 验收等级目标 | 备注 |
|------|------|------|
| Paragraph (`<p>`) | `1:1` | 含行内子节点 |
| Heading (`<h1-6>`) | `1:1` | |
| List (`<ul>`/`<ol>`/`<li>`) | `1:1` | 含嵌套缩进 |
| HorizontalRule (`<hr>`) | `1:1` | |
| LineBreak (`<br>`) | `1:1` | |
| TextRun | `1:1` | 含 bold/italic/strikethrough/underline 等基础样式 |
| LinkRun (`<a>`) | `1:1` | 含点击数显示、内部链接路由 |
| InlineCodeRun (`<code>`) | `1:1` | 含背景样式 |
| EmojiRun (`<img class="emoji">`) | `1:1` | 含 emoji 选择支持(伪文本) |
| MentionRun (`<a class="mention">`) | `1:1` | 含状态 emoji 注入、点击打开用户卡 |
| ImageRun (inline `<img>`) | `1:1` | 含 upload:// 解析、SVG 检测、emoji 区分 |
| Blockquote (普通) | `1:1` | 不含 Obsidian Callout |
| LinkClickCountRun | `1:1` | 链接后的 click count 角标 |

**阶段 1 退出标准**:

- [ ] 上述节点 golden 全部通过
- [ ] 灰度开关切到 new,帖子列表/详情页可正常渲染纯文本帖子
- [ ] 性能 benchmark:典型帖子 build 时间不超过 legacy
- [ ] 至少 1 周 dogfood 期,无回退用户反馈

---

### 阶段 2:富节点(4-6 周)

**目标**:覆盖 Discourse 主要扩展语法。完成后基本覆盖普通 post 的全部场景。

**节点清单**:

| 节点 | 验收等级目标 | 复杂点 |
|------|------|------|
| CodeBlockNode | `1:1` | 语法高亮、复制按钮、Mermaid 检测、滚动同步 |
| QuoteCardNode | `1:1` | 嵌套子节点递归渲染、引用回跳 |
| SpoilerNode (块级) | `1:1` | 揭示状态、粒子动画(可降级) |
| DetailsNode | `1:1` | 折叠状态、嵌套子节点 |
| InlineSpoilerRun | `1:1` | 模糊效果 + 粒子(可降级到仅模糊) |
| OneboxNode | `1:1` | user/github/video/social/tech/default 6 种子类型 |
| Blockquote → Callout 路由 | `1:1` | Obsidian Callout 语法识别 |
| CalloutNode | `1:1` | note/tip/warning/error 类型 + 边框图标 |
| TableNode | `1:1` | >30 行虚拟化、列宽自适应、嵌套渲染、screenshotMode |
| MathBlockNode + InlineMathRun | `1:1` | flutter_math_fork |
| IframeNode | `1:1` | 嵌入式 WebView、全屏 LayoutLock、macOS 滚轮 |
| LazyVideoNode | `1:1` | YouTube/Vimeo/TikTok 缩略图 + 点击展开 |

**阶段 2 退出标准**:

- [ ] 上述节点 golden 通过
- [ ] 灰度开关切到 new,绝大多数帖子正常渲染
- [ ] 长帖滚动 vsync overhead p99 < 16ms(对比 legacy 显著改善)
- [ ] 至少 2 周 dogfood

---

### 阶段 3:复杂节点 + 边界节点(3-4 周)

**目标**:覆盖剩余节点,达到与 legacy 功能对等。

**节点清单**:

| 节点 | 验收等级目标 | 复杂点 |
|------|------|------|
| PollNode | `1:1` | 投票交互、API 调用、状态同步 |
| ChatTranscriptNode | `1:1` | Discourse Chat 插件聊天卡 |
| FootnoteListNode + 引用 | `1:1` | 上标链接 + popover |
| LocalDateRun | `1:1` | 多时区 popover、倒计时、范围日期 |
| PolicyNode | `1:1` | 投票/accept/revoke |

**阶段 3 退出标准**:

- [ ] 所有 30+ 节点完成,无 `缺失` 等级
- [ ] 灰度开关默认切到 new
- [ ] 长帖滚动卡顿问题闭环验证(profile 数据对比)

---

### 阶段 4:图片体系(2-3 周)

**目标**:图片相关的 gallery/carousel/grid/lightbox 体系完整迁移。

**节点清单**:

| 节点 / 功能 | 验收等级目标 | 复杂点 |
|------|------|------|
| ImageGridNode | `1:1` | d-image-grid 网格、列数配置 |
| ImageCarouselNode | `1:1` | d-image-grid carousel mode、水平滑动 |
| Lightbox | `1:1` | 点击打开 ImageViewerPage、画廊跨节点联动 |
| GalleryInfo 跨节点共享 | `1:1` | 整 post 一个 gallery,跨 chunk |
| SpoilerImage 揭示状态 | `1:1` | spoiler 内图片揭示后才进 gallery |
| LazyImage | `1:1` | VisibilityDetector 懒加载 |

**阶段 4 退出标准**:

- [ ] 画廊跨 chunk 联动正常(从 chunk1 的图点开,可以左右翻到 chunk3 的图)
- [ ] Spoiler 内图片揭示前不在 gallery,揭示后加入

---

### 阶段 5:横切关注点(3-4 周)

**目标**:选区 / 复制 / 截图 / 上下文菜单等跨节点功能。

#### 5.0 阶段 1-4 期间的选区策略 + 铺路

阶段 5 才做完整自研选区,但**数据契约**在阶段 1 起就铺好,避免后续
回头改所有节点:

| 当前阶段做(已做) | 留到阶段 5 做 |
|---|---|
| `BlockNode.id` 稳定身份 | `SelectionRegistrar` 全局状态机 |
| InlineNode 列表 index 隐含 offset | `NodeGeometryRegistry` 几何缓存 |
| (TBD) `SelectionAwareNode` 标记接口 | `SelectionLayer`(ContentLayers 模式) |
| | 选区手柄 / 工具栏 / 双击选词 等 UI 交互 |

**阶段 1-4 dogfood 期的选区**:`DualRenderWidget` 在 `newImpl` 模式下,
外层主项目仍有 `SelectionArea` 包裹,基础文本选区可用 — 但有 Flutter
`SelectionArea` 在虚拟化 Sliver 内的崩溃风险(`flutter/flutter #124078`)。
触发 crash 时切回 `legacy` 模式即可。**普通用户默认 `legacy`,
不受影响**。

#### 5.1 阶段 5 任务清单

| 功能 | 验收等级目标 | 复杂点 |
|------|------|------|
| 自研逻辑选区 | `重做` | 跨节点、跨 chunk、虚拟化场景下保持正确 |
| 选区高亮 SelectionLayer | `1:1` | ContentLayers 模式 |
| 选区手柄 | `1:1` | 移动端拖动 handle |
| 选区工具栏 | `1:1` | 复制/引用/AI 总结等 action |
| 双击选词 / 三击选段 | `1:1` | |
| 键盘选区 (Shift+方向) | `1:1` | |
| 选区 → 文本/HTML/markdown | `1:1` | `ClipboardExporter` |
| 截图模式 | `1:1` | 展开滚动区域、整 post 截图 |
| onSelectionChanged 外部回调 | `1:1` | 给 toolbar / AI 功能用 |
| contextMenuBuilder | `1:1` | 自定义右键菜单 |

**阶段 5 退出标准**:

- [ ] 所有选区相关功能通过验收清单
- [ ] 长文跨多 chunk 选区在 120Hz 设备上不掉帧

---

### 阶段 6:旧实现下线(1-2 周)

**目标**:确认新引擎完全替代后,删掉 legacy。

| 任务 | 说明 |
|------|------|
| 删除 `lib/widgets/content/discourse_html_content/`(legacy) | 30+ builder 文件、chunked、image_utils 等 |
| 删除 `packages/fluxdo_reader/`(实验代码) | super_editor POC |
| 删除灰度开关相关代码 | NodeKind 三态、SharedPreferences 项、设置页入口 |
| 移除 `flutter_widget_from_html` 依赖 | pubspec.yaml |
| 清理 `HtmlParseService` 中的 chunk/gallery 双产出 | 简化为只服务于新引擎 |

**阶段 6 退出标准**:

- [ ] 新引擎稳定运行 ≥ 2 个版本周期,无 P0 回退
- [ ] CI 全绿、所有 golden 通过
- [ ] 删除后主项目体积明显减小

---

## 5. 节点验收清单模板

**每个节点的 PR 必须填写以下清单,审查时按项打勾**。

### 5.1 实现完整性

- [ ] 节点定义在 `packages/fluxdo_render/lib/node/`,sealed class 派生
- [ ] NodeFactory 中注册了 `build(node, context) → Widget`
- [ ] 如果是行内节点,InlineFlattener 中实现了 `flatten(node, style) → InlineSpan`
- [ ] 旧实现的所有功能点都有对应:列出对应文件 + 行号

### 5.2 测试覆盖

- [ ] 至少 5 个 fixture 覆盖典型场景(简单 / 嵌套 / 边界 / 异常 HTML / 极长内容)
- [ ] Golden 测试通过(`fixture × legacy / new` 像素差 < 阈值)
- [ ] 单元测试覆盖 parser 边界(空字符串、缺属性、嵌套循环、超深递归)

### 5.3 交互对齐

- [ ] 点击行为对齐(链接跳转、图片打开、mention 打开用户卡等)
- [ ] 长按行为对齐(图片引用、链接复制等)
- [ ] 选区行为对齐(可选 / 不可选,与 legacy 一致)
- [ ] 键盘行为对齐(如果适用)
- [ ] 列出对齐项与对应 legacy 代码位置

### 5.4 性能基线

- [ ] 同 fixture 上,新实现 build 时间不超过 legacy 的 1.1x
- [ ] 长帖虚拟化场景下,chunk 滚入时 vsync overhead 不退化
- [ ] 节点首次 mount 时无 100ms+ 同步阻塞
- [ ] benchmark 数据贴在 PR 描述

### 5.5 灰度接入

- [ ] `NodeKind` 枚举新增对应项
- [ ] 设置页"开发者选项 → 渲染引擎"中可见
- [ ] 默认值 `legacy`,通过开关切换 `new`
- [ ] 三态对照模式(legacy/new/both)可工作

### 5.6 文档

- [ ] 节点定义文件头部 dartdoc 注释,说明对应 HTML 模式
- [ ] 复杂节点配 `docs/nodes/<node_name>.md`,说明设计取舍
- [ ] 如果验收等级是 `近似` / `重做`,必须有差异说明文档

---

## 6. 风险与缓解

### 6.1 已识别风险

| 风险 | 严重度 | 缓解 |
|------|--------|------|
| **Rust PoC 不达预期** | 中 | 阶段 0.8 决策点,< 5x 加速直接砍掉,继续走 Dart isolate 路径 |
| **自研选区跨节点 bug 多** | 高 | 阶段 5 集中攻坚,做完整测试用例覆盖虚拟化场景;复用上次 POC 的 `VirtualizedDocumentLayout` 经验 |
| **节点功能漏移植** | 高 | 验收清单第 5.1 项强制对照 legacy 代码,golden 像素对比兜底 |
| **fwfh 借鉴失误,新实现性能反退化** | 中 | 阶段 0.3 调研要列清楚每个借鉴点的复杂度,避免照搬整套架构 |
| **节点级灰度导致代码膨胀** | 低 | 阶段 6 强制清理,所有节点完成后删除灰度逻辑 |
| **dogfood 用户少,问题发现晚** | 中 | 灰度切换前在 internal channel 至少 1 周;每阶段切默认前发布 beta 版 |

### 6.2 红线 — 触发即暂停重构

- 新引擎导致用户报告 P0 数据丢失(如选区复制内容错误)
- 性能比 legacy 显著退化且找不到根因
- 阶段 2 结束时核心节点验收不达 80%

---

## 7. 时间预估

| 阶段 | 工作量 | 累计 |
|------|--------|------|
| 0 底盘 | 2-3 周 | 2-3 周 |
| 1 基础节点 | 2-3 周 | 4-6 周 |
| 2 富节点 | 4-6 周 | 8-12 周 |
| 3 复杂节点 | 3-4 周 | 11-16 周 |
| 4 图片体系 | 2-3 周 | 13-19 周 |
| 5 横切关注点 | 3-4 周 | 16-23 周 |
| 6 下线 | 1-2 周 | 17-25 周 |

**总计:4-6 个月**(按单作者持续投入估算)

**每阶段独立可发布**,即任一阶段结束都可以切灰度上线一部分节点。不存在"做完一半不可用"的状态。

---

## 8. 当前进展记录

> 每完成一个阶段在此追加状态。

- 2026-06-22:文档初稿
- (待补)

---

## 附录 A:已存在基础设施

本次重构可以直接复用以下现有代码:

| 模块 | 文件 | 复用方式 |
|------|------|----------|
| HtmlParseService | `lib/services/html_parse_service.dart` | 新引擎不需要时移除;过渡期可以共用解析路径 |
| BoostContentParser | `lib/widgets/post/post_boost/boost_content.dart` | 不动 |
| HighlighterService | `lib/services/highlighter_service.dart` | 代码块高亮直接复用 |
| PanguCacheService | `lib/services/pangu_cache_service.dart` | 过渡期复用;Rust 路径稳定后下线 |
| native_animated_image | pub 包,已自研 | 直接复用 |
| jovial_svg | pub 包 | SVG 头像继续用 |
| flutter_math_fork | pub 包 | math 节点直接用 |
| flutter_inappwebview | pub 包 | iframe 节点直接用 |
| chewie + video_player | pub 包 | video 节点直接用 |

## 附录 B:不在本次范围

明确不做的事:

- WYSIWYG 编辑模式(后续独立项目)
- Markdown 编辑模式(同上)
- 其他论坛系统支持(本次仅 Discourse / linux.do)
- 主题/换肤系统(独立项目)

## 附录 C:相关文档

- `docs/fwfh_borrowing.md`(阶段 0.3 输出)
- `docs/node_priority.md`(阶段 0.9 输出)
- `docs/nodes/<node>.md`(各节点细节,按需创建)
- `packages/fluxdo_reader/`(上次实验代码,保留参考)
