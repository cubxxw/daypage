# PRD: DayPage v4 — Liquid Glass 体验升级

> **生成日期**：2026-05-07
> **来源**：用户诉求（"raw 应该可以点击" / "中英文字体优雅" / "充分优化页面的布局和显示"）+ Anthropic Design 设计包（DayPage v4.html · Liquid Glass）+ v3 PRD 的体验遗留痛点
> **目标版本**：DayPage v4.0
> **状态**：**待主理人确认 Open Questions 后进入 Wave 拆分**
> **关联 GitHub Issues**：EPIC #245 · 子 issue #243 #244 #246 #247 #248
> **设计源**（只读镜像）：`/tmp/daypage-v4-design/daypage/project/{primitives.jsx, screens/*.jsx, tokens.css}`

---

## 1. 为什么要有这份 PRD（背景 / Why this PRD）

DayPage v3 PRD（`tasks/prd-daypage-v3-experience.md`）解决了"从 demo 到产品"的功能与反馈缺口。v4 是**视觉系统**和**核心交互**的下一步：

> v3 解决的是"这个工具有没有功能"，v4 解决的是"这个工具好不好用、好不好看、好不好读"。
> *v3 answered "does it work"; v4 answers "does it feel right".*

用户在 2026-05-07 当天给了三句话级别的诉求：

1. **"raw 应该可以点击的最好，可以点击进去卡片"**
   *Raw memos should be tappable — tap should open the card detail.*
2. **"充分优化页面的布局和显示，包括字体，中英文字体优雅的"**
   *Optimize page layout and rendering — fonts especially, the Latin-CJK mix should feel elegant.*
3. **"把这些（v4 设计文件）相关的方面实现一下"**
   *Implement the relevant aspects of the v4 design file.*

外加 v3 之后未被解决的四个长期体验暗伤（在本 PRD 第 6 节展开）：
- **动画节奏不对** —— 过硬 / 过按钮感 / 缺少 quiet 呼吸
- **空状态不够温柔** —— 第一次打开 / 今天还没记 / 还没编译，全是冷场
- **错误被玻璃吞掉** —— 编译失败 / 上传失败 / 权限被拒，UI 静默无声
- **CJK ↔ Latin 排印细节** —— 不只是字体，标点、空格、emoji 全是雷

---

## 2. Goals

### 产品目标 / Product Goals

- **G1（视觉迁移）**：完成 v4 Liquid Glass 视觉系统在 Today / Memo / Daily Page / Navigation 四个核心面的迁移，与 `screens/*.jsx` 像素级对齐 ±2px。
  *Migrate to v4 Liquid Glass on all four core surfaces, pixel-matched to the prototype within ±2 px.*
- **G2（中英优雅）**：任何含中英混排的段落渲染时无基线抖动、无字重失配、无标点错位 —— 拍照贴 PR 验收。
  *Mixed Latin-CJK paragraphs render without baseline jitter, weight mismatch, or punctuation drift — verified by paired screenshots in PR.*
- **G3（raw 可达）**：所有 5 种 memo 类型（text/voice/photo/location/file）从 Today 与 Archive 两条入口都能进 detail，可读全文 / 看原图 / 听全段 / 编辑 body / 删除。
  *All 5 memo kinds become tappable from both Today and Archive, with full read / full-res photo / full audio / body edit / delete.*
- **G4（quiet 体验）**：动画在 200–280 ms 之间且全部用 cubic-bezier(.2,.8,.2,1) 或 spring(response: 0.35, dampingFraction: 0.8)；空状态 / 错误 / 第一次使用都有 *human-written* 文案与微动效。
  *Animations live in the 200–280 ms band with a single easing curve. Empty / error / first-run states are warm, not blank.*

### 非目标 / Non-Goals

- **NG-1**：不做 Search 屏幕的实现（v4 设计有 `search.jsx` 但 Search 整体是 Post-MVP）。
- **NG-2**：不做 Entity / Graph 屏幕（PRD MVP NG-3 已划定，v4 也维持原状）。
- **NG-3**：不动 AI 编译 prompt 内容（除非 #248 Daily Page UI 强制需要 threads/mentions —— 那时单独开 issue）。
- **NG-4**：不做 iCloud 同步、附件 onDemand 下载状态（已有 #232 在轨）。
- **NG-5**：不做 Onboarding 重写（仅当与新 token 冲突时局部修补）。

---

## 3. 用户角色（Personas）

| 代号 | 描述 | 关键诉求 |
|---|---|---|
| **P-Nomad** | 数字游民，主用语 中文，部分笔记夹英文（"今天 sunlight on the river 特别 gold"）。每天记 5–20 条，长度 30–500 字。 | 字体不能崩；语音转写要准；位置要自动；要看得到"今天我做了什么" |
| **P-Reader** | 用户三天后回看自己的 daily page，想点开某条 memo 看全文 / 找原图。 | 整卡可点击、detail 完整、share 出 markdown |
| **P-Quiet** | 用户在咖啡馆 / 飞机上低光使用 iPhone，对屏幕变化敏感。 | 动画要 quiet、错误不要弹窗、空状态不要冷 |

