import AppKit
import IOKit
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// MARK: - Shell 工具

@discardableResult
private func runShell(_ command: String) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/zsh")
    task.arguments = ["-c", command]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

// MARK: - 闲置睡眠阻断（IOKit 电源断言，免 root）

final class IdleGuard {
    static let shared = IdleGuard()
    private var idleID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private var lidIdleID: IOPMAssertionID = 0   // 合盖模式下防止系统闲置睡眠（合盖阻断的配套保证）
    private(set) var active = false
    private(set) var deadline: Date?

    var keepDisplayAwake: Bool = UserDefaults.standard.object(forKey: "keepDisplay") as? Bool ?? false {
        didSet { UserDefaults.standard.set(keepDisplayAwake, forKey: "keepDisplay") }
    }
    /// 合盖阻断是否生效（决定屏幕常亮断言是否可以被挂上）
    private(set) var lidActive = false

    /// 屏幕常亮断言的前提：闲置阻断或合盖阻断至少一个在生效
    var screenKeepActive: Bool { active || lidActive }

    var remaining: TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSinceNow)
    }

    private let reason = "KeepAwake: 用户手动保持唤醒" as CFString

    func start(minutes: Double?) {
        stop()
        var newIdle: IOPMAssertionID = 0
        let ok = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newIdle
        ) == kIOReturnSuccess
        guard ok else { return }
        idleID = newIdle
        active = true
        deadline = minutes.map { Date().addingTimeInterval($0 * 60) }
        syncDisplay()
    }

    func stop() {
        if idleID != 0 { IOPMAssertionRelease(idleID); idleID = 0 }
        active = false
        deadline = nil
        syncDisplay() // 若合盖阻断仍在生效，屏幕常亮断言不会被误放
    }

    func setKeepDisplayAwake(_ value: Bool) {
        keepDisplayAwake = value
        syncDisplay()
    }

    /// 合盖阻断开启/关闭：挂系统闲置断言（防合盖挂机中被闲置超时睡掉）+ 同步屏幕常亮断言
    func setLidKeepAwake(_ on: Bool) {
        lidActive = on
        if on && lidIdleID == 0 {
            var newID: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "KeepAwake: 合盖保持运行" as CFString,
                &newID
            ) == kIOReturnSuccess {
                lidIdleID = newID
            }
        } else if !on && lidIdleID != 0 {
            IOPMAssertionRelease(lidIdleID)
            lidIdleID = 0
        }
        syncDisplay()
    }

    /// 统一管理屏幕常亮断言：只在「有阻止生效 且 勾选了常亮」时持有，其余情况一律释放
    private func syncDisplay() {
        if screenKeepActive && keepDisplayAwake {
            if displayID == 0 { createDisplayAssertion() }
        } else if displayID != 0 {
            IOPMAssertionRelease(displayID)
            displayID = 0
        }
    }

    /// 仅设置到期时间（不创建电源断言），用于只开合盖阻断时也能倒计时
    func armDeadline(minutes: Double) {
        deadline = Date().addingTimeInterval(minutes * 60)
    }

    /// 到期返回 true，便于外部提示
    func checkDeadline() -> Bool {
        guard let deadline, Date() >= deadline else { return false }
        stop()
        return true
    }

    private func createDisplayAssertion() {
        var newDisplay: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &newDisplay
        ) == kIOReturnSuccess {
            displayID = newDisplay
        }
    }
}

// MARK: - 合盖睡眠阻断（需要 root：特权助手轮询，或降级为管理员授权弹窗）

final class LidController {
    static let shared = LidController()
    static let dir = "/Library/Application Support/KeepAwake"
    static let stateFile = dir + "/lid.state"
    static let helperMarker = dir + "/apply.sh"

    private(set) var enabled: Bool = LidController.readSystemState()

    /// 无需 root 即可读取：pmset -g 输出中的 SleepDisabled 字段
    static func readSystemState() -> Bool {
        let out = runShell("pmset -g")
        guard let range = out.range(of: "SleepDisabled") else { return false }
        let tail = out[range.upperBound...]
        let digits = tail.compactMap { $0.isNumber ? $0 : nil }
        return digits.first == "1"
    }

