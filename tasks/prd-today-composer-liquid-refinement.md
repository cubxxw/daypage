# PRD: Today 主页极简优雅重塑 + Composer 3.0 — Liquid Composition Surface

> **关联 issue**: [#252](https://github.com/getyak/daypage/issues/252) · [#250](https://github.com/getyak/daypage/issues/250)
> **关联设计语言**: 见 `tasks/prd-daypage-v4-liquid-glass.md`（Liquid Glass v4 基线）
> **作者**: Xinwei + Claude · 2026-05-08
> **状态**: Draft → 待评审

---

## 1. Introduction / Overview

DayPage 当前的 Today 主页（包含 `AmbientBackground`、`DayOrbView`、`EmptyStateView`、`GlassTabBar`）与 `InputBarV4` 的 composing 态在 v4 Liquid Glass 落地之后，整体气质已经接近"AI 演示稿"，与"安静、克制、纸感、有仪式感的日记本"产品定位偏离。本 PRD 把两个独立 issue 合并为**同一次升级**，因为它们共享设计语言（Liquid Glass 玻璃材质 + 琥珀光晕）、共享视觉权重预算（页面只能有一个主角）、且**用户的体感是连贯的**——主页气质和写作仪式必须一并对齐。

**问题来源**：

- **#252（Today 主页）**：① Ambient 背景 4 团暖色光斑过饱和；② 今日空数据日什么都不展示（即使昨天/这周有数据）；③ `EmptyStateView` 渲染了原始 i18n key（`empty.today.no_signals.title`）；④ 顶部 `GlassTabBar` pill + 头像 + 齿轮"三个圆"过重，与 sidebar 导航重复。
- **#250（Composer）**：① idle → composing 切换无空间连续性，麦克风 orb 直接消失；② 工具栏全部 20pt 等权扁平图标，无层级；③ 空文本发送按钮 18% 透明度像 disabled UI；④ 空 Composer 无任何上下文引子（时间/位置/天气/最近一条尾巴）；⑤ 工具栏钉底，键盘起来后形成双层堆叠；⑥ 单一 light haptic，缺乏材质感；⑦ 缺 matched-geometry / morph / 智能粘贴。

**升级方向**：把"按下 Aa"变成一次有空间感、上下文丰盈、内容感知形变的写作切换；把 Today 主页变回"日记本应有的样子"——主角是字，背景只负责不冷。

---

## 2. Goals

### 主页（#252）
- G1. 视觉饱和度肉眼可感降级——背景从 4 团 55% 不透明光斑 → 几乎纯色 cream，Day Orb 从主角 → 装饰锚点。
- G2. **Today 永远不空白**：今日 0 memo 时按 `昨日 Daily Page > On This Day > Week Recap` 优先级展示一张引子卡。
- G3. 截图里不再出现任何形如 `empty.*.title` 的原始 i18n key——彻查 lproj target membership 并引入 `L10n.swift` 编译期校验。
- G4. **删除 `GlassTabBar`**——sidebar 已覆盖 Today/Archive/Graph 切换，重复导航是当前最大视觉冗余；右上仅留 1–2 个必要控件。

### Composer（#250）
- G5. **空间连续**：idle 玻璃胶囊 → composing 卡片有可见的形态延续（matched-geometry morph），任何一帧截图取出来都能解释清楚形状从哪来。
- G6. **状态机化**：`userExpandedText: Bool` 重构为 `composerState: .idle / .expanding / .open / .collapsing`——12 个签名时刻里 6 个需要明确"过渡中"。
- G7. **上下文丰盈**：空 Composer 自带 ≥3 条上下文 chip（时间·天气、位置、最近一条尾巴等）。
- G8. **内容感知**：发送按钮在 5 种内容形态（空 / 仅文本 / 文本+照片 / 仅位置 / 多模态）下都有合理图形；空状态用 mic 呼吸圆环（复用语音入口语义），不再用 18% 透明琥珀圆。
- G9. **键盘附着**：工具栏跟随键盘上浮（`.toolbar { ToolbarItemGroup(placement: .keyboard) }`），消除"键盘 + 工具栏"双层堆叠。
- G10. **触感阶梯**：5 级 haptic（soft / rigid / medium / light / success）至少落地 4 级。

### 共享
- G11. 所有 UI 改动在 iPhone 17 Simulator 上肉眼验证，且能在 build → run → 录屏流程里一遍走通。
- G12. 不引入任何新的 SPM 依赖；所有效果用 SwiftUI + Apple framework 实现。

---

## 3. User Stories

### 模块 A · Today 主页极简化（issue #252，Phase 1—优先级最高）

#### US-A1: i18n 资源彻查与 L10n.swift 集中
**Description:** As a 用户, I want 主页文案显示中文/英文翻译而非原始 key，so that 截图不再出现 `empty.today.no_signals.title` 这类暴露字符串。

**Acceptance Criteria:**
- [ ] Xcode → DayPage target → Build Phases → Copy Bundle Resources 包含 `zh-Hans.lproj` 和 `en.lproj`（截图取证）
- [ ] Xcode → Project → Localizations 启用 Chinese (Simplified) 与 English
- [ ] `Info.plist` 含 `CFBundleDevelopmentRegion=zh-Hans`、`CFBundleLocalizations=[zh-Hans, en]`
- [ ] 新增 `DayPage/Resources/L10n.swift`：枚举所有 key，提供 `L10n.Empty.todayNoSignalsTitle` 形式的强类型访问器（编译期校验）
- [ ] `EmptyStateView.todayNoSignals()` 改用 `L10n.Empty.todayNoSignalsTitle` 而非裸字面量
- [ ] `Bundle.main.localizations` 在调试日志里能打印出 `["zh-Hans", "en", "Base"]`
- [ ] 中英文系统语言切换后 hero 下方文案正确变化
- [ ] `xcodebuild -scheme DayPage build` 通过；`DayPageTests` 通过
- [ ] 在 iPhone 17 Simulator 上验证截图

#### US-A2: AmbientBackground 纯化（删 4 团暖色光斑）
**Description:** As a 用户, I want 主页背景接近纯色奶油纸感，so that 视觉锚点回到字本身，不再像 AI 演示稿。

**Acceptance Criteria:**
- [ ] `DayPage/DesignSystem/GlassSurface.swift` 中 `AmbientBackground` 默认仅渲染 `DSColor.bgWarm`（FAF7F2）
- [ ] 4 团 amber blob 用 `@AppStorage("debug.ambientBlobs")` 包起来，默认 false（保留作可选/调试）
- [ ] 任何依赖 `AmbientBackground` 的 view（`TodayView`、`DailyPageView`、`MemoDetailView`）显式不传开关，使用默认纯色行为
- [ ] iPhone 17 Simulator 截图与改动前并排：饱和度肉眼明显下降
- [ ] `xcodebuild build` 通过；现有 SnapshotTest（如果存在）需要更新基准
- [ ] 在 iPhone 17 Simulator 上验证截图

#### US-A3: Day Orb 从主角降为装饰锚点
**Description:** As a 用户, I want Day Orb 从中央巨大琥珀球变为纸上一枚轻晕，so that serif 日期 "Friday · MAY 8" 成为视觉主角。

**Acceptance Criteria:**
- [ ] `DayPage/Features/Today/DayOrbView.swift` halo 透明度从 0.4 → 0.15
- [ ] orbFill gradient stops 透明度全部 ×0.5
- [ ] orb 直径从当前值（推断 200pt）→ 140pt（通过参数 `size: CGFloat = 140` 暴露）
- [ ] `TodayView` 调用处显式传 `size: 140`
- [ ] orb 仍保留呼吸动画（v4 已有），但幅度 ×0.7
- [ ] iPhone 17 Simulator 截图与改动前并排：orb 明显收敛
- [ ] 在 iPhone 17 Simulator 上验证截图

#### US-A4: 删除 GlassTabBar，右上仅留齿轮
**Description:** As a 用户, I want 顶部不再出现 [Today ▾] pill 和琥珀色头像，so that 整页只有 sidebar 一套导航语言，视觉一致。

**Acceptance Criteria:**
- [ ] 删除 `DayPage/Components/GlassTabBar.swift`，从 `RootView.swift` / `TodayView.swift` 中移除引用
- [ ] 删除 `TodayView` 顶部账号头像（36pt 实心琥珀圆）；账号入口移入设置 sheet 顶部
- [ ] `TodayView` 顶部右侧仅保留齿轮按钮（28pt 玻璃圆）
- [ ] sidebar（`SidebarView.swift`）在小屏上的展开手势不变
- [ ] Archive / Graph 切换通过 sidebar 完成，回归 path 无歧义
- [ ] `xcodebuild build` 通过；删除涉及的测试更新（`DayPageTests`）
- [ ] 在 iPhone 17 Simulator 上验证截图

#### US-A5: TodayFallbackContent — 今日 0 memo 时的回退栈
**Description:** As a 用户, I want 即使今天没记，主页也能展示昨日 Daily Page / On This Day / 本周回顾中的一张引子卡，so that Today 主页永不空白，并把存量内容自然带到当下。

**Acceptance Criteria:**
- [ ] `TodayViewModel` 新增 `enum TodayFallback { case yesterdayDailyPage(DailyPage), onThisDay([Memo]), weekRecap(WeekStats), pureEmpty }`
- [ ] `TodayViewModel.fallbackContent: TodayFallback` 计算属性按 `昨日 > OnThisDay > WeekRecap > pureEmpty` 优先级返回
- [ ] `TodayView` 在 `memos.isEmpty && !isLoading` 时按 fallback 渲染：
  - `.yesterdayDailyPage` → 复用 `DailyPageEntryCard`
  - `.onThisDay` → 复用 `OnThisDayCard.swift`（当前被禁用，需复活）
  - `.weekRecap` → 复用/复活 `WeeklyRecapSection.swift`（v3 注释说移除了，本 story 是它的复位）
  - `.pureEmpty` → 仅显示 hero 下方一句小字 "今天还没有信号 · 准备开始 →"
- [ ] 原 `EmptyStateView.todayNoSignals()` 退化为单行小字；不再独占 hero 下方一整屏
- [ ] 三种 fallback 卡的点击行为：进入对应详情（昨日 → DailyPageView，OnThisDay → MemoDetailView，WeekRecap → ArchiveView 周视图）
- [ ] 单元测试：`TodayViewModelTests.testFallbackPriority()` 覆盖 4 种状态机转移
- [ ] 在 iPhone 17 Simulator 上构造 4 种存量数据场景验证截图

---

### 模块 B · Composer 3.0（issue #250，Phase 1）

#### US-B1: composerState 状态机
**Description:** As a 开发者, I want 用 `composerState: .idle / .expanding / .open / .collapsing` 替换 `userExpandedText: Bool`，so that 12 个签名时刻中"过渡中"那一拍能被精确控制。

**Acceptance Criteria:**
- [ ] `InputBarV4.swift` 新增 `enum ComposerState: Equatable { case idle, expanding, open, collapsing }`
- [ ] 删除 `userExpandedText: Bool`，所有引用迁移到 `state == .open || state == .expanding`
- [ ] 状态转移函数 `func transition(to: ComposerState)` 集中管理，每次转移触发对应 haptic 与 animation
- [ ] `expanding` / `collapsing` 持续时间 = `.spring(response: 0.42, dampingFraction: 0.78)`
- [ ] 在 `.expanding` / `.collapsing` 期间禁止接受新的状态切换（防抖）
- [ ] 单元测试：`ComposerStateMachineTests` 覆盖所有合法 / 非法转移
- [ ] `xcodebuild build` 通过

#### US-B2: Liquid Morph — 玻璃胶囊"生长"成 composition card
**Description:** As a 用户, I want 从 idle 三槽胶囊到 composing 卡片看到形态延续而非两个 view 切换，so that 切换有仪式感。

**Acceptance Criteria:**
- [ ] 用 `matchedGeometryEffect(id: "composer.surface", in: namespace)` 把 idle 胶囊 morph 成 composing 圆角矩形
- [ ] 麦克风 orb 不消失：缩小 64×64 → 28×28、左移到卡片左下角，作为"切回语音"入口（替代当前左侧 `chevron.down`）
- [ ] Aa 按钮淡出 = TextField caret 淡入（同位置交叉淡入 200ms）
- [ ] 整段动画 `.spring(response: 0.42, dampingFraction: 0.78)`，触发 `UIImpactFeedbackGenerator(.soft)`
- [ ] 录屏验证：任意一帧截图取出来形状都能解释从哪来
- [ ] 在 iPhone 17 Simulator 上验证

#### US-B3: Adaptive Send Affordance（5 形态发送按钮）
**Description:** As a 用户, I want 发送按钮根据 draft 形态变形，so that 我能从图形上读出"现在发送会做什么"。

**Acceptance Criteria:**
- [ ] 5 种形态映射如下表（源自 issue #250 表格）：

| 内容 | 图形 | accessibilityLabel |
|---|---|---|
| 空 | 浅色 `mic.fill` 圆环（柔光呼吸 1.6s/cycle） | "按住说" |
| 仅文本 | 实心琥珀 `arrow.up` | "发送" |
| 文本 + 照片 | `camera.fill` + `arrow.up` 复合 | "记下这一刻" |
| 仅位置 | `mappin.and.arrow.up` | "标记此处" |
| 多模态 | 琥珀 ring 带光晕脉动（每 1.6s） | "发送 N 项" |

- [ ] 空态明确**不再用 18% 透明琥珀圆**——用 mic 呼吸圆环
- [ ] 形态切换 `.spring(response: 0.32, dampingFraction: 0.8)`
- [ ] VoiceOver 朗读对应 label
- [ ] 在 iPhone 17 Simulator 上构造 5 种 draft 验证

#### US-B4: Keyboard-Attached Toolbar
**Description:** As a 用户, I want 工具栏跟键盘一起浮起，so that 不再形成"键盘 + 工具栏"双层堆叠。

**Acceptance Criteria:**
- [ ] 工具栏迁移到 `.toolbar { ToolbarItemGroup(placement: .keyboard) { ... } }`
- [ ] 卡片本体停在画面中段，下方可见 timeline（带 vignette 渐隐遮罩）
- [ ] 键盘收起时工具栏跟随消失，无残留高度占位
- [ ] iPad / 大屏旋转适配：横屏键盘工具栏不溢出
- [ ] 在 iPhone 17 Simulator 上验证

#### US-B5: Drag-to-Collapse Handle
**Description:** As a 用户, I want 卡片顶边一个 36×4 capsule handle 上滑可收起，so that 与 iOS sheet 语言一致。

**Acceptance Criteria:**
- [ ] 卡片顶部居中 36×4 灰色 capsule
- [ ] 上滑距离 > 32pt 触发 `transition(to: .collapsing)` → `.idle`
- [ ] 单击 handle 等价上滑（accessibility）
- [ ] 折叠动画与 morph 反向播放，`.medium` impact
- [ ] 在 iPhone 17 Simulator 上验证

#### US-B6: Tactile Haptics Ladder（5 级触感）
**Description:** As a 用户, I want 不同动作触发不同强度的触感，so that Composer 有"材质感"。

**Acceptance Criteria:**
- [ ] 触感映射（至少落地 4 级）：

| 动作 | 反馈 |
|---|---|
| 点 dock 任意键 | `.soft` impact |
| Caret 首次出现 | 0.15s 延迟 `.rigid` 0.3 强度 |
| 添加附件 | `.medium` |
| 删除附件 | `.light` |
| 发送成功 | `.success` notification |
| 录音太短/错误 | `.warning` notification |

- [ ] 全部触感封装到 `Haptics.swift`（`DayPage/DesignSystem/Haptics.swift` 已存在，扩展 5 级）
- [ ] 实机（非模拟器）验证至少 4 级可感

---

### 模块 C · Composer 3.0（Phase 2 — Context 丰盈，落在同一 PRD 内但晚于 Phase 1）

#### US-C1: Context Spotlight Strip
**Description:** As a 用户, I want TextField 上方一条横向 chip 带显示天气/位置/上一条尾巴/智能粘贴，so that 空 Composer 也有"现在写什么"的引子。

**Acceptance Criteria:**
- [ ] 新增 `ComposerContextProvider`（`DayPage/Services/ComposerContextProvider.swift`），整合 `WeatherService` / `LocationService` / `viewModel.memos.last` / `UIPasteboard.general`
- [ ] Spotlight Strip 横向滚动，每个 chip 28pt 高、玻璃材质
- [ ] chip 类型：`.weather(temp, condition)` / `.location(short)` / `.timeRitual(emoji, text)` / `.lastMemoTail(snippet)` / `.smartPaste(value)`
- [ ] 点击 chip → 对应内容塞入 draft（位置塞 `Memo.Location`、时间塞 prompt、上一条尾巴塞引用块、剪贴板塞文本）
- [ ] 触摸软触感 `.soft` 0.4
- [ ] 空 Composer 至少 3 条 chip（验收标准）
- [ ] 在 iPhone 17 Simulator 上验证

#### US-C2: Smart Templates（时段模板）
**Description:** As a 用户, I want 空 Composer 显示 1 行时段模板，so that 我能一键得到"今天怎么写"的引子。

**Acceptance Criteria:**
- [ ] 12 条 hardcode 模板（不做配置项，留 future）：

| 时段 | 模板示例 |
|---|---|
| 06–11 | "晨间状态" / "今天想做的一件事" / "醒来注意到……" |
| 11–17 | "刚才发生了" / "中午这一段" / "记一个想法" |
| 17–22 | "今天最…的一刻" / "一句话总结" / "给明天的自己" |
| 22–06 | "睡前回看" / "一个未完成的念头" / "梦的边缘" |

- [ ] 仅在 `text.isEmpty && pendingAttachments.isEmpty` 时显示
- [ ] 点击 → 模板文字塞入 TextField，placeholder 高亮（`.foregroundStyle(.secondary)`），caret 定位到 placeholder 起点
- [ ] 用户开始打字后 placeholder 消失
- [ ] 在 iPhone 17 Simulator 上验证

#### US-C3: Inline Lens Strip — 最近 4 张照片
**Description:** As a 用户, I want TextField 下方一条 56×56 圆角缩略图带，so that 我能一键附加最近 24h 内的照片，无需跳 PhotosPicker。

**Acceptance Criteria:**
- [ ] **懒加载相册权限**：第一次展开 Composer 时 prompt `PHPhotoLibrary.requestAuthorization(for: .readWrite)`
- [ ] 拒绝权限后 Strip 隐藏，不再 prompt（`@AppStorage("composer.photoPermissionAsked")`）
- [ ] 显示最近 24h 内 4 张缩略图，按时间倒序
- [ ] 点击缩略图 → 直接附加到 `pendingAttachments`，不跳 sheet
- [ ] 缩略图加载用 `PHCachingImageManager`，避免卡顿
- [ ] 无最近照片时 Strip 隐藏（不显示空态）
- [ ] 在 iPhone 17 Simulator 上验证（需要 Simulator 相册有照片）

#### US-C4: Caret Spotlight + Ambient Dim
**Description:** As a 用户, I want focus 时背景变暗 20% 同时卡片背后泛起暖白射灯，so that 写作仪式感拉满。

**Acceptance Criteria:**
- [ ] focus 进入时 `AmbientBackground` 整体透明度 -20%（`.opacity(0.8)`）
- [ ] Composer 卡片背后 `RadialGradient`（中心 = caret 位置、半径 240pt、暖白色 0.12 opacity）
- [ ] 现有 `BreathingCaretView` 保留并接入
- [ ] focus 退出反向动画 0.4s
- [ ] 在 iPhone 17 Simulator 上验证

#### US-C5: Status Strip
**Description:** As a 用户, I want 卡片顶部一行 12pt mono 显示 `DRAFTING · 2 PHOTOS · ATLAS BLDG · 12s 未保存`，so that 我能看到 Composer 的实时状态。

**Acceptance Criteria:**
- [ ] 字段顺序：`<state> · <attachment count> · <location short> · <draft age>`
- [ ] 状态枚举：`DRAFTING / SENDING / SENT ✓ / ERROR`
- [ ] 发送成功 1.2s 内显示 `SENT ✓` 然后整个 Composer 折叠回 idle dock
- [ ] 字体 `JetBrains Mono` 12pt（已注册）
- [ ] 在 iPhone 17 Simulator 上验证

---

### 模块 D · Composer Phase 3（Intelligence，可选 / future）

#### US-D1: Smart Paste Detection
**Description:** As a 用户, I want 当剪贴板有文本/URL/图片时 Spotlight Strip 最左塞入 `📋 粘贴 "https://…"` chip，so that 一键塞进 draft。

**Acceptance Criteria:**
- [ ] 检测 `UIPasteboard.general.hasStrings/.hasURLs/.hasImages`
- [ ] 仅在 Composer 进入 `.open` 状态时检测一次（不轮询）
- [ ] chip 显示前 30 字省略
- [ ] 点击 → 塞入 draft；剪贴板 = URL 时附加为 link attachment
- [ ] **隐私**：不将剪贴板内容上传 / 不持久化
- [ ] 在 iPhone 17 Simulator 上验证

#### US-D2: Inline Continuation
**Description:** As a 用户, I want 5 分钟内有上一条 memo 且看起来未完时显示 `💭 续写：…` chip，so that 写作有连续性。

**Acceptance Criteria:**
- [ ] 检测条件：`now - lastMemo.createdAt < 5min` AND（`endsWith("…")` OR `endsWith("，")` OR LLM 判定未完）
- [ ] LLM 判定走 `CompilationService.continuationCheck(memo:)`，本地缓存结果，避免重复请求
- [ ] chip 显示 `💭 续写："…然后我就坐在那里看了很久" →`
- [ ] 点击 → 上一条 memo 末尾 30 字以引用块（`> ...`）形式塞入 draft，光标定位到引用之后
- [ ] **降级**：DashScope API 不可用时 chip 静默不显示
- [ ] 在 iPhone 17 Simulator 上验证

---

## 4. Functional Requirements

### Today 主页（FR-A 系列）
- **FR-A1.** `Resources/L10n.swift` 必须为所有 i18n key 提供强类型枚举访问器；不允许在 view 中使用裸字符串字面量做 `LocalizedStringKey`。
- **FR-A2.** `AmbientBackground` 必须支持 `showAmbientBlobs: Bool` 参数（默认 false），由 `@AppStorage("debug.ambientBlobs")` 控制；4 团光斑仅在 true 时渲染。
- **FR-A3.** `DayOrbView` 必须暴露 `size: CGFloat` 与 `haloOpacity: CGFloat` 参数；默认值 `size = 140, haloOpacity = 0.15`。
- **FR-A4.** `GlassTabBar.swift` 必须从 codebase 完全删除（不保留 disabled 版本）；任何对它的引用必须替换为 sidebar 调用。
- **FR-A5.** `TodayViewModel.fallbackContent: TodayFallback` 必须按 `yesterdayDailyPage > onThisDay > weekRecap > pureEmpty` 优先级返回；优先级硬编码、不可配置。
- **FR-A6.** `OnThisDayCard.swift` 与 `WeeklyRecapSection.swift` 必须在 `TodayView` 复活并接入 fallback 渲染。

### Composer（FR-B 系列）
- **FR-B1.** `InputBarV4` 内部状态必须从 `Bool` 重构为 `enum ComposerState: Equatable { case idle, expanding, open, collapsing }`。
- **FR-B2.** Idle ↔ Composing 切换必须使用 `matchedGeometryEffect(id: "composer.surface", in: ns)`，麦克风 orb 在动画期间不可消失（缩放+位移而非淡出）。
- **FR-B3.** 发送按钮必须根据 draft 形态返回 5 种图形之一（见 US-B3 表）；空态使用 mic 呼吸圆环，**不允许**使用 18% 透明琥珀圆。
- **FR-B4.** Composer 工具栏必须挂在 `.toolbar { ToolbarItemGroup(placement: .keyboard) }`，不允许常驻屏幕底。
- **FR-B5.** `Haptics.swift` 必须暴露 5 级 API：`.soft / .rigid(intensity:) / .medium / .light / .success / .warning`，且至少 4 级在 Composer 流程中被实际触发。
- **FR-B6.** `ComposerContextProvider` 必须聚合 `WeatherService`、`LocationService`、`memos.last`、`UIPasteboard`，提供 `var chips: [ContextChip]` 计算属性。
- **FR-B7.** `Smart Templates` 文案必须 hardcode 12 条；不引入配置文件 / 设置项。
- **FR-B8.** Lens Strip 第一次展开 Composer 时才 prompt 相册权限；拒绝后由 `@AppStorage("composer.photoPermissionAsked")` 标记，永不再 prompt。
- **FR-B9.** Status Strip 字段顺序固定为 `<state> · <attachments> · <location> · <draft age>`，使用 JetBrains Mono 12pt。

### 共享（FR-S 系列）
- **FR-S1.** 所有 UI 改动必须在 iPhone 17 Simulator 上构建运行通过。
- **FR-S2.** 不允许引入新的 SPM 依赖；所有动画/触感/材质用 SwiftUI + Apple framework 实现。
- **FR-S3.** 改动涉及的文件必须保持单文件 ≤ 800 行（v3 baseline）；超过则按 view extension 拆分。
- **FR-S4.** 所有新文件必须包含至少 1 个 SwiftUI Preview；状态机 / 服务必须有 ≥1 个单元测试覆盖核心路径。

---

## 5. Non-Goals (Out of Scope)

- **NG-1.** 不重写 sidebar（`SidebarView.swift`）的视觉与行为——仅消费它。
- **NG-2.** 不修改 `CompilationService` 的 daily compilation 逻辑——本 PRD 不触碰 AI 编译管线。
- **NG-3.** 不引入"时段呼吸背景"（issue #252 选项 C）——留 Phase 4，不在本 PRD 内。
- **NG-4.** 不做 Composer Phase 3 的 ghost-text 智能补全——US-D1 / US-D2 仅作为可选拓展，PRD 不强制实现。
- **NG-5.** 不做账号头像迁移到设置 sheet 之外的视觉重构——只是从 TodayView 顶部移除并塞进现有设置 sheet 顶部。
- **NG-6.** 不做 watchOS 适配——`tasks/design-watch-recording.md` 是另一条线。
- **NG-7.** 不引入 SwiftUI `@Observable` 宏（项目锁定 Swift 5）——继续 `ObservableObject` + `@Published`。
- **NG-8.** 不修改文件存储格式（`vault/raw/YYYY-MM-DD.md` YAML+Markdown）——本 PRD 是纯 UI 升级。

---

## 6. Design Considerations

### 视觉权重预算（Design Token）
- **主页**：背景 < Day Orb < serif date（40pt） < timeline 内容
- **Composer**：背景（dim） < Spotlight chips < Composer 卡片 < TextField caret

### Liquid Glass 共享 token（沿用 v4 baseline）
- `DSColor.bgWarm` = `#FAF7F2`
- `DSColor.amber.300` = `#E8974D`（Day Orb / Send button 实色态）
- `DSCorner.composer` = 24pt
- `DSSpring.morph` = `.spring(response: 0.42, dampingFraction: 0.78)`
- `DSSpring.send` = `.spring(response: 0.32, dampingFraction: 0.80)`

### 无障碍
- Dynamic Type：所有新文案必须支持到 `XXXLarge`；状态 Strip 在 `XXLarge+` 时省略 location 字段
- VoiceOver：发送按钮 5 形态各有 accessibilityLabel；状态机转移触发 `UIAccessibility.post(.layoutChanged)`
- Reduced Motion：开启时禁用 Liquid Morph，改为简单 fade（`.opacity` 0.2s）

### 复用既有组件
- `OnThisDayCard.swift`（已存在，需复活引用）
- `WeeklyRecapSection.swift`（v3 已删除注释，本 PRD 复位）
- `DailyPageEntryCard`（已存在）
- `BreathingCaretView`（`InputBarV4.swift:670`，保留）
- `Haptics.swift`（扩展为 5 级）
- `WeatherService.swift` / `LocationService.swift`（直接消费）

---

## 7. Technical Considerations

### 状态机依赖
- `ComposerState` 状态机引入后，`InputBarV4` 内部所有 conditional 渲染必须改读 `state`，不再读 `userExpandedText`。
- 状态机转移必须是单向无歧义：`idle → expanding → open → collapsing → idle`，禁止跨级跳转。

### 性能
- Lens Strip 用 `PHCachingImageManager`，缩略图分辨率 ≤ 168×168（@3x = 56pt）
- Spotlight Strip 的 `lastMemoTail` 计算缓存 60s，避免每次 focus 都重读 vault
- Liquid Morph 的 matchedGeometry 在 ProMotion 上 120fps；非 ProMotion 60fps 仍流畅
- 删除 `GlassTabBar` 后 `TodayView.body` 行数应 ≤ 200 行（当前 ~330 行）

### 风险
- **R1.** `matchedGeometryEffect` 跨 `if-else` 分支在 SwiftUI 早期版本有渲染 bug；iOS 17+ 修复，但需要在 iPhone 17 Simulator（iOS 18）实测。
- **R2.** Keyboard placement toolbar 在 sheet 中表现不一致；如 Composer 嵌入 sheet 需 fallback 到 inline toolbar。
- **R3.** L10n.swift 需要随 strings 文件更新而手动维护；建议加 SwiftGen-style 脚本（future，不阻塞 PRD）。
- **R4.** 删除 `GlassTabBar` 涉及多文件 import 清理；ralph 跑这个 story 时务必 grep 全仓清扫。

### 外部依赖
- 无新增 SPM 依赖
- 复用 `AVFoundation` / `PHPhotoLibrary` / `CoreLocation` / `UIPasteboard`
- DashScope API 仅在 US-D2（可选）触发

---

## 8. Success Metrics

### 主观（截图对比）
- **M1.** 主页改动前/后并排截图：任何外部观察者能一眼说出"后者是日记本，前者是 AI 演示稿"
- **M2.** Composer idle → composing 录屏：任意一帧暂停截图都能解释"形状从哪来"

### 客观
- **M3.** `TodayView.body` 行数 ≤ 200（当前 ~330）
- **M4.** `InputBarV4.swift` 总行数 ≤ 800（当前 ~720，新增功能后允许扩 80）
- **M5.** 所有新文件单元测试通过率 100%；`xcodebuild test -scheme DayPage` 绿
- **M6.** iPhone 17 Simulator 录制 60s 写作流（idle → 拍照 → 加位置 → 文本 → 发送），无掉帧（CADisplayLink ≥ 58fps 平均）
- **M7.** L10n key 全覆盖：`grep -r "LocalizedStringKey(\"" DayPage/` 结果为 0（除 L10n.swift 内部）

### 验收对齐 issue 原话
- **M8.** [#252 验收] 截图叠层放大对比，背景饱和度肉眼明显下降 ✓
- **M9.** [#252 验收] Today 在今日 0 memo 时至少看到一张存量内容卡 ✓
- **M10.** [#252 验收] 截图里不再出现任何 `empty.*.title` 这种原始 key ✓
- **M11.** [#252 验收] 顶部右侧只剩"必须出现"的 1–2 个控件 ✓
- **M12.** [#250 验收] Idle → expanded 切换无任何"跳变" ✓
- **M13.** [#250 验收] 空 Composer 自带 ≥3 条上下文 chip ✓
- **M14.** [#250 验收] 发送按钮在 5 种内容形态下都有合理图形 ✓
- **M15.** [#250 验收] 工具栏跟随键盘 ✓
- **M16.** [#250 验收] 5 种触感至少落地 4 种 ✓

---

## 9. Phasing & Branching Strategy

按"一次性合并：Today Ph1 + Composer Ph1 同发"的决策，落地节奏如下：

### Phase 1（本 PRD 主战场，~3–4 天）
**分支：`feat/today-composer-liquid-refinement`**

| Story | 估算 | 依赖 |
|---|---|---|
| US-A1 i18n + L10n.swift | 0.5d | — |
| US-A2 AmbientBackground 纯化 | 0.25d | — |
| US-A3 Day Orb 收敛 | 0.25d | A2 |
| US-A4 删除 GlassTabBar | 0.5d | — |
| US-A5 TodayFallbackContent | 1d | A1 |
| US-B1 composerState 状态机 | 0.5d | — |
| US-B2 Liquid Morph | 1d | B1 |
| US-B3 Adaptive Send（5 形态） | 0.5d | B1 |
| US-B4 Keyboard Toolbar | 0.5d | B1 |
| US-B5 Drag Handle | 0.25d | B1, B2 |
| US-B6 Haptics Ladder | 0.5d | — |

→ **一个大 PR**，分 stage commit；通过 `gh pr create` 关联 #252 + #250。

### Phase 2（Composer Context 丰盈，~2–3 天，独立分支）
**分支：`feat/composer-context-strip`**

US-C1 → US-C2 → US-C3 → US-C4 → US-C5

### Phase 3（Composer Intelligence，可选，~1–2 天）
**分支：`feat/composer-intelligence`**

US-D1 → US-D2

---

## 10. Open Questions

- **OQ-1.** 删除 `GlassTabBar` 后，Today/Archive/Graph 切换在大屏（iPad）下是否仍有强烈需求？如果有，是否考虑做一个**仅 iPad** 的 segmented control？→ 倾向 iPad 也走 sidebar，PRD 暂不分屏处理。
- **OQ-2.** `WeeklyRecapSection` 复活后的统计粒度（本周已记 N 条 / 几天 / 哪几天）需不需要点击进入周视图？→ 倾向是，进入 `ArchiveView` 周模式。
- **OQ-3.** US-B2 的 `matchedGeometryEffect` 在 iPad 分屏（Slide Over）下是否仍流畅？→ 需在 PR 自测时 spot check。
- **OQ-4.** US-C2 Smart Templates 在 22–06 时段的"梦的边缘"对部分用户可能太诗意，是否需要 A/B？→ PRD 阶段先 hardcode，灰度阶段再说。
- **OQ-5.** Phase 1 一个 PR 是否会过大（11 个 story）？是否拆成 `Today` + `Composer` 两个 PR 但同 milestone？→ **建议拆**，回退更可控；issue 决策"一次性合并"的语义可以是"同一个 milestone 同一周内同发"。

---

## 11. Verification Checklist（PR 提交前必跑）

- [ ] `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' build` 通过
- [ ] `xcodebuild -scheme DayPage -destination 'platform=iOS Simulator,name=iPhone 17' test` 通过（含新增 `TodayViewModelTests` / `ComposerStateMachineTests`）
- [ ] 在 iPhone 17 Simulator 上录屏：
  - 主页 idle → fallback 卡（构造 4 种存量数据场景）
  - Composer idle → 文本 → 加照片 → 加位置 → 发送 → 折回 idle
- [ ] 中英文系统语言切换两次，截图无原始 key
- [ ] VoiceOver 朗读发送按钮 5 形态各 1 次
- [ ] Reduced Motion 开启验证 morph 降级
- [ ] `grep -rn "LocalizedStringKey(\"" DayPage/` 输出为 0（除 L10n.swift）
- [ ] `grep -rn "GlassTabBar" DayPage/` 输出为 0
- [ ] 截图前后对比贴入 PR 描述（建议 `assets/before.png` + `assets/after.png`）

---

## 12. References

- 关联 issue：#252 · #250 · #251（Sync 横幅，间接相关）
- 关联 PRD：`tasks/prd-daypage-v4-liquid-glass.md`（Liquid Glass v4 基线）
- 关联代码：
  - `DayPage/DesignSystem/GlassSurface.swift`（AmbientBackground）
  - `DayPage/Features/Today/DayOrbView.swift`
  - `DayPage/Features/Today/TodayView.swift`
  - `DayPage/Features/Today/TodayViewModel.swift`
  - `DayPage/Features/Today/InputBarV4.swift`
  - `DayPage/Components/EmptyStateView.swift`
  - `DayPage/Components/GlassTabBar.swift`（待删）
  - `DayPage/DesignSystem/Haptics.swift`
  - `DayPage/Resources/{zh-Hans,en}.lproj/Localizable.strings`
- 设计灵感：Apple Notes Quick Note · Things 3 Composer · Bear 2 · iA Writer Focus · Day One Today tab
