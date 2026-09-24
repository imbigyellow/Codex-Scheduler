import SwiftUI
import SchedulerCore
import Darwin

private extension Notification.Name {
    static let focusSchedulerPrompt = Notification.Name("focusSchedulerPrompt")
}

@MainActor final class SchedulerModel: ObservableObject {
    @Published var prompt = ""
    @Published var target: TargetApp = .codex
    @Published var date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var helperTrusted = false
    @Published private(set) var permissionChecked = false
    @Published private(set) var isScheduling = false
    @Published var errorMessage: String?

    private let store = TaskStore()
    private let agents = LaunchAgentService()
    private var storeObserver: DispatchSourceFileSystemObject?

    private var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/SchedulerHelper.app/Contents/MacOS/SchedulerHelper").path
    }

    var scheduledTasks: [ScheduledTask] {
        tasks.filter { $0.status == .waiting || $0.status == .running }
            .sorted { $0.scheduledAt > $1.scheduledAt }
    }

    var historyTasks: [ScheduledTask] {
        tasks.filter { $0.status != .waiting && $0.status != .running }
            .sorted { ($0.actualExecutionDate ?? $0.scheduledAt) > ($1.actualExecutionDate ?? $1.scheduledAt) }
    }

    var hasPrompt: Bool { !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var selectedDate: Date {
        Calendar.current.date(from: Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)) ?? date
    }
    var hasValidDate: Bool { selectedDate > Date() }
    var canSchedule: Bool { hasPrompt && hasValidDate && helperTrusted && !isScheduling }
    var canTest: Bool { hasPrompt && helperTrusted && !isScheduling }

    init() {
        reloadTasks()
        observeStore()
        let path = helperPath
        Task.detached(priority: .utility) {
            try? LaunchAgentService().ensureInstalled(helperPath: path)
        }
        Task { await refreshPermission() }
    }

    func reloadTasks() {
        do {
            let loaded = try store.all()
            withAnimation(.easeInOut(duration: 0.2)) { tasks = loaded }
            for task in loaded where task.status != .waiting && task.status != .running {
                if FileManager.default.fileExists(atPath: agents.plistURL(for: task).path) {
                    agents.remove(task)
                }
            }
        } catch { errorMessage = "读取任务失败：\(error.localizedDescription)" }
    }

    private func observeStore() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let fd = open(store.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in self?.reloadTasks() }
        source.setCancelHandler { close(fd) }
        storeObserver = source
        source.resume()
    }

    func refreshPermission() async {
        let path = helperPath
        let trusted = await Task.detached(priority: .utility) {
            PermissionProbeService().isLaunchAgentHelperTrusted(helperPath: path)
        }.value
        helperTrusted = trusted
        permissionChecked = true
    }

    func schedule(test: Bool = false) async -> ScheduledTask? {
        guard hasPrompt else { errorMessage = "请输入提示词"; return nil }
        guard helperTrusted else { errorMessage = "请先开启自动化权限"; return nil }
        let when = test ? Date().addingTimeInterval(10) : selectedDate
        guard when > Date() else { errorMessage = "请选择未来的发送时间"; return nil }
        guard !isScheduling else { return nil }

        let text = prompt
        let app = target
        let path = helperPath
        isScheduling = true
        errorMessage = nil
        defer { isScheduling = false }

        do {
            let created = try await Task.detached(priority: .userInitiated) { () throws -> ScheduledTask in
                let task = ScheduledTask(prompt: text, target: app, targetDate: when, isTest: test)
                let store = TaskStore()
                try store.add(task)
                do { try LaunchAgentService().ensureInstalled(helperPath: path) }
                catch {
                    _ = try? store.update(id: task.id) {
                        $0.status = .failed
                        $0.error = "LaunchAgent 注册失败：\(error.localizedDescription)"
                    }
                    throw error
                }
                return task
            }.value
            prompt = ""
            reloadTasks()
            return created
        } catch {
            errorMessage = "安排失败：\(error.localizedDescription)"
            reloadTasks()
            return nil
        }
    }

    func cancel(_ task: ScheduledTask) {
        do {
            let updated = try store.update(id: task.id) {
                if $0.status == .waiting { $0.status = .cancelled }
            }
            if updated.status == .cancelled { agents.remove(task) }
            else { errorMessage = "任务已开始发送，无法取消" }
        } catch { errorMessage = "取消失败：\(error.localizedDescription)" }
        reloadTasks()
    }

    func delete(_ task: ScheduledTask) {
        do { try store.delete(id: task.id); agents.remove(task) }
        catch { errorMessage = "删除失败：\(error.localizedDescription)" }
        reloadTasks()
    }

    func clearHistory() -> Bool {
        do {
            for task in try store.clearHistory() { agents.remove(task) }
            errorMessage = nil
            reloadTasks()
            return true
        } catch {
            errorMessage = "清空历史失败：\(error.localizedDescription)"
            reloadTasks()
            return false
        }
    }

    func reuse(_ task: ScheduledTask) {
        prompt = task.prompt
        target = task.target
        date = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
        errorMessage = nil
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func showHelper() {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/SchedulerHelper.app")
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private func shortTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

private func dayLabel(_ date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "今天" }
    if calendar.isDateInTomorrow(date) { return "明天" }
    return date.formatted(.dateTime.year().month(.abbreviated).day())
}

private func statusPresentation(_ status: TaskStatus) -> (String, String, Color) {
    switch status {
    case .waiting: return ("clock", "待发送", .secondary)
    case .running: return ("arrow.up.circle", "发送中", .accentColor)
    case .sent: return ("checkmark", "已发送", .green)
    case .cancelled: return ("minus.circle", "已取消", .secondary)
    case .failed: return ("exclamationmark.circle", "发送失败", .orange)
    case .missed: return ("clock.badge.exclamationmark", "已错过", .orange)
    }
}

private struct PromptComposer: View {
    @Binding var prompt: String
    @Binding var target: TargetApp
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("输入稍后要发送的提示词…")
                        .foregroundStyle(.tertiary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .focused(focused)
                    .frame(height: 112)
                    .accessibilityLabel("提示词")
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 7)

            Rectangle().fill(Color(nsColor: .separatorColor).opacity(0.55)).frame(height: 1)
            HStack(spacing: 6) {
                Text("发送至").foregroundStyle(.secondary)
                Picker("目标应用", selection: $target) {
                    ForEach(TargetApp.allCases) { app in Text(app.rawValue).tag(app) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 105)
                .accessibilityLabel("目标应用")
                Spacer()
                Text("⌘ ↵ 安排").foregroundStyle(.tertiary)
            }
            .font(.caption)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(focused.wrappedValue ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 1)
        }
        .animation(.easeInOut(duration: 0.16), value: focused.wrappedValue)
    }
}