---

## 4. User Stories

> 每个 US 都被设计为**一个 focused session 内可完工**。
> US-001 到 US-006 是 v4 视觉与交互主线（对应 #243-#248），US-007 到 US-013 是体验升级。

---

### US-001: 中英文字体优雅 / Cascading Latin-CJK serif
> **绑 issue**：#243

**Description（中）**：作为 P-Nomad，我希望一段中英混排的文字读起来基线齐、字重匹、italic 时双语都倾斜，不再是"New York 配 PingFang"那种拼接感。
**Description (en)**: As a Nomad user, I want a paragraph that mixes Chinese and English to render with matched baselines, matched stroke weights, and matched italic behavior — not the current New-York-meets-PingFang collage.

**Acceptance Criteria**:
- [ ] `Source Serif 4`（Latin）+ `Source Han Serif SC`（CJK）打入 bundle，三档字重 + Latin italic
- [ ] `DSFonts.serif(size:weight:italic:)` 走 `UIFontDescriptor.cascadeList` 实现自动回落
- [ ] 测试句 "今天 sunlight on the river 特别 gold" 在 Today / Daily Page / Detail 三处都基线对齐（PR 附前后截图对比）
- [ ] `serifQuote` 渲染 "「今天 the meeting went well 真好」" 时，Latin 倾斜，CJK 行为在 PR 里说明（Source Han Serif 是否支持 italic 变体）
- [ ] 任意纯 Latin 段落与 v4 prototype `SigText` 渲染零差异
- [ ] `DSFonts.newYork(...)` 加 `@available(*, deprecated, renamed: "serif")`
- [ ] App size delta 在 PR 描述里写明
- [ ] iPhone 17 模拟器构建通过

---

### US-002: raw memo 整卡可点击 → MemoDetailView (push)
> **绑 issue**：#244

**Description（中）**：作为 P-Reader，我希望从 Today 或 Archive 任意点一张 memo 卡，整张卡都可点 push 进 `MemoDetailView`，看全文 / 看原图 / 听全段 / 编辑正文 / 删除。
**Description (en)**: As a Reader, I want to tap any memo card from Today or Archive — anywhere on the card — to push into `MemoDetailView` for full content, full-res photo, full audio, body edit, and delete.

**Acceptance Criteria**:
- [ ] Today 与 Archive 两个入口的 memo 卡片都可整卡点击
- [ ] `NavigationStack` 嵌入到 Today 内部，不破坏现有 sidebar 抽屉
- [ ] Swipe 手势（删除 / 置顶）保持工作；当 swipe 已展开时，tap 关闭 swipe 而**不** push detail
- [ ] `MemoDetailView` 正确渲染 5 种 memo：text / voice (waveform + scrub) / photo (full-res) / location (map + Open in Maps) / file
- [ ] Detail 内编辑正文：保存 → 写盘 → 列表自动反应，无需重启
- [ ] Detail 删除：返回上一级，列表中该 memo 消失
- [ ] location 卡 long-press 仍直开 `LocationPreviewSheet`（保留快捷路径）
- [ ] iPhone 17 模拟器构建 + 真实写盘验证（vault/raw/YYYY-MM-DD.md 内容更新）

---

### US-003: Day Orb hero / 替换 heatmap-first Today header
> **绑 issue**：#246

**Description（中）**：作为 P-Nomad，我希望打开 Today 第一眼看到一个温暖的、有光晕的 Day Orb 圆球，正中心是今天的 signals 数；不再是顶着一个热力图。
**Description (en)**: As a Nomad, I want Today to greet me with a warm Day Orb showing today's signal count — not a heatmap.

**Acceptance Criteria**:
- [ ] `DayOrbView` 实现：径向渐变 + halo + 内/外阴影按 `capture.jsx:387–402` 还原 ±2 px
- [ ] Today hero 顺序：serif 大字日期 → mono kicker → orb；heatmap 不在 Today 出现
- [ ] `OnThisDayCard` 与 `WeeklyRecapSection` 从 Today 移除（迁移到 Archive / Day Drawer 在 follow-up）
- [ ] Orb 数字反映 `vm.signalCount`
- [ ] Orb 可点击（占位行为 OK）
- [ ] iPhone 17 截图贴 PR

---

### US-004: Glass TopBar TabBar / single-pill expand-on-tap
> **绑 issue**：#247

**Description（中）**：作为 P-Quiet，我希望屏幕右上角始终有一个像 `当前页面图标 + 标签 + 下拉箭头` 的小药丸，点开展开 4 个 tab 列表，选完合上 —— 不要总是依赖左侧抽屉。
**Description (en)**: As a Quiet user, I want a single-pill nav at top-right that expands on tap into a vertical menu — so I'm not always depending on the left drawer.

