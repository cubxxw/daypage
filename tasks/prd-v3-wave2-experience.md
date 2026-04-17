# PRD: DayPage V3 Wave 2 — 体验细节打磨

> **生成日期**：2026-04-17
> **来源**：用户 dogfood 反馈 → 5 个 GitHub issue（[#66](https://github.com/getyak/daypage/issues/66) [#67](https://github.com/getyak/daypage/issues/67) [#68](https://github.com/getyak/daypage/issues/68) [#69](https://github.com/getyak/daypage/issues/69) [#70](https://github.com/getyak/daypage/issues/70)）+ DashScope 官方文档核实
> **目标版本**：v3.1（v3 主线的第二个 Wave）
> **预期工时**：1 个 Wave（约 1 周）
> **关联 PRD**：`prd-daypage-v3-experience.md`（v3 主线）
> **状态**：**待主理人对 Open Questions 拍板后开干**

---

## 1. Introduction / Overview

V3 Wave 1（`#60-#62`）解决了"语音转写丢数据 / 编译错误无反馈 / API key 健康检查"三个**功能可用性**问题。
Wave 2 处理用户在 Wave 1 之后立刻反馈出来的 **5 个体验阻断**：

| # | 问题 | 用户原话 | 严重度 |
|---|---|---|---|
| 1 | DashScope 编译 404 | "编译一直 404" | **P0 — 核心功能瘫痪** |
| 2 | Archive 点击过往日期白屏/崩溃 | "只能强制退出" | **P0 — Archive 无法用** |
| 3 | 编译进行中三处提示同时出现 | "悬框一直在提醒，影响审美" | P1 — 视觉污染 |
| 4 | 编译入口在 timeline 中间太抢戏 | "应该放在最下面，比较小、优雅" | P1 — 信息架构 |
| 5 | 输入框丑 + 语音交互不顺手 | "参考 Fromm，长按语音、上滑取消、左滑转文字" | P1 — 核心交互 |

**这份 PRD 不引入新功能**，全部围绕"把已有动线做到精致"。所有改动都是对**用户已经在做的事**的优化。

---

## 2. Goals

### 产品目标
- **G1（编译能用）**：删除 DashScope 调用的 404 阻断，编译成功率从当前 0% → 95%+（不含网络抖动）
- **G2（Archive 不崩）**：Archive 任意日期可点击，无白屏、无崩溃，空态友好
- **G3（编译提示统一）**：编译过程中屏幕上有且只有 1 处状态指示（当前是 3 处）
- **G4（输入区可对标 Fromm）**：输入框、附件入口、长按语音体感与 Fromm / 微信同档次
- **G5（编译入口隐于无形）**：从 timeline 中"硬塞的卡片"变成"滚到底部才看见的优雅按钮"

### 体验目标
- 用户从打开 app 到记完一条语音 ≤ 3 秒（按住、说、松手即发）
- Archive 点过去任意一天，0 崩溃 / 0 白屏
- 编译时用户**一眼就知道在编译**，但**不会被悬浮元素打断阅读**

### 工程目标
- DashScope baseURL 配置统一从 `Secrets.swift` 走，删除硬编码默认值的踩坑陷阱
- `DayDetailView` 三态明确（compiled / rawOnly / empty），每一态有 unit test
- 输入框组件化彻底：`InputBarV2` / `AttachmentMenuPopover` / `PressToTalkButton` / `RecordingOverlayView` 各自独立可测

---

## 3. User Stories

### US-W2-001：DashScope baseURL 修正 + 失败可观测

**Description**：作为用户，我希望点击「编译今日」后真的能编译出 daily page，而不是看到一个无声的 404。
作为开发者，我希望编译失败时**日志里能一眼看出 URL / status / response body**，而不是猜。

**根因**（来自调研）：
`CompilationService.swift:352` 默认 baseURL 写的是 `https://coding.dashscope.aliyuncs.com/v1`，
这个域名是阿里云**通义灵码 Coding Plan 专用端点**，必须配 `BAILIAN_CODING_PLAN_API_KEY`。
普通 DashScope key 调它必返 404。正确通用入口是 `https://dashscope.aliyuncs.com/compatible-mode/v1`。

**Acceptance Criteria**：
- [ ] `CompilationService.swift` 默认 baseURL 改为 `https://dashscope.aliyuncs.com/compatible-mode/v1`
- [ ] `CLAUDE.md` 第 30 行同步修正
- [ ] DashScope 调用失败时，在 DEBUG 构建打印 `URL / HTTP status / response body 前 500 字符`
- [ ] 用真实 DashScope key 跑一次编译，daily page 成功生成
- [ ] `xcodebuild -scheme DayPage build` 通过

---

### US-W2-002：Settings 增加「测试 API 连接」按钮

**Description**：作为用户，我希望在配 API key 时能立刻知道这个 key 是否真的能用，而不是要等到当晚 02:00 编译失败才发现。

**Acceptance Criteria**：
- [ ] Settings 页面，在 DashScope key 输入框下方增加「测试连接」按钮
- [ ] 点击后向 `{baseURL}/chat/completions` 发一个最小 prompt（如 `[{"role":"user","content":"hi"}]`，max_tokens=1）
- [ ] 成功显示绿色 ✓「连接成功 · 模型 xxx」；失败显示红色 ✗ + HTTP status + 提示信息
- [ ] 失败提示按错误类型给修复建议：
  - 401/403 → "API key 无效或权限不足"
  - 404 → "URL 不存在，检查 baseURL 是否为 `https://dashscope.aliyuncs.com/compatible-mode/v1`"
  - 网络超时 → "网络不可达，检查代理"
- [ ] `xcodebuild -scheme DayPage build` 通过

---

### US-W2-003：删除三处冗余编译提示，统一到 CompilePromptCard

**Description**：作为用户，我不希望编译时有 3 个地方同时告诉我"正在编译"。屏幕上有 1 处足够了。

**当前现状**：
- `TodayView.swift:69-72` Header 的 `CompilingBadge`
- `MemoCardView.swift:708, 720` Timeline 卡片的两条文字
- `TodayViewModel.swift:463` BannerCenter 浮动横幅

**Acceptance Criteria**：
- [ ] 删除 `TodayViewModel.swift:463` 的编译进行中 Banner（成功/失败 Banner 保留）
- [ ] 删除 `TodayView.swift:69-72` 的 `CompilingBadge`
- [ ] `CompilePromptCard` 编译态合并为一行：`正在编译 N 条 memo · [进度条 / 旋转图标]`
- [ ] 编译完成 / 失败仍用 BannerCenter 闪一次提示
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：在 Simulator 触发编译，屏幕上有且只有 1 处「正在编译」提示

---

### US-W2-004：编译入口下移 — 滚到底部才优雅淡入

**Description**：作为用户，我不希望「编译卡片」直接霸占 timeline 第二位。它应该藏起来，等我浏览完今日所有 memo、滚到接近底部时才优雅出现。

**设计**（用户选择 2B：滚动触发出现）：
- 删除 `TodayView.swift:158-171` timeline 中的 `CompilePromptCard`
- 新建 `CompileFooterButton`：胶囊状，半透明背景 + 1pt 描边，左 sparkle 图标 + 右文字「编译今日 · N 条」
- 出现条件：`!isDailyPageCompiled && memoCount > 0` **且** ScrollView 滚动到 `contentHeight - 200pt` 以内
- 出现动画：spring 弹入；滚回顶部时再淡出
- 编译态：替换为「正在编译 N 条 memo · 进度条」（与 US-W2-003 保持一致）
- 编译完成：淡出消失

**Acceptance Criteria**：
- [ ] 新建 `Features/Today/CompileFooterButton.swift`
- [ ] Timeline 内不再有 `CompilePromptCard`
- [ ] 用 `ScrollViewReader` + `GeometryReader` 跟踪滚动位置
- [ ] 滚到接近底部 → spring 弹入；滚回顶部 → 淡出（动画 < 300ms）
- [ ] 编译中：按钮变进度态、不可点
- [ ] 编译完成：自动消失
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：在 Simulator 滚动测试，按钮出现/消失节奏自然，无视觉抖动

---

### US-W2-005：InputBar V2 视觉重设计 + Fromm 风加号面板

**Description**：作为用户，我希望输入框看起来像 Fromm，而不是裸 `TextEditor`。所有附件入口集中在一个 `+` 按钮里，点击展开浮窗菜单。

**设计**：

```
静态态：
┌────────────────────────────────────────────┐
│  [+]   想记点什么…                  [🎤]  │
└────────────────────────────────────────────┘

+ 展开（spring 弹出，点外部关闭）：
       ┌──────────────────────┐
       │ 📷 拍照              │
       │ 🖼  从相册选          │
       │ 📁 附件              │
       │ 📍 位置              │
       └──────────────────────┘
       [+]
```

**Acceptance Criteria**：
- [ ] 新建 `Features/Today/InputBarV2.swift`，与旧 `InputBarView` 并存（feature flag 切换）
- [ ] 输入条样式：cornerRadius 18、1pt 描边（`DSColor.outlineVariant`）、垂直内边距 10pt
- [ ] 左侧 `+` 按钮：圆形 36pt
- [ ] 新建 `Features/Today/AttachmentMenuPopover.swift` — 4 项菜单（拍照 / 相册 / 文件 / 位置）
- [ ] 输入态（用户开始打字）：麦克风 → 发送按钮、附件 carousel 上方显示
- [ ] 删除原 keyboard accessory 的 5 个图标
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：静态态视觉对标 Fromm；`+` 展开顺滑

---

### US-W2-006：长按麦克风录音 + 上滑取消 + 左滑转文字

**Description**：作为用户，我希望按住麦克风就开始录音、松手就发送，无需任何二次确认；同时支持微信式上滑取消，多一个**左滑转文字**的高级选项。

**交互细节**（用户选择 3B）：

| 手势 | 行为 | 反馈 |
|---|---|---|
| 按下 🎤 | 立即开始录音 | 轻 haptic + 屏底浮起黑色面板（波形 + 计时） |
| 保持按住 | 持续录音 | 实时波形（`AVAudioRecorder.averagePower`） |
| 松手（在原位） | 停止 + 立即发送 | 中等 haptic + 面板消失 |
| 上滑 ≥ 80pt | 进入"取消"预备态 | 强 haptic + 面板变红 + "↑ 松手取消" |
| 左滑 ≥ 80pt | 进入"转文字"预备态 | 中等 haptic + 面板变蓝 + "← 松手转文字" |
| 在取消态松手 | 丢弃录音 | 弱 haptic + 面板消失 |
| 在转文字态松手 | 调用 Whisper 转文字、把结果填回 TextEditor，**不直接发送** | 中等 haptic + 转写中 spinner |

**Acceptance Criteria**：
- [ ] 新建 `Features/Today/PressToTalkButton.swift` — 用 `DragGesture(minimumDistance: 0)` + `@GestureState` 跟踪
- [ ] 新建 `Features/Today/RecordingOverlayView.swift` — 全屏底部浮层，3 态（录音中 / 取消预备 / 转文字预备）
- [ ] 实时波形从 `AVAudioRecorder.averagePower(forChannel: 0)` 读取，每 50ms 更新
- [ ] 阈值 80pt 在 `Features/Today/Tokens.swift`（或 `DSTokens`）集中
- [ ] 三种 haptic 强度 (`UIImpactFeedbackGenerator` light/medium/heavy) 区分
- [ ] 转文字路径复用 `VoiceService.transcribe(audioURL:)`，结果填入 `TodayViewModel.draftText`
- [ ] 旧 `VoiceRecordingView` sheet 保留为兜底（可被 Settings 项关闭）
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：在 Simulator 真机各跑一次按下→松手 / 上滑取消 / 左滑转文字

---

### US-W2-007：DayDetailView 三态健壮化 + dateString 格式校验

**Description**：作为用户，点击 Archive 任何日期都不应该白屏或崩溃。没记录的日期要给友好空态。

**根因**（来自调研）：
- `DayDetailView.swift:20-30` 用 computed property 同步 IO 检查文件，body 渲染时反复调用
- 三态 (`compiled` / `rawOnly` / `empty`) 中的 `empty` 态没有 UI，可能返回空 body 导致白屏
- 下游 `DailyPageView` / `RawMemoView` 假设文件一定存在，强解析失败可能崩溃
- `dateString` 无格式校验

**Acceptance Criteria**：
- [ ] `DayDetailView` 重构：把文件检查从 computed property 移到 `@State` + `onAppear` 异步加载
- [ ] 显式三态：`.compiled` / `.rawOnly` / `.empty` / `.error`，每态有独立 view
- [ ] `.empty` 态：插画 + 「这一天还没有记录」文案 + 「关闭」按钮
- [ ] `.error` 态：错误图标 + 错误描述 + 「关闭」按钮
- [ ] `dateString` init 时用 regex `^\d{4}-\d{2}-\d{2}$` 校验，不合法直接 `.error`
- [ ] `DailyPageView` / `RawMemoView` init 检查文件存在，失败 fallthrough 到 `.error`
- [ ] 任何文件 IO 失败打印完整路径 + errno
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：构造 `dateString = "2020-01-01"`（必无文件），点击不崩溃、显示 `.empty` 态

---

### US-W2-008：Archive 日历区分有数据 / 无数据日期

**Description**（用户选择 4D — A+C 组合）：作为用户，我希望日历上一眼看出哪些日期有记录、哪些没有。无记录的日期半透明显示，**仍可点击**进去看空态。

**Acceptance Criteria**：
- [ ] `ArchiveView` 加载日历时，预扫描 `vault/raw/` 与 `vault/wiki/daily/` 文件列表，缓存到 `@State` Set
- [ ] 日历单元格：
  - 有 daily：实心高亮
  - 仅有 raw：圆点 dot 标记
  - 都没有：50% 透明灰
- [ ] 所有日期（含无数据）都可点击 → 进入 `DayDetailView`，由其负责显示对应态
- [ ] 预扫描在 `onAppear` 异步执行，不阻塞 UI
- [ ] `xcodebuild -scheme DayPage build` 通过
- [ ] **手动验证**：日历视觉清晰区分三种态；点击任何日期都正常进入

---

### US-W2-009：DayDetailView Unit Tests

**Description**：作为开发者，我希望 `DayDetailView` 的三态逻辑被测试覆盖，避免下次回归。

**Acceptance Criteria**：
- [ ] 新建 `DayPageTests` target（如尚未存在），用 Swift Testing
- [ ] 测试 `dateString = "2020-01-01"`（无任何文件）→ `.empty`
- [ ] 测试 `dateString = "abc"`（格式错误）→ `.error`
- [ ] 测试在 mock vault 写入 raw 文件 → `.rawOnly`
- [ ] 测试在 mock vault 同时写入 raw + daily → `.compiled`
- [ ] 测试 vault 路径损坏 → `.error`，不 crash
- [ ] `xcodebuild -scheme DayPage test` 通过

---

## 4. Functional Requirements

### 编译路径
- **FR-1**：DashScope baseURL 默认值为 `https://dashscope.aliyuncs.com/compatible-mode/v1`
- **FR-2**：DashScope 调用失败必须打印 `[DashScope] URL=... status=... body=...`（DEBUG 构建）
- **FR-3**：Settings 提供「测试连接」按钮，发最小请求验证 key 可用性
- **FR-4**：编译进行中，屏幕上**有且只有 1 处**视觉指示（即 `CompileFooterButton` 的进度态）
- **FR-5**：编译完成 / 失败 用 BannerCenter 闪一次（保留 Wave 1 的反馈机制）

### 编译入口位置
- **FR-6**：Timeline 中**不再有**编译卡片
- **FR-7**：`CompileFooterButton` 出现条件：`!isDailyPageCompiled && memoCount > 0 && scrollOffset 接近底部`
- **FR-8**：按钮出现 / 消失用 spring 动画，duration 200-300ms

### 输入区
- **FR-9**：`InputBarV2` 默认启用（feature flag `useInputBarV2 = true`）
- **FR-10**：附件入口集中在左侧 `+` 按钮，展开 4 项浮窗菜单
- **FR-11**：长按麦克风触发录音，松手即发送，无二次确认
- **FR-12**：录音中上滑 ≥ 80pt 进入取消预备态，松手丢弃
- **FR-13**：录音中左滑 ≥ 80pt 进入转文字预备态，松手调用 Whisper、结果填回 TextEditor 不发送
- **FR-14**：录音中实时显示音量波形，更新频率 ≥ 20Hz

### Archive
- **FR-15**：`DayDetailView` 必须实现 4 态：`.compiled` / `.rawOnly` / `.empty` / `.error`
- **FR-16**：`dateString` 必须校验格式 `^\d{4}-\d{2}-\d{2}$`
- **FR-17**：Archive 日历必须区分「有 daily / 仅 raw / 无数据」三种视觉态
- **FR-18**：日历任何日期都可点击，由 `DayDetailView` 决定显示哪一态

---

## 5. Non-Goals (Out of Scope)

- ❌ 不引入新的 AI 能力（不做 prompt 优化、不换模型、不加多轮对话）
- ❌ 不动 Background Compilation 调度逻辑（02:00 daily 编译保持现状）
- ❌ 不重构 `VoiceService` / `WhisperAPI` 的转写实现（只复用）
- ❌ 不动 Graph Tab（继续 Post-MVP）
- ❌ 不做 onboarding（V3 Wave 1 已做）
- ❌ 不做 iCloud 同步（独立 issue #64）
- ❌ 不做日历的「连续打卡」「streak」可视化
- ❌ 输入框不引入富文本编辑（继续纯 Markdown）
- ❌ 编译按钮不做"右滑展开高级选项"（保持单一动作）

---

## 6. Design Considerations

### 视觉对标
- **InputBarV2**：参考 Fromm（Threads-like 加号展开）+ 微信（长按语音 + 上滑取消）
- **CompileFooterButton**：参考 Linear / Raycast 的浮动 action button — 半透明、轻描边、不抢戏
- **DayDetailView 空态**：参考 Bear 的空态 — 一行短文 + 一个图标，不要插画师产物

### Design Token 复用
- 颜色全部走 `DSColor`（`primary` / `surfaceContainer` / `outlineVariant` / `error`）
- 字体走 `DSFonts` / `Typography`
- 圆角统一 `DSRadius.medium = 18pt`、`DSRadius.large = 24pt`
- 间距走 `DSSpacing`（4 / 8 / 12 / 16 / 24 / 32）

### 动画规范
- spring response 0.35、damping 0.85（默认）
- 淡入/淡出 duration 200ms
- haptic：light（开始/取消）/ medium（发送/转文字预备）/ heavy（取消预备）

---

## 7. Technical Considerations

### 风险点
1. **`DragGesture(minimumDistance: 0)` 与 ScrollView 冲突**：长按麦克风的手势可能被外层 ScrollView 抢走 → 需要 `.simultaneousGesture` 或 `.highPriorityGesture` 调整
2. **Whisper API 转写延迟**：转文字路径预期 1-3 秒，期间 UI 需要清晰的 loading 态
3. **Archive 日历预扫描性能**：`vault/raw/` 文件多时可能阻塞 → 必须异步 + 缓存
4. **`InputBarV2` 与旧版本切换**：feature flag 应可在 Settings 切换，便于对比 / 回滚

### 依赖关系
- US-W2-001 / 002 不依赖其他 story，可并行
- US-W2-003 必须在 US-W2-004 之前（先删提示再加新按钮，避免叠 4 处提示）
- US-W2-005 必须在 US-W2-006 之前（先有 InputBarV2 框架，再加录音手势）
- US-W2-007 必须在 US-W2-008 之前（先有健壮 DayDetailView，日历再放开点击）
- US-W2-009 在 US-W2-007 / 008 完成后做

### 技术债清理
- 删除 `Secrets.dashScopeBaseURL` 默认空值的踩坑设计 — 改为强制读取 `Config/GeneratedSecrets.swift` 的固定值
- 删除 `CompilingBadge` 组件本身（如果别处也没人用）

---

## 8. Success Metrics

### 上线后 1 周观测
- **编译成功率**：从 0%（404）→ ≥ 95%（不含网络）
- **Archive 崩溃率**：从「点过往日期必崩」→ 0 崩溃
- **编译入口可发现性**：用户在不被告知的情况下，能在 30 秒内找到编译按钮
- **语音录制完成时间**：从「点击 → 弹 sheet → 录 → 确认」≥ 5 秒 → 「按住 → 松手」≤ 3 秒

### 工程指标
- 所有 9 个 US 的 Acceptance Criteria 100% 勾完
- `xcodebuild -scheme DayPage build` 全绿
- `DayPageTests` 新增的测试用例 100% 通过

### 用户口头反馈目标
- 不再听到"编译又 404 了"
- 不再听到"点 Archive 怎么白屏"
- 不再听到"输入框丑"
- 不再听到"编译卡片好碍眼"

---

## 9. Open Questions

1. **`CompileFooterButton` 是否需要 Settings 开关**？让用户在「sticky 按钮 / 滚动出现 / 不显示按钮（只能从 Settings 触发）」之间切？
   - 当前默认：滚动出现，无开关（保持简单）

2. **左滑转文字结果**是否要在 TextEditor 里显示「↶ 撤销转写」浮按钮？避免用户后悔。
   - 倾向：是，做一个简单的撤销按钮

3. **InputBarV2 feature flag 默认状态**：默认开启 V2 还是默认旧版？
   - 倾向：默认 V2，Settings 提供「使用旧版输入框」开关

4. **Archive 日历无数据日期是否真的允许点击**？还是无数据就半透明 + 禁用？
   - 当前选择（4D）：允许点击，进入 `.empty` 态。但要不要给一个「补一条」快捷按钮跳回 Today？
   - 倾向：先不加，避免修改 Today 的日期上下文

5. **DashScope baseURL 修正后，老用户的 `Secrets.dashScopeBaseURL` 自定义配置如何处理**？
   - 倾向：保留尊重，只改默认值。已配 `coding.*` 的用户启动时 BannerCenter 提示「检测到您配置的是 Coding Plan 端点，需匹配 Coding Plan key」

---

## 10. 关联 Issue 与 Wave 拆分

| US | 对应 Issue | 优先级 | 估时 |
|---|---|---|---|
| US-W2-001 | [#66](https://github.com/getyak/daypage/issues/66) | P0 | 0.5d |
| US-W2-002 | [#66](https://github.com/getyak/daypage/issues/66) 衍生 | P1 | 0.5d |
| US-W2-003 | [#67](https://github.com/getyak/daypage/issues/67) | P1 | 0.5d |
| US-W2-004 | [#68](https://github.com/getyak/daypage/issues/68) | P1 | 1d |
| US-W2-005 | [#69](https://github.com/getyak/daypage/issues/69) | P1 | 1.5d |
| US-W2-006 | [#69](https://github.com/getyak/daypage/issues/69) | P1 | 2d |
| US-W2-007 | [#70](https://github.com/getyak/daypage/issues/70) | P0 | 1d |
| US-W2-008 | [#70](https://github.com/getyak/daypage/issues/70) 衍生 | P2 | 0.5d |
| US-W2-009 | [#70](https://github.com/getyak/daypage/issues/70) 衍生 | P2 | 0.5d |

**总估时**：8 人天，1 人 Wave（1 周）含 review / dogfood 缓冲。

**建议执行顺序**：
1. Day 1：US-W2-001（解 P0 阻断）+ US-W2-007（解 P0 崩溃）
2. Day 2：US-W2-002 + US-W2-008
3. Day 3：US-W2-003 + US-W2-004
4. Day 4-5：US-W2-005 + US-W2-006（输入区双 story 是大头）
5. Day 6：US-W2-009（测试补全）+ dogfood
6. Day 7：缓冲 / review / merge

---

## 11. Acceptance Definition of Done（整体）

- [ ] 所有 9 个 US Acceptance Criteria 100% 勾完
- [ ] `xcodebuild -scheme DayPage build` 全绿
- [ ] `xcodebuild -scheme DayPage test` 全绿（含新增的 DayPageTests）
- [ ] 主理人 dogfood 1 天，确认 5 个原始痛点全部消失
- [ ] 9 个 US 对应的 5 个 issue (#66-#70) 全部 close
- [ ] CHANGELOG 增加 v3.1 段落
- [ ] 主分支打 tag `v3.1.0`
