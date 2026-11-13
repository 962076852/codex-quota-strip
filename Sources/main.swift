import AppKit

final class QuotaClient {
    var onResult: ((Double, Double) -> Void)?
    var onError: ((String) -> Void)?
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var buffer = Data()
    private var ready = false
    private var pendingID: Int?
    private var nextID = 1
    private var timeout: DispatchWorkItem?
    private var generation = UUID()

    func refresh() {
        guard pendingID == nil else { return }
        if process?.isRunning != true { start(); return }
        guard ready else { return }
        let id = nextID; nextID += 1; pendingID = id
        send(["id": id, "method": "account/rateLimits/read"])
        armTimeout()
    }
    private func start() {
        stop()
        let candidates = [
            ProcessInfo.processInfo.environment["CODEX_CLI_PATH"],
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex"
        ].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            onError?("未找到 Codex，请确认已安装到应用程序目录"); return
        }
        let proc = Process(), stdinPipe = Pipe(), stdoutPipe = Pipe()
        let token = UUID(); generation = token
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["app-server", "--listen", "stdio://"]
        proc.standardInput = stdinPipe; proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                if data.isEmpty { self.connectionEnded(); return }
                self.receive(data)
            }
        }
        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.generation == token else { return }
                self.connectionEnded()
            }
        }
        process = proc; input = stdinPipe; output = stdoutPipe
        do {
            try proc.run()
            send(["id": 0, "method": "initialize", "params": ["clientInfo": ["name": "weekly_reset_widget", "version": "1.0.0"]]])
            armTimeout()
        } catch { stop(); onError?("连接失败，右键选择立即刷新") }
    }
    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        do { try input?.fileHandleForWriting.write(contentsOf: data + Data([10])) }
        catch { connectionEnded() }
    }
    private func armTimeout() {
        timeout?.cancel()
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.stop(); self.onError?("读取超时，将自动重试")
        }
        timeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + 25, execute: task)
    }
    private func receive(_ data: Data) {
        buffer.append(data)
        while let range = buffer.range(of: Data([10])) {
            let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, id == 0 {
                timeout?.cancel()
                guard object["error"] == nil else { stop(); onError?("初始化失败，稍后重试"); return }
                ready = true; send(["method": "initialized"]); refresh()
            } else if let id = object["id"] as? Int, id == pendingID {
                pendingID = nil; timeout?.cancel()
                guard let result = object["result"] as? [String: Any] else {
                    onError?("额度读取失败，请确认 Codex 已登录"); continue
                }
                apply(result)
            } else if object["method"] as? String == "account/rateLimits/updated",
                      let params = object["params"] as? [String: Any] { apply(params) }
        }
    }
    private func apply(_ result: [String: Any]) {
        guard let quota = WeeklyQuota.parse(result) else {
            onError?("当前没有可用的每周额度数据"); return
        }
        onResult?(quota.resetsAt, quota.remainingPercent)
    }
    private func connectionEnded() {
        guard process != nil else { return }
        stop(); onError?("连接已断开，将自动重试")
    }
    func stop() {
        generation = UUID(); timeout?.cancel(); timeout = nil
        output?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true { process?.terminate() }
        try? input?.fileHandleForWriting.close()
        process = nil; input = nil; output = nil
        ready = false; pendingID = nil; buffer.removeAll()
    }
}