**Acceptance Criteria**:
- [ ] `GlassTabBar` 定位在 `top: 54, right: 16`，与 `primitives.jsx:163` 对齐
- [ ] 折叠态：当前 section icon + label + chevron，玻璃配方（blur 28, saturate 160%, hairline 0.5pt, 顶部 inner highlight）
- [ ] 展开态：垂直列表 ≥ 140 pt 宽，spring 动画
- [ ] 点击外部关闭 menu 但不切 section
- [ ] `SidebarView` 的 Today/Archive 行隐藏或降权（PR 中说明决策）
- [ ] sidebar 仍承载 Settings / Account / sync — 无回归
- [ ] 单手操作 spot-check：pill 在右拇指自然弧内（iPhone 17）

---

### US-005: Daily Page v4 / serif 压排 + threads + mentions + source signals
> **绑 issue**：#248

**Description（中）**：作为 P-Reader，我希望编译完的 Daily Page 长得像一份"页"——serif 大标题、serif body 段落、中间 hairline 分隔、底部 threads 与 mentions 标签、再下面是可点回原 memo 的 source signals 列表。
**Description (en)**: As a Reader, I want the compiled Daily Page to read like a page — serif title, serif body, hairline dividers, threads + mentions, then a tappable source-signals list.

**Acceptance Criteria**:
- [ ] Hero card 还原 `screens/page.jsx:14–69` 布局
- [ ] 玻璃配方：`glassStyle({tone:'hi', radius:24})` 一致
- [ ] Action row：Regenerate / Add note / Reflect（Reflect 禁用 + Coming soon）
- [ ] Source signals row 点击 → push `MemoDetailView`（依赖 #244 已落地）
- [ ] 若 `CompilationService` 暂未给 threads/mentions：UI 用 stub 数据 + 立 follow-up issue
- [ ] iPhone 17 截图与 `screens/page.jsx` 对照贴 PR

---

### US-006: 整体玻璃配方落地 / Liquid Glass surface recipe
> **跨 issue**（#244 #246 #247 #248 共用）

**Description（中）**：作为开发者，我需要一个集中的 `liquidGlassCard / liquidGlassPill / liquidGlassPanel` modifier 集，所有 v4 玻璃面共享一份配方。
**Description (en)**: As a dev, I need centralized glass-surface modifiers so every v4 glass surface shares one recipe.

**Acceptance Criteria**:
- [ ] `DesignSystem/Surfaces.swift` 提供 `.liquidGlassCard(cornerRadius:tone:)`、`.liquidGlassPill()`、`.liquidGlassPanel()`
- [ ] 三种 tone：`std / hi / lo` 对应 `T.glass / T.glassHi / T.glassLo`（来自 `primitives.jsx:42`）
- [ ] backdrop blur 28、saturate 160%、0.5 pt hairline、顶部 inner highlight、底部柔阴影 全在一处 —— 不允许散落
- [ ] 现有 `MemoCardView.swift:128` 旧 `liquidGlassCard` 迁移到新版（保持 API 不破）
- [ ] iPhone 17 上无明显 GPU 抖动（spot check：拖滚 Today 列表）

---

### US-007: ✨ Motion timing tokens / 全局动画节奏
> **额外体验升级 #1**

**Description（中）**：作为 P-Quiet，我打开 / 切换 / 撤销 任何屏幕都希望感受到同一种"呼吸"——不是 200ms 这里、450ms 那里、linear 与 spring 各跑各的。
**Description (en)**: As a Quiet user, I want every screen transition / overlay / undo to share one motion language — not a patchwork of 200/450 ms timings and mismatched easings.

**当前问题**：
- `RecordingOverlayView` 用 `.easeInOut`，`SwipeableMemoCard` 自定 spring，`AttachmentMenuSheet` 半模态用系统默认 → 串起来"哒哒哒"
- v4 设计 verbatim 给了 `cubic-bezier(.2,.8,.2,1)` 240 ms（rise）/ 180 ms（fade）/ 280 ms（slide-in），需要统一

**Acceptance Criteria**:
- [ ] 新增 `DesignSystem/Motion.swift` 提供 4 个 token：
  - `Motion.fade` = `.easeOut(duration: 0.18)`
  - `Motion.rise` = `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.24)`
  - `Motion.slide` = `.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.28)`
  - `Motion.spring` = `.spring(response: 0.35, dampingFraction: 0.8)`
- [ ] 全仓 grep 替换 `.easeInOut(duration:)` / `.linear(duration:)` / 散落 `.spring()` → 统一到 token
- [ ] `withAnimation` 调用点至少 80% 用 token（剩余 20% 必须 PR 注释解释为何特例）
- [ ] iPhone 17 录屏：任意 5 秒交互（点 memo → detail → 返回 → swipe → 删除），节奏一致

---

### US-008: ✨ 空状态人设 / Warm empty states
> **额外体验升级 #2**

**Description（中）**：作为 P-Nomad 第一次打开 app（或某天还没记），我看到的不该是空白屏 + "暂无数据" —— 应该是一句 *人写的* 话 + 一个可执行的下一步 + 一点点光晕。
**Description (en)**: As a first-time / quiet-day user, I don't want a blank screen with "No data" — I want a *human-written* line, one obvious next step, and a touch of warmth.