    var helperInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: Self.helperMarker)
    }

    var stateWritable: Bool {
        FileManager.default.isWritableFile(atPath: Self.dir)
    }

    func syncFromSystem() {
        enabled = Self.readSystemState()
    }

    /// 返回 (是否成功, 是否走了管理员授权弹窗)
    func set(_ on: Bool) -> (ok: Bool, usedAuthPrompt: Bool) {
        if stateWritable {
            do {
                try "\(on ? 1 : 0)".write(toFile: Self.stateFile, atomically: true, encoding: .utf8)
                var applied = false
                for _ in 0..<15 {
                    Thread.sleep(forTimeInterval: 0.4)
                    if Self.readSystemState() == on { applied = true; break }
                }
                enabled = Self.readSystemState()
                return (applied || enabled == on, false)
            } catch {
                return (false, false)
            }
        }

        // 降级：弹管理员授权框直接执行 pmset
        let script = "do shell script \"pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        guard let osa = NSAppleScript(source: script) else { return (false, true) }
        var errorInfo: NSDictionary?
        osa.executeAndReturnError(&errorInfo)
        syncFromSystem()
        return (errorInfo == nil, true)
    }
}

// MARK: - 合盖/开盖检测（pmset disablesleep 会吞掉盖子事件，需要自己盯）

final class LidWatcher {
    var onClosed: (() -> Void)?
    var onOpened: (() -> Void)?
    private var timer: Timer?
    private var lastClosed: Bool?

    /// 读盖子状态：Apple Silicon 从 IOPMrootDomain 读 AppleClamshellState（实测本机可用）；
    /// Intel 的 AppleSmartBattery/LidClosed 作兜底。都读不到返回 nil，静默降级。
    private static func lidClosed() -> Bool? {
        // 1) IOPMrootDomain.AppleClamshellState
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        if root != 0 {
            defer { IOObjectRelease(root) }
            if let prop = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue(), let v = prop as? Bool {
                return v
            }
        }
        // 2) 兜底：AppleSmartBattery.LidClosed（Intel 机型）
        let battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard battery != 0 else { return nil }
        defer { IOObjectRelease(battery) }
        guard let prop = IORegistryEntryCreateCFProperty(battery, "LidClosed" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() else { return nil }
        return prop as? Bool
    }

    func start() {
        guard timer == nil else { return }
        lastClosed = Self.lidClosed()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let closed = Self.lidClosed(), closed != self.lastClosed else { return }
            self.lastClosed = closed
            if closed { self.onClosed?() } else { self.onOpened?() }
        }
    }
}

// MARK: - 定时预设

private let presets: [(String, Double?)] = [
    ("手动（一直保持）", nil),
    ("30 分钟", 30),
    ("1 小时", 60),
    ("2 小时", 120),
    ("4 小时", 240),
    ("8 小时", 480)
]

