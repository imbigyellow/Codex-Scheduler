# Codex Scheduler

一个离线、原生的 macOS 定时发送工具。输入提示词、选择 Codex 或 ChatGPT、指定本地日期时间，系统会在到点时激活目标 App、粘贴原文并按 Return。支持多个独立任务和 10 秒测试。

## 架构

- SwiftUI 主 App 管理任务、权限提示和状态。
- `~/Library/Application Support/CodexScheduler/tasks.json` 保存完整 `Date`、提示词、状态及唯一 UUID；文件权限为当前用户可读写。锁文件保证主 App 与 helper 不会同时覆盖状态。
- 所有任务共用一个固定的 `~/Library/LaunchAgents/com.codexscheduler.scheduler.plist`。由 `launchctl bootstrap gui/<uid> <plist>` 注册一次；添加任务只更新任务数据，不再为每条任务注册后台项目。主 App 退出后调度照常运行。
- `SchedulerHelper` 随 App 打包。固定的后台进程监听任务文件变化，并用一次性计时器等待下一条任务，不做周期轮询。它检查完整目标时间，只在目标时间到来至其后 10 分钟内执行。状态锁阻止重复发送。
- 辅助功能状态由固定的 `com.codexscheduler.permission` LaunchAgent 按需唤醒 helper 检查；正常使用时不会为每次检查创建新后台项目，也不常驻轮询。
- 重启登录后 launchd 会重启固定服务并立即检查待发送任务，包括 10 秒测试。旧版本已创建的逐任务 Agent 会在对应任务结束时清理。

## 构建与运行

要求 macOS 13+，Swift 5.9+。用 Xcode 打开 `Package.swift` 可浏览及构建 Swift targets。可运行的 `.app` 由下面脚本打包：

```sh
swift run SchedulerSelfTest
./scripts/build-app.sh
open ./build/CodexScheduler.app
```

只需 Xcode Command Line Tools 即可运行脚本；无需 Homebrew、Node、Python 或联网。打包脚本使用本机 ad hoc 签名。**安排任务后不要移动或删除 `.app`**，因为 LaunchAgent 保存的是 helper 的绝对路径。重新编译或重新签名可能改变辅助功能权限身份，需要重新授权。

## 首次授权与焦点

主界面显示 **由 launchd 启动的 SchedulerHelper** 的辅助功能授权状态。检测使用固定的权限探针 LaunchAgent，因为从终端或主 App 直接运行 helper 的权限可能与后台运行不同。点击“打开系统设置”，在“系统设置 → 隐私与安全性 → 辅助功能”中允许 `build/CodexScheduler.app/Contents/Helpers/SchedulerHelper.app`。若列表中尚未出现，可用 `+` 手动添加这个内嵌 App；如无法浏览到它，可在 Finder 对主 App 选择“显示包内容”，进入 `Contents/Helpers`。授权后返回 App 点“刷新”。权限授予给真正执行键盘事件的 helper，主 App 的授权不替代它。系统可能要求退出并重新打开 helper/应用后生效。

发送前 helper 会查找运行中的目标 App：先匹配已知 bundle ID，再按应用显示名称匹配；若未运行，则尝试通过系统查找 bundle ID 并启动。激活后最多检查 3 次是否确实成为前台。未找到、未获得权限或未成为前台时，不粘贴也不按键，并标记失败。

**请在离开 Codex/ChatGPT 前，打开目标 conversation，并让其处于正常可输入状态。** 本程序不识别各 App 的内部输入控件，也不会自动选择 conversation。被激活 App 如果没有把焦点放在输入框，可能不会发送，或会触发该 App 自己的快捷键。请先使用“10 秒后测试发送”验证当前版本的目标 App 行为。

## 使用

