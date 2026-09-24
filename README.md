# Codex Scheduler

**Schedule a prompt for Codex or ChatGPT on your Mac.** A small, native, offline macOS app that sends your text at the time you choose. No account, cloud service, browser extension, or extra runtime is required.

**在 Mac 上定时发送提示词到 Codex 或 ChatGPT。** 这是一款轻量、原生、离线的 macOS 应用：写好内容、选好时间，到点自动发送。无需注册账号、云服务、浏览器扩展或额外运行环境。

[Download / 下载最新版](https://github.com/imbigyellow/Codex-Scheduler/releases/latest) · [中文说明](#中文) · [English](#english) · [Development notes / 开发说明](docs/DEVELOPMENT.zh-CN.md)

## 中文

### 适合什么场景？

想让 Codex 或 ChatGPT **稍后自动收到一段提示词**，例如下班前提醒自己检查进度、明早启动一项工作，或在指定时间发送已经写好的任务。Codex Scheduler 管理一次性任务；它不是聊天机器人、云端定时服务，也不会替你选择目标 App 里的具体对话。

### 优点

- **轻量省资源**：SwiftUI 原生界面，单个固定的后台调度服务；监听任务变化并等待下一个时间点，没有周期轮询，也不会每添加一条任务就注册新的后台项目。
- **本机运行**：提示词和任务保存在你的 Mac，程序不发送网络请求、不做遥测。
- **关掉窗口仍可执行**：主 App 退出后，macOS LaunchAgent 继续负责调度；重新登录后会检查未完成任务。
- **安全地避免重复发送**：每条任务只认领一次；超过预定时间 10 分钟仍未执行的任务会标记为“已错过”。
- **实用操作**：Codex / ChatGPT 目标切换、10 秒测试、任务状态与历史、取消、删除、清空历史、复用历史提示词。

### 下载安装

1. 在 [Releases](https://github.com/imbigyellow/Codex-Scheduler/releases/latest) 下载 `CodexScheduler-…-macOS-universal.zip`，解压后将 **CodexScheduler.app 移到“应用程序”文件夹**，然后再打开。安装包同时支持 Apple Silicon 和 Intel Mac，要求 macOS 13 或更新版本。
2. 此版本采用临时（ad hoc）签名，没有 Apple Developer ID 公证。若 macOS 提示无法验证开发者，先尝试打开一次，再进入 **系统设置 → 隐私与安全性 → 仍要打开（Open Anyway）**。请只从本仓库的 Release 下载，并核对发布页提供的 SHA-256。
3. 按界面提示为内嵌的 **SchedulerHelper** 开启 **辅助功能** 权限，返回 App 点击“刷新”。该权限让 helper 能激活目标应用、粘贴文字并按 Return；仅给主 App 授权是不够的。
4. 在目标 App 中打开想接收提示词的对话，让输入框可用。先用“10 秒后测试发送”验证当前界面，然后安排正式任务。**安排任务后不要移动或删除 CodexScheduler.app**，后台服务使用安装位置的路径。

> Mac 需要处于可登录的用户会话中。睡眠、锁屏、目标 App 的界面变化或未打开正确对话，都可能影响实际发送。程序会记录本地结果，但不能保证目标服务已经收到或处理消息。提示词以本机 JSON 明文保存；共用 Mac 时请避免写入敏感信息。

### 自行构建

安装 Xcode Command Line Tools 后运行：

```sh
swift run -c release SchedulerSelfTest
./scripts/build-app.sh
open ./build/CodexScheduler.app
```

构建双架构发布包：`./scripts/build-release.sh`。详细架构、权限、日志与卸载说明见[开发说明](docs/DEVELOPMENT.zh-CN.md)。

## English

### What is it for?

Codex Scheduler sends a prepared prompt to the **Codex or ChatGPT macOS app at a chosen time**. Use it to start a task tomorrow morning, send a reminder to your open conversation, or queue one-off prompts for later. It does not choose a conversation or inspect the target app's chat UI.

### Why use it?

- **Lightweight native app:** SwiftUI, one persistent LaunchAgent, event-driven scheduling, and no periodic polling or per-task background registrations.
- **Local and offline:** prompts and task history stay on your Mac; no network calls, telemetry, account, or third-party runtime.
- **Works after closing the main app:** the background helper remains scheduled and checks pending tasks when you log in again.
- **One-shot delivery:** a task is claimed once. If it becomes more than 10 minutes late, it is marked missed rather than sent unexpectedly.
- **Useful controls:** 10-second test, Codex/ChatGPT selection, status and history, cancel/delete, clear history, and reuse a past prompt.

### Install and use

1. Download `CodexScheduler-…-macOS-universal.zip` from [Releases](https://github.com/imbigyellow/Codex-Scheduler/releases/latest). Unzip and move **CodexScheduler.app to Applications before opening it**. Supports Apple Silicon and Intel Macs with macOS 13 or later.
2. This release is ad hoc signed and **not Apple notarized**. If macOS cannot verify the developer, try opening the app once, then use **System Settings → Privacy & Security → Open Anyway**. Download only from this repository's Release and compare its SHA-256 checksum.
3. Grant **Accessibility** permission to the bundled **SchedulerHelper** when prompted, then return to the app and click Refresh. The helper needs this permission to activate the target app, paste the prompt, and press Return.
4. Open the intended conversation in Codex or ChatGPT and make sure its input box is ready. Try the **10-second test** before scheduling a real prompt. **Do not move or delete the app after creating tasks**; the LaunchAgent stores its installed path.

> Your Mac needs an active logged-in user session. Sleep, a locked screen, changes to the target app's UI, or the wrong conversation can prevent delivery. The app records its local result but cannot confirm that the remote service processed your message. Prompts are stored locally as plain-text JSON.

### Build from source

With Xcode Command Line Tools installed:

```sh
swift run -c release SchedulerSelfTest
./scripts/build-app.sh
open ./build/CodexScheduler.app
```

Run `./scripts/build-release.sh` to make the universal ZIP. See the [development notes (Chinese)](docs/DEVELOPMENT.zh-CN.md) for architecture, permissions, logs, and uninstall steps.

## License

MIT. This is an independent project and is not affiliated with OpenAI.
