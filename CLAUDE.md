# DayPage — Claude Code 项目规范

## 项目简介

DayPage：以"每日原始数据采集"为核心的个人记录工具。用户倾倒，AI 每日编译成结构化日记和知识网络。目标用户：旅居者/数字游民。

## 技术栈

### 客户端

| 层 | 选型 | 理由 |
|---|---|---|
| 框架 | **Expo SDK 55** (React Native 0.83) | 官方推荐框架，New Architecture 默认启用，file-based routing，原生模块生态最完善 |
| 包管理 | **Bun** | Expo 官方支持，安装速度 4x+，`bunx expo` 直接可用 |
| 语言 | **TypeScript** (strict mode) | 类型安全，元数据结构需要强类型保障 |
| 样式 | **NativeWind v4** (Tailwind CSS) | 与设计系统的 utility-first 思路一致，零圆角等约束通过 tailwind.config 全局控制 |
| 导航 | **Expo Router v4** (file-based) | 三个 Tab (Today / Archive / Graph) + 模态浮层，文件即路由 |
| 状态管理 | **Zustand** | 轻量，memo 列表和 UI 状态足够用，不需要 Redux |
| 本地存储 | **expo-file-system** + 纯 Markdown 文件 | Raw 层写 `.md` 文件，不用数据库。附件存 `assets/` 目录 |
| 语音录制 | **expo-av** (录音) + **expo-audio** (播放) | Expo 原生模块，稳定 |
| 语音转文字 | **Whisper.cpp** via `react-native-whisper` | 本地转录，隐私优先。备选：Anthropic/OpenAI STT API |
| 相机/相册 | **expo-image-picker** + **expo-media-library** | EXIF 自动提取 |
| 位置 | **expo-location** | 前台 GPS + 反向地理编码 |
| 天气 | **OpenWeather API** (free tier) | 基于 GPS 坐标获取当前天气 |
| Markdown渲染 | **react-native-markdown-display** | 在 Daily Page 和 Archive 中渲染编译后的 wiki 内容 |

### AI 编译引擎

| 功能 | 选型 | 说明 |
|---|---|---|
| 每日编译 | **Claude API** (claude-sonnet-4-20250514) | 读当天 raw + hot.md，产出 Daily Page + Entity Page 更新 |
| 编译调度 | **expo-background-fetch** + **expo-task-manager** | 每日凌晨 2:00 本地时间触发 |
| Token 优化 | 仅传文本，不传音频/图片原文件 | 每日 20 条 memo 约 2k-5k input tokens |


## 编码规范

- 组件用函数式 + hooks，不用 class
- 文件命名：PascalCase 组件，camelCase 工具函数
- 每个文件 < 200 行，超过就拆分
- 不用 `any`，不用 `@ts-ignore`


## UI 设计

设计稿（Stitch 项目 `DayPage Today Flow` / ID `6404909232718143042`）已快照到仓库，实现时**优先读本地文件**，不要调用 `mcp__stitch__*`：

- `design/stitch/screenshots/*.png` — 布局、配色、视觉层级
- `design/stitch/html/*.html` — 精确间距、字号、颜色值（读 class 和内联样式）

屏幕映射：

| 资产文件名 | 对应屏幕 |
|---|---|
| `today-flow` | Today Tab 主流程 |
| `voice-recording` | 语音录制浮层 |
| `daily-page` | 每日编译后的日记页 |
| `archive-calendar` | Archive 日历视图 |
| `archive-list` | Archive 列表视图 |

**重新同步**：设计改动后运行 `mcp__stitch__get_screen`（screen ID 清单见 `design/stitch/README.md`），覆盖 `design/stitch/` 下对应文件。


# 测试

一些明确的任务可以 TDD 驱动，确保每一次任务完成之前使用 SKILLS 检查 UI 或者程序是否有问题
