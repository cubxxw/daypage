# PRD: DayPage v2 全量路线图

> **来源**：GitHub Issues #30–#53（24 个 OPEN issue 整合）
> **生成日期**：2026-04-17
> **目标版本**：DayPage v2.0（v1.x = 已发布 MVP）
> **交付节奏**：滚动交付（no hard deadline），按 Wave 分批推进

---

## 1. Introduction / Overview

DayPage 当前 MVP 已上线 TestFlight，但存在一批影响日常使用的 bug（导航死链、UI 接线缺失、后台任务静默失败），以及几个核心价值未完全兑现的方向——特别是**位置系统**（nomad 用户核心场景）、**AI 编译可靠性**、**Graph 知识网络**。

本 PRD 将 24 个 open issue 归为 **5 个 Wave**，按「先稳住地基、再补完整性、最后扩能力」的顺序交付。每个 Wave 可独立上线一个 TestFlight build。

---

## 2. Goals

### 产品目标
- **G1（稳定性）**：消除所有导航死链和装饰性按钮，Today / Archive / Entity / Daily Page 四张核心页面的交互完全可用
- **G2（可靠性）**：AI 编译失败、离线、API Key 缺失等异常场景有明确 UI 反馈和恢复路径
- **G3（位置价值）**：被动位置感知 + 草稿确认流跑通，nomad 用户无需主动输入即可记录足迹
- **G4（内容完整）**：Daily Page 支持重编译 / 元数据编辑，Timeline Tab 渲染结构化 memo 卡片
- **G5（知识网络）**：Graph Tab 上线，实体节点可视化 + 关系连线 + 点击跳转 Entity Page

### 量化目标
- 后台编译成功率 ≥ 95%（失败自动重试 3 次）
- 用户日均位置草稿确认率 ≥ 60%
- Graph Tab 日均打开次数 ≥ 1（核心用户）
- 所有 P0/P1 bug 修复率 100%

---

## 3. 优先级与 Wave 划分（我的建议）

| Wave | 主题 | Issue 数 | 估时 | 核心价值 |
|---|---|---|---|---|
| **W1** | 地基稳定化（bug fix + 接线） | 9 | 1-2 周 | 让现有功能真正可用 |
| **W2** | AI 编译可靠性 + 异常反馈 | 3 | 1 周 | 让用户信任后台流程 |
| **W3** | 位置系统重做 | 4 | 2-3 周 | 兑现 nomad 核心价值 |
| **W4** | Daily Page / Archive / 搜索完整性 | 4 | 2 周 | 让内容管理闭环 |
| **W5** | 输入栏扩展 + Graph Tab | 4 | 3-4 周 | 扩展能力边界 |

**排序依据**：
1. **用户影响 > 技术风险**：W1-W2 优先修复日常流程中的死链和信任问题
2. **依赖关系**：W3（位置）必须先过 W2（异常反馈），否则后台失败无提示会劝退用户
3. **风险前置**：W3 涉及 Always 授权和后台耗电，放中段以便有充足时间打磨
4. **探索性任务后置**：Graph（W5）复杂度高、设计未定，放最后

---

## 4. User Stories

### 🌊 Wave 1：地基稳定化（9 个 story）

#### US-101: 修复 Wikilink 跳转 (#32)
**Description**: As a user, I want to click `[[Entity]]` links in Daily Page and Entity Page so that I can navigate the knowledge network.

**Acceptance Criteria:**
- [ ] Daily Page 内 `[[Entity]]` 文本渲染为可点击链接（下划线或 accent 色）
- [ ] 点击跳转到对应 Entity Page（若不存在则创建空 Entity Page）
- [ ] Entity Page 内 `[[Entity]]` 同样可点击
- [ ] Typecheck/build passes
- [ ] Verify in Simulator

#### US-102: 修复 Archive 日历未编译日期点击无响应 (#33)
**Description**: As a user, I want to tap any date cell on the calendar—even if it's not yet compiled—so I can view raw memos.

**Acceptance Criteria:**
- [ ] 未编译日期单元格可点击
- [ ] 点击导航到"原始 memo 浏览"视图（显示该日所有 memo，按时间排序）
- [ ] 空白日期点击提示"该日无记录"
- [ ] Verify in Simulator

#### US-103: 修复 Archive 列表视图未编译日期无法查看原始 memo (#48)
**Description**: As a user, I want the list view to also allow opening uncompiled dates so behavior matches the calendar.