final class DragSurface: NSVisualEffectView {
    override var mouseDownCanMoveWindow: Bool { true }
}
final class DragLabel: NSTextField {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
final class WidgetDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel!
    private let dateLabel = DragLabel(labelWithString: "—")
    private let weekdayLabel = DragLabel(labelWithString: "读取中")
    private let timeLabel = DragLabel(labelWithString: "—")
    private let captionLabel = DragLabel(labelWithString: "重置")
    private let remainingCaption = DragLabel(labelWithString: "剩余")
    private let percentLabel = DragLabel(labelWithString: "—")
    private let client = QuotaClient()
    private var timer: Timer?
    private var tick: Timer?
    private var reset: Double?
    private var remaining: Double?
    private var updated: Date?
    private var error: String?
    private var monitoring = false
    private var smokeTest = CommandLine.arguments.contains("--smoke-test")
    private let codexID = "com.openai.codex"

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !smokeTest {
            let bundleID = Bundle.main.bundleIdentifier ?? "io.github.codex-quota-strip"
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first { other.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return }
        }
        NSApp.setActivationPolicy(.accessory)
        panel = NSPanel(contentRect: NSRect(x: 24, y: 130, width: 52, height: 148),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.title = "Codex 每周重置"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        let restored = panel.setFrameUsingName("WeeklyResetVerticalPosition") || panel.setFrameUsingName("WeeklyResetCompactPosition")
        panel.setContentSize(NSSize(width: 52, height: 148))
        panel.setFrameAutosaveName("WeeklyResetVerticalPosition")
        if !restored, let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.minX + 12, y: screen.visibleFrame.minY + 100))
        }
        let effect = DragSurface(frame: NSRect(x: 0, y: 0, width: 52, height: 148))
        effect.material = .sidebar; effect.blendingMode = .behindWindow; effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true
        panel.contentView = effect
        captionLabel.frame = NSRect(x: 4, y: 126, width: 44, height: 12)
        captionLabel.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        captionLabel.textColor = .secondaryLabelColor
        dateLabel.frame = NSRect(x: 4, y: 102, width: 44, height: 17)
        dateLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        dateLabel.setAccessibilityLabel("每周重置日期")
        weekdayLabel.frame = NSRect(x: 4, y: 83, width: 44, height: 14)
        weekdayLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        weekdayLabel.textColor = .secondaryLabelColor
        timeLabel.frame = NSRect(x: 3, y: 50, width: 46, height: 18)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        timeLabel.setAccessibilityLabel("每周重置时间（北京时间）")
        remainingCaption.frame = NSRect(x: 4, y: 31, width: 44, height: 12)
        remainingCaption.font = NSFont.systemFont(ofSize: 9, weight: .regular)
        remainingCaption.textColor = .secondaryLabelColor
        percentLabel.frame = NSRect(x: 3, y: 10, width: 46, height: 19)
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        percentLabel.setAccessibilityLabel("每周剩余额度")
        for label in [captionLabel, dateLabel, weekdayLabel, timeLabel, remainingCaption, percentLabel] {
            label.alignment = .center
            label.lineBreakMode = .byClipping
            effect.addSubview(label)
        }
        let divider = NSView(frame: NSRect(x: 16, y: 75, width: 20, height: 1))
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
        effect.addSubview(divider)
        let menu = NSMenu()
        menu.addItem(withTitle: "立即刷新", action: #selector(refreshNow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "关于与使用方法", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出时间条", action: #selector(quitWidget), keyEquivalent: "").target = self
        effect.menu = menu
        for label in [captionLabel, dateLabel, weekdayLabel, timeLabel, remainingCaption, percentLabel] { label.menu = menu }
        client.onResult = { [weak self] reset, remaining in
            guard let self = self else { return }
            self.reset = reset; self.remaining = remaining; self.updated = Date(); self.error = nil
            self.render()
            if self.smokeTest { print("PASS: " + self.dateLabel.stringValue + " / " + self.weekdayLabel.stringValue + " / " + self.timeLabel.stringValue + " / " + self.percentLabel.stringValue + " | size=52x148"); NSApp.terminate(nil) }
        }
        client.onError = { [weak self] message in
            guard let self = self else { return }
            self.error = message; self.render()
            if self.smokeTest { fputs("FAIL: \(message)\n", stderr); exit(1) }
        }
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didWakeNotification] {
            nc.addObserver(self, selector: #selector(lifecycleChanged), name: name, object: nil)
        }
        syncLifecycle()
        timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            if self?.monitoring == true { self?.client.refresh() }
        }
        tick = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.syncLifecycle(); self?.render()
        }
    }
    @objc private func lifecycleChanged() { syncLifecycle() }
    private func syncLifecycle() {
        let running = smokeTest || !NSRunningApplication.runningApplications(withBundleIdentifier: codexID).isEmpty
        if running && !monitoring { monitoring = true; client.refresh() }
        if !running && monitoring {
            monitoring = false; client.stop(); reset = nil; remaining = nil; updated = nil; error = nil
            dateLabel.stringValue = "—"; weekdayLabel.stringValue = "读取中"; timeLabel.stringValue = "—"; percentLabel.stringValue = "—"
        }
        let visible = running && NSWorkspace.shared.frontmostApplication?.bundleIdentifier == codexID
        if visible && !smokeTest { panel.orderFrontRegardless() }
        else { panel.orderOut(nil) }
    }
    @objc private func refreshNow() { if monitoring { client.refresh() } }
    @objc private func quitWidget() { NSApp.terminate(nil) }
    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Codex 每周重置竖条"
        alert.informativeText = "拖动竖条任意文字即可调整位置，位置会自动保存。\n\n北京时间；每两分钟自动刷新。剩余高于 20% 显示绿色，6%–20% 显示橙色，5% 及以下显示红色。数据过期或刷新失败时显示灰色。悬停可查看更新时间。\n\nCodex 在前台时显示，退出或切换到其他程序时隐藏。后台助手保留运行，负责下次自动显示。\n\n此版本不读取 Codex 窗口位置，不能自动跟随窗口移动。"
        alert.runModal()
    }
    private func render() {
        guard let reset = reset, let remaining = remaining, let updated = updated else {
            dateLabel.stringValue = "—"
            weekdayLabel.stringValue = error == nil ? "读取中" : "重试中"
            timeLabel.stringValue = "—"
            percentLabel.stringValue = "—"
            percentLabel.textColor = .secondaryLabelColor
            remainingCaption.stringValue = "剩余"
            remainingCaption.textColor = .secondaryLabelColor
            for label in [captionLabel, dateLabel, weekdayLabel, timeLabel, remainingCaption, percentLabel] { label.toolTip = error ?? "北京时间；每两分钟自动刷新" }; return
        }
        let fmt = DateFormatter(); fmt.locale = Locale(identifier: "zh_CN")
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai"); fmt.dateFormat = "M/d"
        let passed = Date().timeIntervalSince1970 >= reset
        let stale = error != nil || Date().timeIntervalSince(updated) > 300
        let resetDate = Date(timeIntervalSince1970: reset)
        dateLabel.stringValue = fmt.string(from: resetDate)
        fmt.dateFormat = "EEE"
        weekdayLabel.stringValue = fmt.string(from: resetDate)
        fmt.dateFormat = "HH:mm"
        timeLabel.stringValue = fmt.string(from: resetDate)
        percentLabel.stringValue = "\(Int(remaining.rounded()))%"
        remainingCaption.stringValue = stale || passed ? "上次剩余" : "剩余"
        let displayedPercent = Int(remaining.rounded())
        if stale || passed {
            percentLabel.textColor = .secondaryLabelColor
            remainingCaption.textColor = .secondaryLabelColor
        } else {
            let color: NSColor
            switch RemainingLevel.classify(remaining) {
            case .normal: color = .systemGreen
            case .warning: color = .systemOrange
            case .critical: color = .systemRed
            }
            percentLabel.textColor = color
            remainingCaption.stringValue = displayedPercent <= 20 ? "● 剩余" : "剩余"
            remainingCaption.textColor = displayedPercent <= 20 ? color : .secondaryLabelColor
        }
        captionLabel.stringValue = passed ? "待更新" : (stale ? "重置*" : "重置")
        fmt.dateFormat = "M/d HH:mm"
        let help = "北京时间\n每周剩余 \(Int(remaining.rounded()))%\n更新于 \(fmt.string(from: updated))\n拖动调整位置，右键可退出" + (error.map { "\n刷新失败：" + $0 } ?? "")
        for label in [captionLabel, dateLabel, weekdayLabel, timeLabel, remainingCaption, percentLabel] { label.toolTip = help }
    }
    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate(); tick?.invalidate(); client.stop()
    }
}
let application = NSApplication.shared
let delegate = WidgetDelegate()
application.delegate = delegate
application.run()