**当前问题**（grep 结果）：
- Today 在 `vm.memos.isEmpty` 时只渲染空 `ScrollView`（无 hint）
- Archive 在没有 daily page 的日期 tap 时显示 "No memos for this day"（生硬）
- Daily Page 在 signal < 3 时按钮 disabled，但**不告诉用户为什么**
- 第一次进 App 没有任何 onboarding 性提示

**要做的状态**：

| 场景 | 文案（中） | 文案（en） | 动作 |
|---|---|---|---|
| 第一次打开 | "今天看起来像一张白纸。" | "Today looks like a blank page." | "随手记一句" 大按钮 |
| 今天还没记 | "今天还没攒下信号。" | "No signals today, yet." | 输入框聚焦 |
| 信号 < 3 时点编译 | "再多两条就能 compile 了。" | "Two more signals and we can compile." | 输入框聚焦 + 进度环 (1/3) |
| 编译失败 | （US-009 处理） | | |
| Archive 那天没记 | "那天你没在 DayPage 留下脚印。" | "You didn't pass through here that day." | 跳到 Today |
| 录音权限被拒 | "DayPage 听不到你 — 在系统设置里给个许可？" | "DayPage can't hear you — grant mic permission in Settings?" | "去 Settings" 按钮 |

**Acceptance Criteria**:
- [ ] `Components/EmptyStateView.swift` 通用组件：title + subtitle + CTA + 可选 orb 微缩光晕
- [ ] 上表 6 个场景全部接入 `EmptyStateView`
- [ ] 所有文案有中英两版（按系统语言切换；项目当前是中文优先，英文是 fallback）
- [ ] iPhone 17 截图：6 张空状态 paired 在 PR

---

### US-009: ✨ 错误不被玻璃吞掉 / Failures speak up
> **额外体验升级 #3**

**Description（中）**：作为 P-Nomad，编译失败 / 上传失败 / 权限被拒不能"啥也不发生"——必须有非弹窗、非阻塞的可见反馈，告诉我 *什么坏了 + 我能做什么*。
**Description (en)**: As a Nomad, compile failures / upload failures / permission denials must not be silent. Show me *what broke* and *what I can do*, without a blocking alert.

**当前问题**（代码审计）：
- `CompilationService.swift` 错误类型齐全但 Today 不显示
- `VoiceService.swift` Whisper 失败时 `attachment.transcript = nil`，UI 不显示 fallback
- `LocationService.swift` 权限被拒时 silently 不附 location，用户不知道为什么 location 没附上
- Photo upload / file pick 在错误路径上没有 user-facing 反馈

**v4 限制**：UI 是玻璃 + ambient blob，传统红 toast 看着会"破功"；要设计 *glass-tone* 的错误条。

**Acceptance Criteria**:
- [ ] 新增 `Components/GlassErrorBanner.swift`：
  - 颜色用 `T.error` + `T.errorSoft` 但保留 backdrop blur
  - 顶部从屏幕顶滑入 280 ms（用 `Motion.slide`）
  - 自动 5 s 后滑出（除非 user 点 retry / details）
  - 有 leading 图标 + 标题 + 副标题 + 可选 retry 按钮
- [ ] 接入 4 个错误源：
  - Compile failure（含 retry 按钮）
  - Whisper failure（标题 "录音保存了 / 转写没成"）
  - Mic permission denied（CTA "去 Settings"）
  - Location permission denied（CTA "去 Settings"）
- [ ] 文案中英双版，避免技术术语（不要 "API 500"，要 "云端没回应，再试一次？"）
- [ ] 同时多个错误：堆叠最多 2 条，顺序 LIFO；多于 2 条折叠成 "+N more" 入口（点开看全部）
- [ ] iPhone 17 录屏：手动断网触发 compile → banner 出现 → 联网点 retry → 成功

---

### US-010: ✨ CJK 排印细节 / Punctuation, spacing, emoji polish
> **额外体验升级 #4**

**Description（中）**：作为 P-Nomad，我写"她说『今天的 sunlight 真好』😊。"时，希望中文全角『』和 Latin 半角字母之间不会有奇怪的 1px 缝、emoji 不会顶到下一行、句末的中文句号"。"不会被多塞一个 ASCII 句号。
**Description (en)**: As a Nomad, mixing CJK full-width punctuation, Latin half-width letters, and emoji should not produce 1-px gaps, emoji line-break artifacts, or doubled punctuation.

**当前问题**：
- CJK 全角『』『」』 与 Latin 字符之间，UIKit text 渲染留有 1–2 px 视觉缝（kerning issue）
- emoji 在 Source Han Serif 缺字时回落到 Apple Color Emoji，但行高会被拉高（行排不齐）
- AI compile 输出有时双标点（`。.`）—— 来自 prompt 末尾的 ASCII 句号
- 复制粘贴中文带的全角空格 `　` 和 Latin 空格 ` ` 视觉等宽不等
- Markdown render 时中英之间 *没有* 自动加 hair space（GitHub 风格的 CJK-Latin 间距）