**Acceptance Criteria:**
- [ ] 列表视图中未编译日期行可点击，行为与 US-102 一致
- [ ] 复用同一"原始 memo 浏览"视图
- [ ] Verify in Simulator

#### US-104: 修复 Entity Page 关联条目点击无响应 (#39)
**Description**: As a user, I want to click a date entry in an Entity Page's related-entries list so I jump to that Daily Page.

**Acceptance Criteria:**
- [ ] 关联条目列表行点击响应（添加 `onTapGesture` 或 `NavigationLink`）
- [ ] 导航到对应日期的 Daily Page
- [ ] Verify in Simulator

#### US-105: Entity Page → Daily Page 返回导航 / 面包屑 (#49)
**Description**: As a user, I want a clear back path from Entity Page to the Daily Page I came from.

**Acceptance Criteria:**
- [ ] Entity Page 顶部显示面包屑 `< [来源 Daily Page 日期]` 或标准 back button
- [ ] 点击返回到来源 Daily Page（保留滚动位置）
- [ ] 通过 Tab 切换进入的 Entity Page 不显示面包屑
- [ ] Verify in Simulator

#### US-106: Daily Page Timeline Tab 渲染结构化 memo 卡片 (#31)
**Description**: As a user, I want Timeline Tab to render memo cards (text / voice / photo / location) with the same styling as Today view, not plain text dump.

**Acceptance Criteria:**
- [ ] Timeline Tab 复用 Today view 的 memo 卡片组件
- [ ] 支持 text / voice / photo / location 四种类型渲染
- [ ] 语音卡片有播放按钮，照片卡片显示缩略图
- [ ] 与 Today view 视觉一致（时间贯通竖线、间距、字体）
- [ ] Verify in Simulator

#### US-107: Daily Page 语音时长 Chip 修复 (#47)
**Description**: As a user, I want the voice duration chip in Daily Page metadata to actually show duration, not be invisible.

**Acceptance Criteria:**
- [ ] 识别当日 memo 中所有语音附件，汇总总时长
- [ ] Chip 显示 "🎙️ 12:34"（总时长 mm:ss）
- [ ] 无语音 memo 时 Chip 不显示（当前返回 EmptyView 是对的，但有语音时也不显示是 bug）
- [ ] Verify in Simulator

#### US-108: 接线汉堡菜单按钮 (#34)
**Description**: As a user, I want the hamburger button to actually do something (or be removed if undecided).

**Acceptance Criteria:**
- [ ] 点击打开 Side Drawer 或 Sheet，列出：Archive 入口、Graph 入口、设置入口
- [ ] **[或]** 若暂不实现，直接从 UI 移除该按钮（与设计稿确认）
- [ ] Verify in Simulator

#### US-109: 接线设置图标按钮 (#35)
**Description**: As a user, I want the settings icon to open a Settings screen where I can manage API keys, permissions, and preferences.

**Acceptance Criteria:**
- [ ] 点击打开 Settings 视图（新建 `SettingsView.swift`）
- [ ] Settings 包含分区：API Keys（DashScope / OpenAI / OpenWeather 状态展示）、位置权限、通知权限、关于 / 版本号
- [ ] API Key 未配置时显示"未配置"红色徽章
- [ ] Verify in Simulator

---

### 🌊 Wave 2：AI 编译可靠性 + 异常反馈（3 个 story）

#### US-201: 后台编译失败重试 + 用户通知 (#40)
**Description**: As a user, I want background compilation failures to retry automatically and notify me if they still fail, instead of silently disappearing.

**Acceptance Criteria:**
- [ ] `BackgroundCompilationService` 失败时重试 3 次（exponential backoff: 30s / 2min / 10min）
- [ ] 三次都失败后发本地通知："今日编译失败，点击查看"
- [ ] 点击通知进入 Today View 并显示错误横幅 + "重试"按钮
- [ ] 记录失败原因到 log（API 错误 / 网络错误 / JSON 解析错误分别归类）
- [ ] Unit test 覆盖重试逻辑
- [ ] Verify in Simulator

#### US-202: AI 编译进度反馈 UI (#38)
**Description**: As a user, I want to see that AI compilation is in progress, not just a frozen UI.