// MARK: - 菜单栏界面

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var titleItem: NSMenuItem!
    private var idleItem: NSMenuItem!
    private var lidItem: NSMenuItem!
    private var timerMenu: NSMenu!
    private var displayItem: NSMenuItem!
    private var loginItem: NSMenuItem!

    private let idle = IdleGuard.shared
    private let lid = LidController.shared
    private let watcher = LidWatcher()
    private var selectedPreset: Int = UserDefaults.standard.integer(forKey: "preset")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        buildMenu()
        lid.syncFromSystem()
        if lid.enabled { idle.setLidKeepAwake(true) }
        // 合盖时灭屏、开盖时亮屏（仅在"阻止合盖睡眠"生效且未勾选屏幕常亮时）
        watcher.onClosed = { [weak self] in
            guard let self, self.lid.enabled, !self.idle.keepDisplayAwake else { return }
            _ = runShell("pmset displaysleepnow")
        }
        watcher.onOpened = { [weak self] in
            guard let self, self.lid.enabled, !self.idle.keepDisplayAwake else { return }
            _ = runShell("caffeinate -u -t 2") // 模拟用户活动，唤醒显示器
        }
        watcher.start()
        refresh()
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let justEnded = self.idle.checkDeadline()
            if justEnded && self.lid.enabled && self.lid.stateWritable {
                try? "0".write(toFile: LidController.stateFile, atomically: true, encoding: .utf8)
                self.lid.syncFromSystem()
                self.idle.setLidKeepAwake(false)
            }
            self.refresh()
            if justEnded { self.notify("定时已结束", "防休眠已全部恢复系统默认策略") }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        idle.stop()
        idle.setLidKeepAwake(false)
        // 合盖阻断是系统级设置，退出时写回 0，避免用户离开后电脑永不休眠
        if lid.enabled && lid.stateWritable {
            try? "0".write(toFile: LidController.stateFile, atomically: true, encoding: .utf8)
        }
    }

    // MARK: 菜单构建

    private func buildMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.behavior = [.removalAllowed]

        let menu = NSMenu()
        menu.autoenablesItems = false // 由 refresh() 手动控制，实现"常亮"项的条件置灰

        titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        menu.addItem(titleItem)

        idleItem = NSMenuItem(title: "", action: #selector(toggleIdle(_:)), keyEquivalent: "")
        idleItem.target = self
        menu.addItem(idleItem)

        lidItem = NSMenuItem(title: "", action: #selector(toggleLid(_:)), keyEquivalent: "")
        lidItem.target = self
        menu.addItem(lidItem)

        timerMenu = NSMenu()
        for (index, preset) in presets.enumerated() {
            let item = NSMenuItem(title: preset.0, action: #selector(applyPreset(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            timerMenu.addItem(item)
        }
        let timerParent = NSMenuItem(title: "定时自动关闭", action: nil, keyEquivalent: "")
        timerParent.submenu = timerMenu
        menu.addItem(timerParent)

        displayItem = NSMenuItem(title: "保持屏幕常亮", action: #selector(toggleDisplay(_:)), keyEquivalent: "")
        displayItem.target = self
        menu.addItem(displayItem)

        loginItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出 KeepAwake", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: 界面刷新

    private func refresh() {
        let anyOn = idle.active || lid.enabled

        var parts: [String] = []
        parts.append(idle.active ? "闲置睡眠：已阻止" : "闲置睡眠：允许")
        parts.append(lid.enabled ? "合盖睡眠：已阻止" : "合盖睡眠：允许")
        if anyOn {
            parts.append(idle.keepDisplayAwake ? "屏幕：常亮" : "屏幕：可熄灭")
        }
        if let remain = idle.remaining {
            parts.append("剩余 " + Self.format(remain))
        }
        titleItem.title = parts.joined(separator: " · ")

        idleItem.title = idle.active ? "停止阻止闲置睡眠" : "阻止闲置睡眠"
        idleItem.state = idle.active ? .on : .off

        lidItem.title = lid.enabled ? "停止阻止合盖睡眠" : "阻止合盖睡眠"
        lidItem.state = lid.enabled ? .on : .off

        displayItem.title = "保持屏幕常亮"
        displayItem.state = idle.keepDisplayAwake ? .on : .off
        displayItem.isEnabled = anyOn // 两个阻止都没开时置灰，不允许单独开屏幕常亮
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off

        for item in timerMenu.items {
            item.state = (item.tag == selectedPreset) ? .on : .off
        }

        if let remain = idle.remaining {
            statusItem.button?.title = " " + Self.format(remain)
        } else {
            statusItem.button?.title = ""
        }
        statusItem.button?.toolTip = anyOn ? "KeepAwake：正在阻止睡眠" : "KeepAwake：点击开启防休眠"

        let name = anyOn ? "sun.max.fill" : "moon.fill"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "KeepAwake")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // MARK: 动作

    @objc private func toggleIdle(_ sender: Any?) {
        if idle.active {
            idle.stop()
        } else {
            idle.start(minutes: presets[selectedPreset].1)
        }
        refresh()
    }

    @objc private func toggleLid(_ sender: Any?) {
        let want = !lid.enabled
        let result = lid.set(want)
        if lid.enabled {
            idle.setLidKeepAwake(true) // 合盖阻断生效期间，系统闲置也不许睡
            if !idle.active, let m = presets[selectedPreset].1 {
                idle.armDeadline(minutes: m) // 只开合盖阻断时也要让"定时自动关闭"生效
            }
        } else {
            idle.setLidKeepAwake(false)
            if !idle.active { idle.stop() } // 仅清除倒计时，无副作用
        }
        refresh()
        if !result.ok {
            let alert = NSAlert()
            alert.messageText = "设置失败"
            alert.informativeText = result.usedAuthPrompt
                ? "管理员授权被取消或执行出错，合盖睡眠策略未更改。"
                : "特权助手未响应，合盖睡眠策略未更改。请重新运行安装命令修复。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        } else if result.usedAuthPrompt {
            notify(want ? "合盖睡眠已阻止" : "合盖睡眠已恢复", "策略已写入系统")
        }
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        selectedPreset = sender.tag
        UserDefaults.standard.set(selectedPreset, forKey: "preset")
        if idle.active {
            idle.start(minutes: presets[selectedPreset].1)
        }
        refresh()
    }

    @objc private func toggleDisplay(_ sender: Any?) {
        guard idle.active || lid.enabled else { NSSound.beep(); return }
        idle.setKeepDisplayAwake(!idle.keepDisplayAwake)
        refresh()
    }

    @objc private func toggleLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSAlert(error: error).runModal()
        }
        refresh()
    }

    @objc private func quitApp(_ sender: Any?) {
        idle.stop()
        NSApp.terminate(nil)
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// MARK: - 入口

let application = NSApplication.shared
let appDelegate = AppDelegate()
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