**Acceptance Criteria**:
- [ ] `Models/CJKTextPolish.swift` 一个纯函数 `polish(_ raw: String) -> String`：
  - 中英之间自动插入 U+200A（hair space），仅在视觉无相邻标点时
  - 双标点 `。.` / `，,` 折叠成单标点（保留中文原标点）
  - 全角空格 `　` 标记并保留（不动），但 hair space 不重复加
  - emoji 保持原状但渲染时统一 `lineSpacing` 与 CJK 行
- [ ] 该函数在以下点接入：
  - Today / Detail 渲染前（read 路径，纯渲染层）
  - Daily Page compile 后渲染前
  - **不**修改持久化原文（vault/raw/YYYY-MM-DD.md 永远是用户原始输入）
- [ ] 单元测试 12+ 用例：纯中、纯英、CJK+Latin、加 emoji、加全角标点、双标点、ASCII 全角混标点
- [ ] iPhone 17 上 paired 截图：polish 前后

---

### US-011: ✨ Haptics 落点 / Where haptics fire
> **额外体验升级（小）**

**Description（中）**：v4 的 quiet 调子要求触觉**减少**且**对**——目前 `SwipeableMemoCard` 用 `UIImpactFeedbackGenerator(style: .medium)`，与 quiet 不符。
**Description (en)**: v4's quiet language asks for *fewer, more meaningful* haptics — current `medium` impact on every swipe action is too loud.

**Acceptance Criteria**:
- [ ] 制定 `DesignSystem/Haptics.swift`：
  - `Haptics.tapConfirm` → `.light`
  - `Haptics.commit` → `.medium`（仅 Compile 完成 / Save 完成）
  - `Haptics.warn` → `.warning`（错误 banner 出现）
  - `Haptics.success` → `.success`（编译成功）
- [ ] 现有 swipe / pin / delete 改 `.light`；commit 类操作（compile / save edit）改 `.medium`
- [ ] 录屏 30 s 一气呵成的录入 + 编辑 + 删除流程，触觉密度感觉"克制"

---

### US-012: ✨ 第一次使用 / First-run welcome
> **额外体验升级（小）**

**Description（中）**：作为第一次安装的 P-Nomad，App 启动后应该有 1 屏（**最多 1 屏**）的"这是 DayPage"——不弹窗、不要求登录、不解释 30 个功能；就一个 Day Orb 在中间淡入，下一行写"在这里留下你今天的信号"，有个"开始"按钮。
**Description (en)**: As a first-launch user, see exactly one welcome screen — not a modal, not a login wall, not 30 explained features. A Day Orb fades in, one line below it, one button.

**Acceptance Criteria**:
- [ ] `Features/Onboarding/WelcomeScreen.swift`
- [ ] 仅在 `UserDefaults.hasSeenWelcome == false` 时出现一次
- [ ] 内容：fade-in Day Orb（800 ms）+ serif 大字 "在这里留下你今天的信号 / Leave today's signals here." + amber 主按钮 "开始 / Begin"
- [ ] 点 Begin 立即进 Today，不再二次弹
- [ ] 用户当天第二次启动绝对不再出现

---

### US-013: ✨ 输入态的"在听 / 在写"光晕
> **额外体验升级（小）**

**Description（中）**：录音 overlay 和 text composer 现在的微动效偏静止；v4 设计的 `RecordOverlay`（`capture.jsx:458–501`）有双层 pulse + halo，是 Liquid Glass 唯一允许的"动"。
**Description (en)**: Recording overlay and text composer should breathe — the v4 `RecordOverlay` (`capture.jsx:458–501`) has the only "moving" element allowed in Liquid Glass: dual pulse + halo.

**Acceptance Criteria**:
- [ ] 录音中：双层圆环 pulse（1.6 s 周期，错相 0.3 s），按 `capture.jsx:474–475` 比例
- [ ] 录音 idle（按 hold-to-record 但还没释放）：`Hold to record` 字样浮起，无 pulse
- [ ] Text composer 聚焦时：底部 caret 微弱呼吸（800 ms 周期，opacity 0.6 ↔ 1.0），跟 `Motion.fade` 时长不同 —— 这是仅有的例外，PR 注释说明为何
- [ ] iPhone 17 上低亮度场景验证：呼吸不刺眼

---

## 5. Functional Requirements（具体功能要求）

### 视觉 / Visual

- **FR-1**: 加载 `Source Serif 4`（Latin）+ `Source Han Serif SC`（CJK）三档字重 + Latin italic 到 bundle，注册到 `Info.plist UIAppFonts`。
- **FR-2**: `DSFonts.serif(size:weight:italic:)` 必须用 `UIFontDescriptor.cascadeList` 实现 Latin → CJK 自动回落。
- **FR-3**: `DSType.serif*` 全部 token 切换到 cascading 实现；`DSFonts.newYork` 标 `@deprecated`。
- **FR-4**: 提供 `liquidGlassCard / liquidGlassPill / liquidGlassPanel` 三个 SwiftUI modifier，参数化 `cornerRadius`, `tone`。
- **FR-5**: `DayOrbView` 实现 156 / 200 pt 两种尺寸，渐变 + halo + 内/外阴影按 `capture.jsx:387–402` 还原。