**Acceptance Criteria:**
- [ ] 手动触发编译时，Daily Page 显示进度状态："正在分析 N 条 memo..." / "正在生成 Daily Page..." / "完成"
- [ ] 使用 `ProgressView` + 动画文字
- [ ] 后台编译不打扰，但 Today View 顶部显示小徽章"正在编译..."
- [ ] 编译耗时 > 5s 时显示取消按钮
- [ ] Verify in Simulator

#### US-203: API Key 未配置 / 离线 UI 提示 (#41)
**Description**: As a user, I want clear feedback when the app can't reach AI / weather / transcription services, so I understand why features aren't working.

**Acceptance Criteria:**
- [ ] 启动时检查三个 API key（DashScope / OpenAI / OpenWeather），任一缺失时 Today View 顶部显示 banner："部分功能需要配置 API Key，前往设置"
- [ ] 点击 banner 跳转 Settings（US-109）
- [ ] 离线时语音转写、AI 编译、天气获取分别显示"离线，稍后自动重试"
- [ ] 网络恢复后自动重试队列
- [ ] Verify in Simulator

---

### 🌊 Wave 3：位置系统重做（4 个 story）

#### US-301: 位置权限升级到 Always + 后台模式 (#51)
**Description**: As a developer, I need to request Always location authorization and enable background location mode so CLVisitor can run passively.

**Acceptance Criteria:**
- [ ] `Info.plist` 添加 `NSLocationAlwaysAndWhenInUseUsageDescription` 与 `UIBackgroundModes: location`
- [ ] 首次进入 Today 仍先请求 When-In-Use；在用户触发"启用被动位置"开关（Settings 中）时升级到 Always
- [ ] 升级授权流程有说明弹窗，阐明隐私用途 + 电量影响
- [ ] 授权状态在 Settings 中可见可修改
- [ ] Typecheck passes

#### US-302: CLVisitor 被动位置感知 (#50)
**Description**: As a nomad user, I want the app to automatically detect when I arrive at and leave significant places, without draining my battery.

**Acceptance Criteria:**
- [ ] 新建 `PassiveLocationService.swift`，使用 `CLLocationManager.startMonitoringVisits()`
- [ ] `didVisit` 回调中保存 `VisitDraft { id, arrivalDate, departureDate?, coordinate, accuracy }` 到 `VisitDraftStore`（文件持久化 `vault/drafts/visits.json`）
- [ ] 到达事件异步反向地理编码，缓存地名
- [ ] 授权为 Always 时才启动，降级到 When-In-Use 时自动停止
- [ ] 每日凌晨清理 7 天前的 dismissed drafts
- [ ] Unit test: Draft 持久化 + 去重 + 清理逻辑

#### US-303: Today View 自动位置草稿确认卡片 (#52)
**Description**: As a user, I want to see passively-detected visits as a draft card in Today, confirm or dismiss them in bulk or individually.

**Acceptance Criteria:**
- [ ] Today View 顶部显示 `LocationDraftCard`，列出当天所有 pending drafts
- [ ] 每行显示：到达时间（HH:mm）、地名、停留时长（"约 2 小时"）
- [ ] 行级按钮：✓ 确认 / ✕ 忽略
- [ ] 卡片底部：[全部确认] [全部忽略]
- [ ] 确认 → 创建 `.location` memo 写入当日 `.md`
- [ ] 忽略 → `markDismissed`
- [ ] 地名可点击编辑（反向地理编码可能不准）
- [ ] 无 pending drafts 时卡片不显示
- [ ] Verify in Simulator

#### US-304: 位置附件 Chip 地图预览 (#46)
**Description**: As a user, I want to preview a location attachment on a map instead of only being able to delete it.

**Acceptance Criteria:**
- [ ] 位置 Chip 点击弹出 Sheet，显示 MapKit 静态地图（标注坐标 + 地名）
- [ ] Sheet 底部保留"删除附件"按钮（原清除行为移到这里）
- [ ] Sheet 支持"在 Apple Maps 中打开"
- [ ] Verify in Simulator

---

### 🌊 Wave 4：Daily Page / Archive / 搜索完整性（4 个 story）

#### US-401: Daily Page 重新编译 / 元数据编辑 (#43)
**Description**: As a user, I want to re-run AI compilation on a past day if I'm unhappy with the result, and manually edit metadata (mood, weather, cover image).

