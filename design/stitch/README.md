# Stitch 设计资产

来源：Stitch 项目 `DayPage Today Flow`
Project ID：`6404909232718143042`

## 目录结构

- `screenshots/` — PNG 截图，看布局和视觉
- `html/` — HTML 源码，看精确样式值

## Screen ID 清单

| 本地文件（不含扩展名） | Screen ID |
|---|---|
| `design-system`（未下载） | `asset-stub-assets-a6a977c636d44f3e9a27fdef4c20a8d3-1776239737435` |
| `today-flow` | `d04c6aacebe545ddadbb62a9dec096dc` |
| `voice-recording` | `b775e7c144484f669d2f537e403a0f5b` |
| `daily-page` | `9d2ae4b86b5f4dc199b57e6dd0692dc0` |
| `archive-calendar` | `d5c62950056d49fbae3e0da2052f3b6d` |
| `archive-list` | `541c1afa6c144a8db0874790b5f79397` |
| `daily-page-updated-nav`（未下载） | `e29e4b887b654061ae2257f570ad1480` |
| `today-flow-refined` | `11aa047194684caea6c36c45526f2484` |
| `daily-page-fixed-nav`（未下载） | `856607e7ff80401c939e05a30ee4d6c0` |
| `voice-recording-v2`（未下载） | `761eec6a9f9e4e00bb3bb1ee89c8ff73` |

## 重新同步流程

1. 用 `mcp__stitch__get_screen` 按 screen ID 取最新 HTML 和图片 URL
2. `curl -L <url> -o html/<name>.html`（或对应的 png 路径）覆盖
3. 同一屏幕存在多个迭代版本时，最新的那个覆盖基础文件名，旧版本归档到 `archive/` 子目录

## 约定

- Claude Code 实现 UI 时**不要**调用 `mcp__stitch__*` 工具，直接读本地文件
- 仅当用户明确说"设计稿更新了"或者本地资产明显过期时才重新同步