### 交互 / Interaction

- **FR-6**: Today / Archive 列表用 `NavigationStack` 包裹，定义 `navigationDestination(for: Memo.ID.self)` 推 `MemoDetailView`。
- **FR-7**: `SwipeableMemoCard` 必须用 `NavigationLink(value:)` + `simultaneousGesture(TapGesture)` 同时支持"点击进 detail"和"点击关 swipe"。
- **FR-8**: `MemoDetailView` 必须支持编辑 body 并写盘（通过 `TodayViewModel.update(memo:body:)` 新方法）。
- **FR-9**: `GlassTabBar` 折叠态显示当前 section；展开态列出所有 section；外部 tap 关闭。
- **FR-10**: `AppNavigationModel` 同时驱动 sidebar 与 GlassTabBar，单一来源。

### Daily Page

- **FR-11**: Hero card 内容顺序固定：状态条 → serif 标题 → serif 段落 → divider → THREADS → divider → MENTIONS。
- **FR-12**: Source signals 区每行 = 28×28 类型 tile + 截断 body + mono 时间戳，整行可点 push detail。
- **FR-13**: 若 compile response 暂无 threads/mentions，UI 用 stub 数据 + 立 follow-up issue（**不**阻塞 v4 视觉迁移）。

### 体验升级 / Experience polish

- **FR-14**: `DesignSystem/Motion.swift` 提供 4 个统一动画 token；全仓 80% 替换。
- **FR-15**: `Components/EmptyStateView.swift` 覆盖 6 个空场景，全部中英双文案。
- **FR-16**: `Components/GlassErrorBanner.swift` 接入 4 个错误源（compile / whisper / mic / location）。
- **FR-17**: `Models/CJKTextPolish.swift` 在渲染层（不在持久层）插入 hair space、折叠双标点、归一化 emoji 行高。
- **FR-18**: `DesignSystem/Haptics.swift` 收编四档触觉；旧 `.medium` 调用点降到 `.light`。
- **FR-19**: First-run welcome 屏只在 `hasSeenWelcome == false` 时出现一次，含 Day Orb fade-in。
- **FR-20**: 录音 overlay 双层 pulse 1.6s 错相 0.3s；composer caret 呼吸 800 ms。

---

## 6. Design Considerations / 设计参考

### 6.1 设计源（只读）

```
/tmp/daypage-v4-design/daypage/
├── README.md                           # 设计师手书的 handoff 说明
├── chats/chat1.md                      # 设计师与用户对话（v4 是怎么演变到这版的）
└── project/
    ├── DayPage v4.html                 # 顶层 layout、字体 import、accent palette 切换
    ├── primitives.jsx                  # T (color tokens), glassStyle(), GlassScreen,
    │                                   #   TopBar, GlassIconBtn, GlassTabBar, MonoChip
    ├── tokens.css                      # warm-white v3 token，作为 v4 的 fallback 基底
    └── screens/
        ├── capture.jsx                 # Today + 5 SignalRow + Dock + SideDrawer +
        │                               #   TextComposer + AttachMenu + RecordOverlay
        ├── page.jsx                    # Daily Page hero + threads + mentions + sources
        ├── archive.jsx                 # 暂不实现，待 follow-up
        ├── search.jsx, entity.jsx,     # NG: 不在本 v4 范围
        └── onboarding-settings.jsx
```

**Important**：README 明确禁止"打开 HTML 截图"作为参考路径——所有尺寸 / 颜色 / 字体都直接读源码。本 PRD 的所有 ±2 px 验收都基于源码值，不基于浏览器渲染截图。

### 6.2 Color tokens（v4 完整 palette）

来自 `primitives.jsx:4–33`：

| Token | Value | 用途 |
|---|---|---|
| `T.bg` | `#FAF7F2` | 暖白页 |
| `T.bgDeep` | `#F1ECE3` | 环境光 halo 基底 |
| `T.glass` | `rgba(255,253,250,0.62)` | 标准玻璃 |
| `T.glassHi` | `rgba(255,253,250,0.85)` | hero 卡 / TopBar |
| `T.ink` | `#241B10` | 主文字 |
| `T.inkMuted` | `rgba(36,27,16,0.62)` | 副文字 |
| `T.inkSubtle` | `rgba(36,27,16,0.38)` | mono 时间戳 |
| `T.amber` | `#A8541B` | 主 accent |
| `T.amberDeep` | `#5D3000` | 编译按钮 / 选中态 |
| `T.amberSoft` | `rgba(168,84,27,0.10)` | 标签底 |

`Ocean / Ink` accent 在 v4.html:88–91 提供切换；本 v4 PRD **保留 `amber` 一种**，accent 切换是 Post-MVP 设置项。