**Acceptance Criteria:**
- [ ] Daily Page 右上角"更多"菜单添加 [重新编译] [编辑元数据] 选项
- [ ] 重新编译：调用 `CompilationService` 重新生成，确认弹窗 "将覆盖当前内容，确定？"
- [ ] 编辑元数据：Sheet 表单允许修改 mood、weather、cover image
- [ ] 编辑后 YAML front-matter 原子写入
- [ ] Verify in Simulator

#### US-402: 搜索高级筛选 (#45)
**Description**: As a user searching my archive, I want filters for date range, memo type, and location so I can narrow down results.

**Acceptance Criteria:**
- [ ] 搜索页顶部添加筛选栏：日期范围 picker、类型多选（text/voice/photo/location）、地点过滤
- [ ] 筛选与关键词并存，结果实时更新
- [ ] 筛选状态保存在 URL query（或 session state）
- [ ] 空结果显示 empty state
- [ ] Verify in Simulator

#### US-403: Archive 月度统计筛选 / 导出 / 分享 (#44)
**Description**: As a user reflecting on a month, I want to filter the monthly summary and export / share it.

**Acceptance Criteria:**
- [ ] 月度摘要页添加筛选：仅显示有位置的日期 / 仅显示有照片的日期
- [ ] "导出"按钮：生成 Markdown 文件（包含所有 memo 和 Daily Page），通过 `UIActivityViewController` 分享
- [ ] "分享"按钮：截图当前月度统计页分享
- [ ] Verify in Simulator

#### US-404: 语音 memo 重复转写 bug 修复 (#53)
**Description**: As a user, I want voice transcription to appear only once, not duplicated.

**Acceptance Criteria:**
- [ ] 定位重复来源（`VoiceService` 回调被触发两次 / memo 写入两次 / UI 渲染两次）
- [ ] 修复并添加 unit test 覆盖回归
- [ ] Verify in Simulator（录一条语音，确认转写只出现一次）

#### US-405: 语音录音实时转写文字显示 (#42)
**Description**: As a user recording voice, I want to see live transcription text as I speak, for confidence that it's working.

**Acceptance Criteria:**
- [ ] 录音浮层显示实时转写区域（使用 iOS `SFSpeechRecognizer` 本地识别，或流式 Whisper）
- [ ] 停止录音后，转写文字自动填入 memo
- [ ] 识别失败时回退到传统 Whisper API（录完再转）
- [ ] Verify in Simulator（模拟器用预录音频）

---

### 🌊 Wave 5：输入栏扩展 + Graph Tab（4 个 story）

#### US-501: 输入栏直接拍照 (#36)
**Description**: As a user, I want to take a photo directly from the input bar, not just pick from the library.

**Acceptance Criteria:**
- [ ] 输入栏照片按钮长按 / 次级菜单区分 [拍照] [从相册选择]
- [ ] 拍照使用 `UIImagePickerController` / `AVCaptureSession`
- [ ] 拍摄后走现有 Photo 附件流程（EXIF 提取 + 缩略图）
- [ ] Verify in Simulator（Simulator 无相机，用 `sourceType = .photoLibrary` fallback）+ 真机验证

#### US-502: 输入栏文件附件 (#37)
**Description**: As a user, I want to attach arbitrary files (PDF, text) to memos.

**Acceptance Criteria:**
- [ ] 输入栏添加 "+" 按钮（或替换现有次级菜单），可选文件附件
- [ ] 使用 `UIDocumentPickerViewController`
- [ ] 附件拷贝到 `vault/raw/assets/files/`，YAML 记录 `type: file, path: ..., filename: ...`
- [ ] Daily Page 卡片显示文件图标 + 文件名，点击用系统默认应用打开
- [ ] Verify in Simulator

#### US-503: Graph Tab 节点可视化 + 连线 (#30, Part 1)
**Description**: As a user, I want to see my entities (people, places, topics) as nodes and their connections as edges in Graph Tab.

**Acceptance Criteria:**
- [ ] `RootView.swift` 移除 Graph Tab 的 `.disabled(true)`
- [ ] 新建 `GraphViewModel` 扫描所有 Daily Page 中的 `[[Entity]]` 引用，构建节点 + 边
- [ ] 节点分类：人物（@mention）/ 地点 / 主题（其他 `[[]]`）用不同颜色
- [ ] 使用 SwiftUI Canvas + 力导向布局（可用 SPM 引入 `SwiftUIFlow` 或手写简化版）
- [ ] 支持 pinch 缩放、拖拽平移
- [ ] Verify in Simulator

