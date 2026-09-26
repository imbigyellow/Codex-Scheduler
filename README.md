# Codex Scheduler

**Hit the Codex or ChatGPT usage limit before your work is done?** Write a continuation prompt now and schedule it for a time after your limit is expected to reset. Codex Scheduler can send it to your open conversation while you're away, so the unfinished work can continue. It's a lightweight, native, offline macOS app with no extra account, cloud service, browser extension, or runtime.

**Codex 或 ChatGPT 额度用完了，工作还没做完？** 先写好续接提示词，安排在预计额度重置后发送。即使人暂时不在电脑前，也能让已打开的对话继续处理未完成的工作。Codex Scheduler 是轻量、原生、离线的 macOS 应用，无需额外账号、云服务、浏览器扩展或运行环境。

[Download / 下载最新版](https://github.com/imbigyellow/Codex-Scheduler/releases/latest) · [中文说明](#中文) · [English](#english) · [Development notes / 开发说明](docs/DEVELOPMENT.zh-CN.md)

## 中文

### 适合什么场景？

例如你正在让 Codex 修改项目，额度突然用尽，但任务还没完成。把接下来要做的事写成提示词，选择**预计额度重置之后**的时间；到点后，Codex Scheduler 会尝试向目标 App 中已打开的对话粘贴并发送。你可以离开电脑，不必守着重置时间。它也适合定时启动其他一次性任务。

你可以这样写续接提示词：**“继续刚才未完成的工作。先检查当前对话和项目状态，再完成剩余修改、运行测试并总结结果。”** 请预先打开正确的对话，并保持 Mac 处于可用的登录会话中。**本工具不会读取额度或检测实际重置时间；它只在你设定的时间尝试发送。**

### 优点

- **轻量省资源**：SwiftUI 原生界面，单个固定的后台调度服务；监听任务变化并等待下一个时间点，没有周期轮询，也不会每添加一条任务就注册新的后台项目。
- **额度重置后续接工作**：提前安排提示词，让未完成的任务在你不守着电脑时继续。
- **本机运行**：提示词和任务保存在你的 Mac，程序不发送网络请求、不做遥测。
- **关掉窗口仍可执行**：主 App 退出后，macOS LaunchAgent 继续负责调度；重新登录后会检查未完成任务。
- **安全地避免重复发送**：每条任务只认领一次；超过预定时间 10 分钟仍未执行的任务会标记为“已错过”。
- **实用操作**：Codex / ChatGPT 目标切换、10 秒测试、任务状态与历史、取消、删除、清空历史、复用历史提示词。

### 下载安装

1. 在 [Releases](https://github.com/imbigyellow/Codex-Scheduler/releases/latest) 下载 `CodexScheduler-…-macOS-universal.zip`，解压后将 **CodexScheduler.app 移到“应用程序”文件夹**，然后再打开。安装包同时支持 Apple Silicon 和 Intel Mac，要求 macOS 13 或更新版本。
2. 此版本采用临时（ad hoc）签名，没有 Apple Developer ID 公证。若 macOS 提示无法验证开发者，先尝试打开一次，再进入 **系统设置 → 隐私与安全性 → 仍要打开（Open Anyway）**。请只从本仓库的 Release 下载，并核对发布页提供的 SHA-256。
3. 按界面提示为内嵌的 **SchedulerHelper** 开启 **辅助功能** 权限，返回 App 点击“刷新”。该权限让 helper 能激活目标应用、粘贴文字并按 Return；仅给主 App 授权是不够的。
4. 在目标 App 中打开想接收提示词的对话，让输入框可用。先用“10 秒后测试发送”验证当前界面，然后安排正式任务。**安排任务后不要移动或删除 CodexScheduler.app**，后台服务使用安装位置的路径。

### Codex 锁屏续聊

需要发到**同一个 Codex 对话**时，在目标选 Codex，开启“后台续聊现有 Codex 对话”，填写该任务的会话 UUID（也可粘贴 `codex://threads/<UUID>` 链接）和项目目录的绝对路径。先在终端执行 `codex login status` 确认 CLI 已登录，再安排 10 秒测试。此模式调用官方 `codex exec resume <会话 ID>`，不使用键盘事件，也不需要辅助功能权限。会话 ID 必须是 Codex 任务的 ID，不能填分享快照链接；目录应与原任务工作目录一致。后台运行期间不要同时在该会话发起另一个任务。

锁屏后，只要 Mac 仍处于运行状态且网络可用，调度服务可以继续该会话。macOS 的锁屏快捷键是 **Control + Command + Q（⌃⌘Q）**；Shift + Command + Q（⇧⌘Q）是退出登录。锁屏本身不等于睡眠。默认勾选“等待期间防止自动睡眠”，它会在存在待执行的后台续聊任务时阻止闲置睡眠；屏幕仍可关闭或锁定，但可能增加耗电。**真正睡眠期间 Mac 无法运行本机任务**：如果睡眠跨过预定时间，任务在唤醒后标记为“已错过”，不会补发。关机、断网或未登录时，同样不能保证准点执行。

> Mac 需要处于已登录的用户会话中。传统的界面发送模式会受睡眠、锁屏、目标 App 界面变化或未打开正确对话影响；Codex 后台续聊模式的行为见上文。程序会记录本地结果，但不能保证目标服务已经收到或处理消息。提示词以本机 JSON 明文保存；共用 Mac 时请避免写入敏感信息。

### 自行构建

安装 Xcode Command Line Tools 后运行：

```sh
swift run -c release SchedulerSelfTest
zsh scripts/build-app.sh
open ./build/CodexScheduler.app
```

构建双架构发布包：`zsh scripts/build-release.sh`。详细架构、权限、日志与卸载说明见[开发说明](docs/DEVELOPMENT.zh-CN.md)。

## English

### What is it for?

Suppose Codex reaches its usage limit while it is working on your project. Write down what it should do next, choose a time **after the limit is expected to reset**, and leave the conversation open. Codex Scheduler will try to paste and send that prompt in the target app at the scheduled time. Your work can continue even if you're away from the keyboard. You can also schedule other one-off prompts.

For example: **“Continue the unfinished work in this conversation. Check the current project state, finish the remaining changes, run the tests, and summarize the result.”** Keep the intended conversation open and your Mac in a usable logged-in session. **The app does not read your quota or detect when it actually resets; it sends at the time you choose.**

### Why use it?

- **Lightweight native app:** SwiftUI, one persistent LaunchAgent, event-driven scheduling, and no periodic polling or per-task background registrations.
- **Continue after a usage-limit reset:** prepare the next prompt before stepping away instead of waiting at your Mac.
- **Local and offline:** prompts and task history stay on your Mac; no network calls, telemetry, account, or third-party runtime.
- **Works after closing the main app:** the background helper remains scheduled and checks pending tasks when you log in again.
- **One-shot delivery:** a task is claimed once. If it becomes more than 10 minutes late, it is marked missed rather than sent unexpectedly.
- **Useful controls:** 10-second test, Codex/ChatGPT selection, status and history, cancel/delete, clear history, and reuse a past prompt.

### Install and use

1. Download `CodexScheduler-…-macOS-universal.zip` from [Releases](https://github.com/imbigyellow/Codex-Scheduler/releases/latest). Unzip and move **CodexScheduler.app to Applications before opening it**. Supports Apple Silicon and Intel Macs with macOS 13 or later.
2. This release is ad hoc signed and **not Apple notarized**. If macOS cannot verify the developer, try opening the app once, then use **System Settings → Privacy & Security → Open Anyway**. Download only from this repository's Release and compare its SHA-256 checksum.
3. Grant **Accessibility** permission to the bundled **SchedulerHelper** when prompted, then return to the app and click Refresh. The helper needs this permission to activate the target app, paste the prompt, and press Return.
4. Open the intended conversation in Codex or ChatGPT and make sure its input box is ready. Try the **10-second test** before scheduling a real prompt. **Do not move or delete the app after creating tasks**; the LaunchAgent stores its installed path.

> Your Mac needs a logged-in user session. The original UI delivery mode can be affected by sleep, a locked screen, changes to the target app's UI, or the wrong conversation. See the background Codex mode below for locked-screen behavior. The app records its local result but cannot confirm that the remote service processed your message. Prompts are stored locally as plain-text JSON.

### Continue an existing Codex conversation while locked

Select Codex and enable **Continue an existing Codex conversation in the background**. Enter the task UUID (or a `codex://threads/<UUID>` link) and its working directory. Sign in to the Codex CLI first, then try a 10-second test. This mode uses `codex exec resume` and does not need Accessibility permission. It can run while the screen is locked with **Control-Command-Q**; **Shift-Command-Q** logs out. By default, it prevents idle system sleep while such tasks are pending, which may increase battery use. If the Mac sleeps across the scheduled time, the task is marked missed after wake and is never sent late.

### Build from source

With Xcode Command Line Tools installed:

```sh
swift run -c release SchedulerSelfTest
zsh scripts/build-app.sh
open ./build/CodexScheduler.app
```

Run `zsh scripts/build-release.sh` to make the universal ZIP. See the [development notes (Chinese)](docs/DEVELOPMENT.zh-CN.md) for architecture, permissions, logs, and uninstall steps.

## License

MIT. This is an independent project and is not affiliated with OpenAI.