### 6.3 重用现有组件

- `liquidGlassCard` modifier 在 `MemoCardView.swift:128` 已存在 → 抽到 `DesignSystem/Surfaces.swift`
- `LocationPreviewSheet` 在 `MemoCardView.swift:317+` → MemoDetailView 的 location 块直接复用
- `CompileFooterButton.swift` 110 行 → Day Drawer 落地后可弃用
- `OnThisDayCard` 68 行 → 整体迁移到 Archive

---

## 7. Technical Considerations / 技术约束

### 7.1 已知约束

- **iOS 16+** (CLAUDE.md)：可以用 `Layout` 协议（iOS 16）做 `FlowLayout`；可以用 `NavigationStack`（iOS 16）；不能用 `@Observable` 宏（Swift 5）。
- **无外部依赖**（CLAUDE.md "no SPM dependencies"）：CJK 字体只能 bundle 内置，不能 SPM。
- **持久层不动**：CJK polish 仅在渲染层；vault/raw/*.md 永远存用户原文。
- **Swift Testing**：可以用，xcodebuild 16+ 默认支持。
- **iPhone 17 simulator**（CLAUDE.md）：所有截图与构建必须在该机型，**模拟器后台启动**（`open -a Simulator &`）。

### 7.2 可能的性能风险

| 风险 | 监控方式 | 缓解 |
|---|---|---|
| 18 MB CJK 字体 → app size 30+ MB | `xcodebuild -showBuildSettings` 后看 .app 体积 | 仅 bundle 3 档；用户接受 |
| `cascadeList` 首次 layout 较慢 | Instruments TimeProfiler trace | 启动时 warm-up（注册时空 `Text("我A")` 预热） |
| `backdrop blur 28 saturate 160%` 在低端模拟器 GPU 抖动 | 滚 Today 列表 60fps 检查 | iPhone 17 是 P-Nomad 主力，不优化老机；A14 以下做 graceful degradation（blur 半径降到 12）|
| `NavigationStack` 嵌入 sidebar 后路由污染 | 写一个 navigation smoke test | sidebar 仍持有 root；NavigationStack 仅 Today 内部 |
| 双层 pulse 动画在低亮度耗电 | 实机 30 min 测试 | 录音 overlay 出现时 `setAnimationsEnabled(true)`；离开关闭 |

### 7.3 实施 Wave 拆分（建议）

```
Wave 1（基础设施）  US-001 字体, US-006 玻璃配方, US-007 motion tokens, US-011 haptics
                   ↓ 提供 token + modifier 给所有后续 US
Wave 2（核心交互）  US-002 raw 可点击, US-003 Day Orb, US-004 GlassTabBar
                   ↓ Today / Archive / Detail 三处主线
Wave 3（编译面）    US-005 Daily Page v4, US-009 错误 banner, US-013 输入光晕
Wave 4（温度层）    US-008 空状态, US-010 CJK polish, US-012 first-run
```

> 也可以倒过来，**Wave 1 + 2 并行**（字体不影响交互，反之亦然），让 4 周变 3 周。

---

## 8. Success Metrics / 成功指标

### 量化

- **M-1**：6 个绑定 issue（#243-#248）全部 close，PR 合入 main
- **M-2**：13 个 US 全部 close，acceptance criteria 100% 勾选
- **M-3**：iPhone 17 模拟器启动到 Today 渲染完成 < 800 ms（cold start）
- **M-4**：ScrollView Today 60 条 memo，60 fps 滚动无掉帧（Instruments Frame Rate）
- **M-5**：app `.ipa` 体积 ≤ 35 MB（含字体）
- **M-6**：`xcodebuild test` 通过（CJK polish 单元测试 ≥ 12 用例）

### 体感（PR 自验）

- **M-7**：写 "今天 sunlight on the river 特别 gold" 一段，PR 截图前后对比 — 中英基线对齐 ✓
- **M-8**：录屏 60 s 完整 capture → compile → 看 page → 点 source signal 进 detail → 编辑 body → 删除 → 返回，全流程 quiet（无突兀动画）
- **M-9**：手动断网触发 compile，错误 banner 出现 + retry 工作 ✓
- **M-10**：第一次安装启动看到 welcome 一次；第二次启动不再出现 ✓

### 反指标 / Anti-metrics

- **AM-1**：v4 之后 P0/P1 bug 数 > 3 → 视为退步
- **AM-2**：app size > 40 MB → 字体策略需缩减
- **AM-3**：滚动 < 55 fps → blur 配方需降级

---

## 9. Open Questions / 待主理人拍板

> 这些问题不解决，Wave 1 不能动。

- **Q-1**：CJK 字体打 3 档（Regular/Medium/SemiBold）= +18 MB，还是仅 1 档（Regular）+ faux-bold？
  - 建议：3 档。memo 标题与编辑按钮的 SemiBold 不可省。
- **Q-2**：Search tab（GlassTabBar 第 4 项）：隐藏，还是 disabled + "Coming soon"？
  - 建议：先隐藏。Search ship 时再加回来一行代码。
- **Q-3**：`OnThisDayCard` / `WeeklyRecapSection` 从 Today 迁出后，立即落 Archive，还是先暂时藏起来 + follow-up issue？
  - 建议：暂藏 + follow-up。本 v4 焦点是 Today / Detail / Daily Page，不开 Archive 战场。
- **Q-4**：错误 banner 在 v4 之后，要不要替换 v3 已有的 toast 实现？
  - 建议：要。统一到 GlassErrorBanner，旧 toast 删除。
- **Q-5**：CJK polish 默认开还是 settings 开？
  - 建议：默认开。用户感知不到的"刚刚好"。Settings 里给一个 advanced toggle 仅给 power user。
- **Q-6**：v4 上线节奏 — 一次性合 6 issue，还是 Wave 1 先发 TestFlight 内测？
  - 建议：Wave 1 + 2 合并发 TestFlight beta；Wave 3 + 4 接着 RC；最终 v4.0 主版本号。

---

## 10. 与 v3 PRD 的边界 / Boundary with v3

| v3 PRD 涉及 | v4 PRD 涉及 |
|---|---|
| 5 步 → 2 步输入压缩 | 不动（v3 已交付） |
| 编译错误 user-facing 反馈 | **细化**：v4 的 `GlassErrorBanner` 替代 v3 的 toast |
| 语音转写 5s → 3s 的 bug | 不动（v3 责任） |
| On This Day / 随机漫步 | 不动（v3 + Archive 责任） |
| Brutalist → 暖色视觉 | **替换**：v3 暖白被 v4 玻璃 + 暖白 + ambient blob 包住 |
| 字体规范（Inter/Space Grotesk/JetBrainsMono） | **扩展**：加 Source Serif 4 + Source Han Serif SC |
| 微交互 | **统一**：Motion tokens 收编所有 v3 散落动画 |

> v4 的"完成"标志：v3 的所有体验承诺 + Liquid Glass 视觉 + raw 可点击 + 中英文优雅 + 4 大体验补丁，全部在主线发布。

---

## 11. Glossary / 术语

| 术语 | 含义 |
|---|---|
| **Liquid Glass** | iOS 26 风格的"暖底 + 半透玻璃 + ambient blob"系统，v4 视觉根基 |
| **Day Orb** | Today 页面唯一的标志性元素：径向渐变圆球 + signals 数 |
| **Signal** | 单条 raw memo 的别名（v4 设计语言中的统一称呼） |
| **Compile** | AI 把当天 raw signals 编译成 Daily Page 的过程 |
| **Cascade list** | UIKit 字体回落机制：Latin 命中 Source Serif 4，CJK 自动回落到 Source Han Serif SC |
| **Glass tone** | std / hi / lo 三档玻璃透明度，`primitives.jsx:42` 定义 |
| **Hair space** | U+200A，CJK ↔ Latin 之间视觉间距的最小单位 |

---

## 12. 附录：完整文件改动估计 / Files touched (estimate)

```
新增（11 个文件）
  DayPage/DesignSystem/Surfaces.swift
  DayPage/DesignSystem/Motion.swift
  DayPage/DesignSystem/Haptics.swift
  DayPage/Models/CJKTextPolish.swift
  DayPage/Components/GlassTabBar.swift
  DayPage/Components/GlassErrorBanner.swift
  DayPage/Components/EmptyStateView.swift
  DayPage/Features/Today/DayOrbView.swift
  DayPage/Features/MemoDetail/MemoDetailView.swift
  DayPage/Features/Onboarding/WelcomeScreen.swift
  DayPage/App/Fonts/SourceSerif4-*.ttf + SourceHanSerifSC-*.otf

修改（≥ 12 个文件）
  DayPage/DesignSystem/Typography.swift     # cascading serif
  DayPage/Features/Today/TodayView.swift    # NavigationStack + Day Orb hero + empty state
  DayPage/Features/Today/MemoCardView.swift # 玻璃 modifier 抽离 + CJK polish 接入
  DayPage/Features/Today/SwipeableMemoCard.swift  # NavigationLink + simultaneousGesture
  DayPage/Features/Daily/DailyPageView.swift      # v4 hero + threads + mentions + sources
  DayPage/Features/Today/RecordingOverlayView.swift  # 双层 pulse
  DayPage/App/RootView.swift                # GlassTabBar + welcome 路由
  DayPage/App/SidebarView.swift             # 隐藏主导航行
  DayPage/App/SidebarViewModel.swift        # 主导航行抽离
  DayPage/App/AppNavigationModel.swift      # sectionBinding
  DayPage/App/Info.plist                    # UIAppFonts 增加 7 个 face
  DayPage/Services/CompilationService.swift # 错误源接入 GlassErrorBanner（仅信号上报）
```

> 估计总改动量：**新增 ~1,500 LOC + 修改 ~600 LOC**，分布在 4 个 wave。