#### US-504: Graph Tab 点击节点跳转 + 时间轴过滤 + 搜索 (#30, Part 2)
**Description**: As a user, I want to click a node to open its Entity Page, filter the graph by date range, and search for specific nodes.

**Acceptance Criteria:**
- [ ] 节点点击 → 导航到对应 Entity Page
- [ ] 顶部日期范围 picker（默认"最近 30 天"）动态过滤节点
- [ ] 搜索框输入关键词高亮匹配节点
- [ ] 空图谱 empty state："记录更多 memo 以构建你的知识网络"
- [ ] Verify in Simulator

---

## 5. Functional Requirements

### FR-Navigation（导航）
- FR-1: Wikilink `[[Entity]]` 在 Daily Page 和 Entity Page 中均渲染为可点击链接
- FR-2: Archive 日历 / 列表的所有日期单元格（含未编译）均可点击导航
- FR-3: Entity Page 关联条目行均为 `NavigationLink`
- FR-4: Entity Page 顶部显示面包屑 / back button（从 Daily Page 进入时）

### FR-UI 接线
- FR-5: 汉堡菜单、设置图标必须有功能或从 UI 移除
- FR-6: Daily Page Timeline Tab 复用 Today 的 memo 卡片组件
- FR-7: Daily Page 语音时长 Chip 当有语音 memo 时显示总时长

### FR-AI 可靠性
- FR-8: 后台编译失败重试 3 次（30s/2min/10min backoff），最终失败发通知
- FR-9: 手动编译必须有进度反馈 UI
- FR-10: API Key 缺失、离线状态必须有 banner 提示 + Settings 跳转路径

### FR-位置系统
- FR-11: 新增 Always 授权申请流程（用户主动开启）
- FR-12: `PassiveLocationService` 基于 CLVisitor 被动记录
- FR-13: `VisitDraftStore` 持久化草稿到 `vault/drafts/visits.json`
- FR-14: Today View 显示 `LocationDraftCard`，支持单条 / 批量确认 / 忽略
- FR-15: 位置 Chip 点击显示地图预览（MapKit Sheet）

### FR-内容管理
- FR-16: Daily Page 支持重新编译 + 元数据编辑
- FR-17: 搜索支持日期范围 / 类型 / 地点筛选
- FR-18: Archive 月度统计支持筛选 + 导出 Markdown + 分享截图
- FR-19: 语音录音支持实时转写显示
- FR-20: 语音转写结果只写入一次（修复重复 bug）

### FR-输入扩展
- FR-21: 输入栏支持拍照（区分于相册选取）
- FR-22: 输入栏支持任意文件附件（PDF / 文本 / 其他）

### FR-Graph
- FR-23: Graph Tab 解锁，节点 + 边可视化（力导向布局）
- FR-24: 节点分类着色（人物 / 地点 / 主题）
- FR-25: 节点点击跳转 Entity Page
- FR-26: 时间轴筛选 + 节点搜索

---

## 6. Non-Goals（明确不做）

- ❌ 跨设备同步（iCloud / 自建云）—— 保持纯本地
- ❌ 多用户 / 协作 —— 单用户工具
- ❌ AI 模型本地化 —— 继续用 DashScope 云端
- ❌ Android / Web 版本 —— 专注 iOS
- ❌ Apple Watch / 小组件 —— v2 不做
- ❌ Markdown 富文本编辑器 —— 保持 plain text 输入
- ❌ 实时协同编辑 Daily Page
- ❌ 云端 API Key 托管 —— 用户自带 key
- ❌ 输入栏富文本 / 表情 / @提及自动补全（v2 不做）
- ❌ Graph 3D 视图 / VR —— 仅 2D 力导向

---

## 7. Design Considerations

### 必须同步设计
1. **`LocationDraftCard`**（US-303）—— 需要设计稿，当前 issue #52 只有文字描述
2. **`SettingsView`**（US-109）—— 全新页面，需要与 Today/Archive 保持视觉一致
3. **Graph Tab**（US-503/504）—— 当前无设计，需要 Stitch 补图
4. **位置 Chip 地图预览 Sheet**（US-304）—— 需要设计稿
5. **面包屑组件**（US-105）—— 需要定义视觉