1. 在顶部编辑器输入提示词，底部选择目标 App。普通 Return 换行，⌘N 聚焦编辑器。
2. 在“发送时间”选择快捷时间，或点时间摘要打开完整日期时间选择器（含年、月、日、小时、分钟）。
3. 点击“安排发送”或按 ⌘Return。新任务会出现在“待发送”，编辑器清空并短暂显示确认提示；10 秒测试是次级操作。
4. 任务右侧菜单可取消或删除；发送结果进入默认折叠的“历史记录”。历史任务的“再次安排”会将原提示词与目标 App 放回编辑器，并预选一小时后的时间；确认后才会创建新任务。历史区的“清空历史”经确认后删除全部已结束任务并清空执行日志，待发送任务不受影响。可关闭窗口或退出 App，LaunchAgent 仍会执行。

电脑重启后，用户重新登录时 LaunchAgent 会被系统加载。若目标时间已过去超过 10 分钟，任务标记为“已错过”，不会发送。目标时间是创建时的绝对时间，更改系统时区不会改变它。睡眠、关机、未登录、锁屏、目标 App 内部 UI 状态与系统 TCC 策略会影响实际执行；锁屏环境请先用测试任务验证。

## 检查与清理

```sh
ls ~/Library/LaunchAgents/com.codexscheduler.scheduler.plist
launchctl print gui/$(id -u)/com.codexscheduler.scheduler
cat ~/Library/Application\ Support/CodexScheduler/tasks.json
tail ~/Library/Application\ Support/CodexScheduler/executions.jsonl
```

`executions.jsonl` 每次记录 `scheduledAt`、`targetDate`、`actualExecutionDate`、`targetApp`、`result`、`error`。另外有 `helper.out.log` 与 `helper.err.log`。任务列表显示最终状态和最近错误。

开发验收可运行 `swift run -c release SchedulerSelfTest`。`swift run -c release SchedulerSelfTest --permission-probe --helper "$PWD/build/CodexScheduler.app/Contents/Helpers/SchedulerHelper.app/Contents/MacOS/SchedulerHelper"` 会按 LaunchAgent 路径检查辅助功能权限。`--agent-registration --helper <同一路径>` 会短暂添加两个未来任务，验证它们只共用一个固定 Agent，不会发送消息。`--agent-integration --helper <同一路径>` 会创建并清理一个真正的临时任务；如果 helper 已授权且 Codex 已打开，可能会向当前对话发送一条无害测试消息。

手动卸载调度 Agent 和旧版本遗留的逐任务 Agent（**不影响** `com.codex.autosend`）：

```sh
launchctl bootout "gui/$(id -u)/com.codexscheduler.scheduler" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.codexscheduler.scheduler.plist"
for file in "$HOME"/Library/LaunchAgents/com.codexscheduler.task.*.plist; do
  [ -e "$file" ] || continue
  label="${file##*/}"
  label="${label%.plist}"
  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm "$file"
done
```

如需彻底卸载 App，再执行 `launchctl bootout "gui/$(id -u)/com.codexscheduler.permission"` 并删除 `~/Library/LaunchAgents/com.codexscheduler.permission.plist`。

## 剪贴板与限制

helper 在发送前逐项读取原剪贴板各类型的二进制数据，写入提示词，按 Cmd+V，等待粘贴，再按 Return，最后恢复原项目。此方式通常能保留文字、图片、文件 URL 与富文本；由其他应用延迟提供的剪贴板数据、极大内容、特殊私有类型或发送期间用户同时修改剪贴板的情形不能保证完全恢复。恢复失败不会让已发送任务重新发送。发送以目标 App 前台检查为前提，不保证目标 App 接受粘贴后的最终服务器响应。

程序没有网络请求、遥测或第三方运行时。提示词以本机 JSON 明文存放，适合个人机器使用；不要在不受信任的共享账户安排敏感提示词。

本机发现过显示名称为 ChatGPT、bundle ID 却为 `com.openai.codex`、界面实际处于 Codex 模式的安装版本。选 Codex 时会优先匹配这个 bundle ID；选 ChatGPT 时优先匹配显示名称。若两种模式共用同一个 App，程序无法切换其内部模式，请事先打开正确的对话界面。