private struct TaskRow: View {
    let task: ScheduledTask
    let highlighted: Bool
    let onReuse: (() -> Void)?
    let onCancel: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        let status = statusPresentation(task.status)
        HStack(alignment: .center, spacing: 15) {
            VStack(alignment: .leading, spacing: 2) {
                Text(shortTime(task.targetDate))
                    .font(.system(size: 17, weight: .medium))
                    .monospacedDigit()
                Text(dayLabel(task.targetDate))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 74, alignment: .leading)

            VStack(alignment: .leading, spacing: 5) {
                Text(task.prompt.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(task.target.rawValue).foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Label(status.1, systemImage: status.0).foregroundStyle(status.2)
                }
                .font(.caption2)
                if task.status == .failed, let error = task.error {
                    Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }

            Menu {
                if let onReuse { Button("再次安排", action: onReuse) }
                if task.status == .waiting { Button("取消发送", action: onCancel) }
                Button("删除任务", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("\(dayLabel(task.targetDate)) \(shortTime(task.targetDate)) 的任务操作")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 12)
        .background(highlighted ? Color.accentColor.opacity(0.1) : (hovered ? Color.primary.opacity(0.035) : .clear),
                    in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }
}

struct ContentView: View {
    @StateObject private var model = SchedulerModel()
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var promptFocused: Bool
    @State private var showTimePicker = false
    @State private var showPermissionHelp = false
    @State private var showHistory = false
    @State private var highlightedTask: UUID?
    @State private var toast: String?
    @State private var hoveredQuickTime: String?
    @State private var confirmClearHistory = false
    @State private var pendingReuse: ScheduledTask?
    @State private var scrollToComposer = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        composerSection.id("composer")
                        timeSection
                        actionSection(scroll: scroll)
                        Divider().padding(.top, 24).padding(.bottom, 19)
                        tasksSection
                    }
                    .frame(maxWidth: 660)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: scrollToComposer) { _ in
                    withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("composer", anchor: .top) }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 540, minHeight: 485)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast, systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 20)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                model.reloadTasks()
                if !model.helperTrusted { Task { await model.refreshPermission() } }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSchedulerPrompt)) { _ in
            promptFocused = true
        }
        .confirmationDialog("清空历史记录？", isPresented: $confirmClearHistory) {
            Button("清空历史", role: .destructive) {
                if model.clearHistory() { showHistory = false; showToast("历史已清空") }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会删除所有已结束任务及其执行日志。待发送任务不受影响。")
        }
        .confirmationDialog("替换当前草稿？", isPresented: Binding(
            get: { pendingReuse != nil },
            set: { if !$0 { pendingReuse = nil } }
        )) {
            Button("使用历史提示词") {
                if let task = pendingReuse { applyReuse(task) }
                pendingReuse = nil
            }
            Button("取消", role: .cancel) { pendingReuse = nil }
        } message: {
            Text("当前编辑器已有内容。再次安排会用历史提示词替换它。")
        }
    }

    private var header: some View {
        HStack {
            Text("Codex Scheduler")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            if !model.permissionChecked {
                Text("正在检查…").font(.caption).foregroundStyle(.tertiary)
            } else if model.helperTrusted {
                HStack(spacing: 6) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Ready")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("自动化已就绪")
            } else {
                Button {
                    showPermissionHelp.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                        Text("需要权限")
                        Image(systemName: "chevron.down").font(.system(size: 9))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showPermissionHelp, arrowEdge: .bottom) { permissionHelp }
                .accessibilityLabel("需要自动化权限，点击查看说明")
            }
        }
        .frame(maxWidth: 660)
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
    }

    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("允许自动发送").font(.headline)
            Text("定时任务由 SchedulerHelper 在后台执行。请在系统设置的“辅助功能”中添加并允许它。")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack {
                Button("显示 Helper") { model.showHelper() }
                Button("打开系统设置") { model.openAccessibilitySettings() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(17)
        .frame(width: 290)
    }

    private var composerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("提示词")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            PromptComposer(prompt: $model.prompt, target: $model.target, focused: $promptFocused)
        }
    }

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发送时间")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Button {
                showTimePicker.toggle()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar").font(.system(size: 15)).foregroundStyle(.secondary)
                    Text("\(dayLabel(model.date))  ·  \(shortTime(model.date))")
                        .font(.system(size: 17, weight: .medium))
                        .monospacedDigit()
                    Spacer()
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .medium)).foregroundStyle(.tertiary)
                }
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showTimePicker, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("选择完整日期和时间").font(.subheadline.weight(.medium))
                    DatePicker("日期和时间", selection: $model.date,
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.field)
                        .accessibilityLabel("发送日期和时间")
                }
                .padding(16)
                .frame(width: 310)
            }
            HStack(spacing: 16) {
                quickTime("10 分钟后") { model.date = Date().addingTimeInterval(10 * 60) }
                quickTime("1 小时后") { model.date = Date().addingTimeInterval(60 * 60) }
                quickTime("明天 09:00") {
                    let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                                                         to: Calendar.current.startOfDay(for: Date())) ?? Date().addingTimeInterval(86400)
                    var parts = Calendar.current.dateComponents([.year, .month, .day], from: tomorrow)
                    parts.hour = 9
                    parts.minute = 0
                    model.date = Calendar.current.date(from: parts) ?? tomorrow
                }
            }
            .font(.caption)
            if !model.hasValidDate {
                Text("请选择未来的日期和时间").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.top, 25)
    }

    private func quickTime(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .foregroundStyle(hoveredQuickTime == title ? Color.primary : Color.secondary)
            .onHover { hoveredQuickTime = $0 ? title : nil }
            .accessibilityLabel("设置发送时间为\(title)")
    }

    private func actionSection(scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("10 秒后测试") {
                    createTask(test: true, scroll: scroll)
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.canTest ? Color.secondary : Color.secondary.opacity(0.55))
                .disabled(!model.canTest)
                .accessibilityLabel("10 秒后测试发送")
                Spacer()
                Button {
                    createTask(test: false, scroll: scroll)
                } label: {
                    if model.isScheduling {
                        ProgressView().controlSize(.small).frame(width: 78)
                    } else {
                        Text("安排发送")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!model.canSchedule)
                .accessibilityHint("Command 加 Return 安排发送；普通 Return 在提示词中换行")
            }
            .font(.subheadline)
            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }
        .padding(.top, 21)
    }

    private func createTask(test: Bool, scroll: ScrollViewProxy) {
        Task {
            guard let created = await model.schedule(test: test) else { return }
            highlightedTask = created.id
            withAnimation(.easeInOut(duration: 0.2)) {
                toast = test ? "测试已安排 · 约 10 秒后" : "已安排 · \(dayLabel(created.targetDate)) \(shortTime(created.targetDate))"
            }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.22)) { scroll.scrollTo(created.id, anchor: .center) }
            }
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil; highlightedTask = nil }
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toast = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_300_000_000)
            withAnimation(.easeInOut(duration: 0.2)) { toast = nil }
        }
    }

    private func applyReuse(_ task: ScheduledTask) {
        model.reuse(task)
        showHistory = false
        promptFocused = true
        DispatchQueue.main.async { scrollToComposer += 1 }
        showToast("提示词已填入，请确认发送时间")
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text("待发送").font(.system(size: 15, weight: .medium))
                Text("\(model.scheduledTasks.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 9)

            if model.scheduledTasks.isEmpty {
                if model.historyTasks.isEmpty {
                    VStack(spacing: 7) {
                        Image(systemName: "clock").font(.system(size: 23, weight: .ultraLight)).foregroundStyle(.tertiary)
                        Text("暂无待发送任务").font(.subheadline)
                        Text("写下提示词，选好时间，它会在稍后自动发送。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 31)
                } else {
                    Text("暂无待发送任务")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 15)
                }
            } else {
                ForEach(model.scheduledTasks) { task in
                    TaskRow(task: task, highlighted: highlightedTask == task.id,
                            onReuse: nil,
                            onCancel: { model.cancel(task) }, onDelete: { model.delete(task) })
                        .id(task.id)
                    Divider().padding(.leading, 9)
                }
            }

            if !model.historyTasks.isEmpty {
                HStack(spacing: 12) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showHistory.toggle() }
                    } label: {
                        HStack(spacing: 7) {
                            Text("历史记录").font(.system(size: 13, weight: .medium))
                            Text("\(model.historyTasks.count)").font(.caption.monospacedDigit())
                            Image(systemName: showHistory ? "chevron.up" : "chevron.down")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("清空历史") { confirmClearHistory = true }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("清空所有历史任务")
                }
                .padding(.top, 21)
                .padding(.bottom, 8)

                if showHistory {
                    ForEach(model.historyTasks) { task in
                        TaskRow(task: task, highlighted: false,
                                onReuse: {
                                    if model.hasPrompt && model.prompt != task.prompt {
                                        pendingReuse = task
                                    } else {
                                        applyReuse(task)
                                    }
                                },
                                onCancel: {}, onDelete: { model.delete(task) })
                        Divider().padding(.leading, 9)
                    }
                }
            }
        }
    }
}

@main struct CodexSchedulerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(CommandLine.arguments.contains("--preview-dark") ? .dark : nil)
        }
            .defaultSize(width: 680, height: 600)
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("聚焦提示词") {
                        NotificationCenter.default.post(name: .focusSchedulerPrompt, object: nil)
                    }
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
    }
}