### 可复用现有设计
- Daily Page Timeline Tab（US-106）：直接复用 Today view 组件
- Archive 筛选栏：复用现有 segmented control + picker 样式
- 重编译确认弹窗：用系统 `alert` 即可

### 设计交付流程
参考 `CLAUDE.md` 的 Stitch 同步流程：新页面设计完成后，`mcp__stitch__get_screen` 拉取 → 存入 `design/stitch/` → 实现时读本地文件。

---

## 8. Technical Considerations

### 依赖与风险
- **Always 授权**（W3）：App Store 审核会重点检查隐私声明，需要在 `NSLocationAlwaysAndWhenInUseUsageDescription` 中清楚说明"可选的被动位置记录"
- **后台耗电**（W3）：CLVisitor 官方声明低耗电，但需要真机实测 24h 耗电增量 < 5%
- **Graph 布局算法**（W5）：力导向在 100+ 节点时性能下降，需要实测 + 考虑分页或聚类
- **实时转写**（W4）：`SFSpeechRecognizer` 本地模型对中文支持有限，可能需回退到流式 Whisper（成本更高）

### 技术债务清理
- 补齐 `DayPageTests` target（Swift Testing），覆盖 `VisitDraftStore`、`BackgroundCompilationService` 重试逻辑、`Memo` YAML 解析
- `CompilationService` JSON 解析加 schema 验证（参考已修复的 #54）

### 数据迁移
- W3 新增 `vault/drafts/visits.json`，首次启动创建空文件
- 老版本 Daily Page 的 YAML 元数据缺字段时，US-401 编辑表单要 graceful fallback

### 性能目标
- Today View 首屏加载 < 300ms（20 条 memo）
- Graph Tab 100 节点渲染 60fps
- 后台编译任务耗时 P95 < 30s

---

## 9. Success Metrics

| 指标 | 基线 | 目标 |
|---|---|---|
| 所有导航死链 | 5 处 | 0 |
| 后台编译成功率 | 未测量 | ≥ 95% |
| 用户日均位置草稿确认率 | N/A | ≥ 60% |
| Graph Tab 日均打开次数 | 0（禁用） | ≥ 1 |
| API Key 缺失导致的静默失败 | 100%（无提示） | 0 |
| 语音 memo 转写出错率 | 未测量 | < 5% |
| TestFlight crash rate | 未知 | < 0.5% |

---

## 10. Open Questions

1. **Graph 布局引擎**：手写简化版力导向 vs 引入 SPM 依赖（偏好不引入 SPM，与现状一致）—— 确认？
2. **实时转写方案**：`SFSpeechRecognizer` 本地（免费、但中文弱）vs 流式 Whisper（成本高、准确）—— 倾向前者 + 后者回退
3. **汉堡菜单功能**（US-108）：Side Drawer 还是直接移除？需要产品决策
4. **Settings 页入口**：iOS 标准做法通常放 Tab 之外，当前放 Today Header 右上角 OK 吗？
5. **重新编译的版本管理**（US-401）：要不要保留历史 Daily Page 版本支持回滚？（倾向不做，直接覆盖）
6. **Graph Tab 数据范围**：默认最近 30 天还是全量？全量可能影响性能
7. **文件附件大小限制**（US-502）：> 50MB 的文件允许吗？vault 目录会膨胀
8. **月度导出格式**（US-403）：Markdown 之外要不要 PDF？

---

## 附录：Issue ↔ Story 映射

| Wave | Story | Issue |
|---|---|---|
| W1 | US-101 | #32 |
| W1 | US-102 | #33 |
| W1 | US-103 | #48 |
| W1 | US-104 | #39 |
| W1 | US-105 | #49 |
| W1 | US-106 | #31 |
| W1 | US-107 | #47 |
| W1 | US-108 | #34 |
| W1 | US-109 | #35 |
| W2 | US-201 | #40 |
| W2 | US-202 | #38 |
| W2 | US-203 | #41 |
| W3 | US-301 | #51 |
| W3 | US-302 | #50 |
| W3 | US-303 | #52 |
| W3 | US-304 | #46 |
| W4 | US-401 | #43 |
| W4 | US-402 | #45 |
| W4 | US-403 | #44 |
| W4 | US-404 | #53 |
| W4 | US-405 | #42 |
| W5 | US-501 | #36 |
| W5 | US-502 | #37 |
| W5 | US-503 | #30 (part 1) |
| W5 | US-504 | #30 (part 2) |
