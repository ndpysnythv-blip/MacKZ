import AppKit
import QuartzCore

/// 应用装配：传感器（数据源） -> 状态机（智能逻辑） -> 覆盖层（渲染），
/// 外加菜单栏开关与 App 内可视化设置面板。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = ConfigStore.load()
    private let sensor = LidAngleSensor()
    private var engine: HingeAnimationEngine!
    /// 覆盖渲染层；延后创建并且可为空，保证它的任何异常都不会影响菜单栏
    private var overlay: OverlayController?
    /// 无铰链角度传感器机型是否已切换到替代触发（开盖 / 合盖事件）
    private var fallbackTriggersEnabled = false
    private var status: StatusBarController!
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[MacKZ] 启动中，版本 %@", UpdateChecker.currentVersion)
        ConfigStore.ensureExists()

        // ---------- 菜单栏（最先创建：保证图标一定先出现，后续环节出错也不影响它）----------
        status = StatusBarController(config: config)

        engine = HingeAnimationEngine(config: config)
        engine.onUpdate = { [weak self] state in self?.overlay?.render(state) }
        status.engine = engine

        // ---------- 覆盖渲染层（延后创建：先让菜单栏稳定出现，渲染层的问题不影响菜单栏）----------
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let controller = OverlayController(config: self.config)
            controller.onStatus = { [weak self] message in self?.status?.setRenderStatus(message) }
            self.overlay = controller
            NSLog("[MacKZ] 渲染层已就绪")
        }

        status.onToggleEnabled = { [weak self] on in self?.setEnabled(on) }
        status.onCalibrate = { [weak self] edge in self?.calibrate(edge) }
        status.onReload = { [weak self] in self?.reloadConfig() }
        status.onOpenConfig = { NSWorkspace.shared.open(ConfigStore.defaultURL) }
        status.onOpenSettings = { [weak self] in self?.showSettings() }
        status.onProbe = { [weak self] in self?.runProbe() }
        status.onRequestCapture = { [weak self] in self?.requestCapturePermission() }
        status.onRepairCapture = { [weak self] in self?.repairCapturePermission() }
        status.onDemo = { [weak self] in self?.engine.playDemo() }
        status.onCheckUpdate = { [weak self] in self?.checkUpdate() }
        status.onQuit = { NSApp.terminate(nil) }

        // ---------- 可视化设置面板 ----------
        settings = SettingsWindowController(config: config)
        settings.onApply = { [weak self] newConfig in self?.apply(newConfig) }
        settings.onReload = { [weak self] in self?.reloadConfig() }
        settings.onProbe = { [weak self] in self?.runProbe() }
        settings.onDemo = { [weak self] in self?.engine.playDemo() }
        settings.onCheckUpdate = { [weak self] in self?.checkUpdate() }
        settings.onRequestCapture = { [weak self] in self?.requestCapturePermission() }
        settings.onRepairCapture = { [weak self] in self?.repairCapturePermission() }
        settings.statusProvider = { [weak self] in
            guard let self else { return (angle: "--", phase: "--", capture: "未知") }
            let angle = self.engine.lastAngleDeg.map { String(format: "%.1f°", $0) } ?? "--"
            let phase: String
            switch self.engine.phase {
            case .idle: phase = "待机"
            case .tracking: phase = "跟随角度"
            case .catchUp: phase = "加速补完"
            }
            return (angle: angle, phase: phase,
                    capture: CGPreflightScreenCaptureAccess() ? "已授权" : "未授权")
        }

        // 传感器线程 -> 主线程（30Hz 级别的派发开销可忽略）
        sensor.onAngle = { [weak self] angle in
            DispatchQueue.main.async {
                self?.engine.update(angle: angle, timestamp: CACurrentMediaTime())
            }
        }
        sensor.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                self?.status?.setSensorStatus(text)
                // 本机没有铰链角度传感器（如 MacBook Air 2020/M1）→ 自动切换到开盖/合盖触发
                if text.contains("未检测到") { self?.enableFallbackTriggers() }
            }
        }

        if config.enabled {
            sensor.start(with: config)
        } else {
            status.setSensorStatus("已停用")
        }

        // 启动自检：主动申请「屏幕录制」权限（拿到桌面画面才能做 Duo Continuity 重投影）
        ensureCapturePermission()

        // 启动后延迟自动检查更新（可在设置面板关闭）；更新包同样来自 GitHub Releases
        if config.autoCheckUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                self?.checkUpdate(silent: true)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
    }

    // MARK: - 配置应用

    /// 设置面板「保存并应用」：写盘 + 热重载引擎、渲染层、传感器
    private func apply(_ newConfig: Config) {
        config = newConfig
        ConfigStore.save(config)
        engine.apply(config: config)
        overlay?.apply(config: config)
        sensor.stop()
        if config.enabled {
            sensor.start(with: config)
        } else {
            status.setSensorStatus("已停用")
        }
        status.setEnabledState(config.enabled)
    }

    // MARK: - 菜单/面板动作

    private func showSettings() {
        settings.sync(config: config)
        settings.show()
    }

    private func setEnabled(_ on: Bool) {
        config.enabled = on
        ConfigStore.save(config)
        engine.apply(config: config)
        engine.reset()                 // 清状态并隐藏覆盖层
        overlay?.apply(config: config)
        settings?.sync(config: config)
        if on {
            sensor.start(with: config)
        } else {
            sensor.stop()
            status.setSensorStatus("已停用")
        }
    }

    /// 用当前角度标定端点：换机或摆放姿态不同时重新标一次即可
    private func calibrate(_ edge: StatusBarController.Calibration) {
        guard let angle = engine.lastAngleDeg else {
            notify("暂时读不到角度", "请先确认传感器可用（设置面板 → 传感器探针）。")
            return
        }
        switch edge {
        case .closed: config.closedAngle = angle
        case .open: config.openAngle = angle
        }
        ConfigStore.save(config)
        engine.apply(config: config)
        settings?.sync(config: config)
        notify("标定完成", String(format: "已把 %.1f° 设为「%@」。", angle, edge == .closed ? "完全闭合" : "完全打开"))
    }

    private func reloadConfig() {
        config = ConfigStore.load()
        engine.apply(config: config)
        overlay?.apply(config: config)
        settings?.sync(config: config)
        if config.enabled {
            sensor.stop()
            sensor.start(with: config)   // 采样率/匹配参数可能已改，重启传感器线程
        }
        notify("配置已重载", ConfigStore.defaultURL.path)
    }

    private func runProbe() {
        _ = LidAngleSensor.probe()
        notify("探针报告已生成", "已保存并打开：\(LidAngleSensor.reportURL.path)")
        NSWorkspace.shared.activateFileViewerSelecting([LidAngleSensor.reportURL])
    }

    // MARK: - 更新

    /// 检查 GitHub Release 是否有新版本；silent = true 时只在发现新版本才提示（供启动自检用）
    private func checkUpdate(silent: Bool = false) {
        UpdateChecker.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if !silent { self.notify("检查更新失败", error.localizedDescription) }
            case .success(.none):
                if !silent { self.notify("已是最新版本", "当前版本 \(UpdateChecker.currentVersion)。") }
            case .success(.some(let release)):
                self.promptUpdate(release)
            }
        }
    }

    /// 询问用户并执行更新（下载 → 退出 → 脚本替换 → 重启）
    private func promptUpdate(_ release: UpdateChecker.Release) {
        let alert = NSAlert()
        alert.messageText = "发现新版本 \(release.version)"
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "当前版本：\(UpdateChecker.currentVersion)\n\n"
            + (notes.isEmpty ? "（该版本没有附加说明）" : String(notes.prefix(600)))
        alert.addButton(withTitle: "立即更新并重启")
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            notify("正在下载更新", "下载完成后 MacKZ 会自动退出并重启，期间屏幕可能短暂闪动。")
            UpdateChecker.downloadAndInstall(release) { [weak self] result in
                switch result {
                case .success:
                    NSApp.terminate(nil)      // 交棒给更新脚本完成替换与重启
                case .failure(let error):
                    self?.notify("更新失败", error.localizedDescription + "\n可到发布页手动下载。")
                    NSWorkspace.shared.open(release.pageURL)
                }
            }
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    // MARK: - 无传感器机型的替代触发

    /// 本机没有 Lid Angle Sensor（如 MacBook Air 2020/M1）时启用替代触发：
    /// - 开盖 / 唤醒 → 播放「展开」动画（屏幕亮起，效果最明显）
    /// - 合盖 / 即将睡眠 → 播放「合上」动画（系统随即休眠，通常只来得及看到开头）
    private func enableFallbackTriggers() {
        guard !fallbackTriggersEnabled else { return }
        fallbackTriggersEnabled = true

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[MacKZ] 唤醒（开盖）→ 播放展开动画")
            self?.engine.playSingle(to: 1.0, duration: 0.7)
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[MacKZ] 即将睡眠（合盖）→ 播放合上动画")
            self?.engine.playSingle(to: 0.0, duration: 0.4)
        }

        status?.setSensorStatus("无传感器，已用开盖/合盖触发")
        NSLog("[MacKZ] 本机无铰链角度传感器，已切换为「开盖唤醒 / 合盖睡眠」触发模式")
    }

    // MARK: - 屏幕录制权限

    /// 启动自检：未授权则主动发起系统授权请求，并引导到系统设置
    private func ensureCapturePermission() {
        guard config.captureScreen else { return }
        guard !CGPreflightScreenCaptureAccess() else {
            status.setRenderStatus("权限就绪")
            return
        }
        status.setRenderStatus("缺少屏幕录制权限")
        // 系统授权弹窗会抢焦点，延后 1 秒等界面稳定；已拒绝过则直接返回 false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            if CGRequestScreenCaptureAccess() {
                self.relaunch(afterGrant: true)
            } else {
                self.notify("MacKZ 需要「屏幕录制」权限",
                            "用于把当前桌面画面折叠成 Duo Continuity 过渡动画。\n\n请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacKZ，然后重新启动本插件。")
                self.openPrivacySettings()
            }
        }
    }

    /// 菜单/面板主动申请：给出明确结果提示
    private func requestCapturePermission() {
        if CGPreflightScreenCaptureAccess() {
            notify("已获得屏幕录制权限", "现在可以实时重投影桌面画面了。")
            overlay?.apply(config: config)
            return
        }
        if CGRequestScreenCaptureAccess() {
            relaunch(afterGrant: true)
            return
        }
        // 走到这里说明系统不再弹窗：绝大多数情况是「更新后签名变化，旧的授权记录失配」。
        // 表现就是：系统设置里明明勾着 MacKZ，程序却一直显示未授权，再点授权也没反应。
        let alert = NSAlert()
        alert.messageText = "授权未生效"
        alert.informativeText = """
        MacKZ 使用的是本地临时签名，每次更新后签名都会变化，
        系统里保留的仍是上一个版本的授权记录，因此会出现“设置里已勾选、程序却说未授权”。

        点「修复权限」会自动清除这些过期记录，然后重新向你申请一次。
        """
        alert.addButton(withTitle: "修复权限")
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            repairCapturePermission()
        case .alertSecondButtonReturn:
            openPrivacySettings()
        default:
            break
        }
    }

    /// 清除本应用的「屏幕录制」授权记录（tccutil reset），让系统重新询问。
    /// 这是解决“更新后再也无法授权”的标准做法。
    private func repairCapturePermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mackz.plugin"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "ScreenCapture", bundleID]
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
            NSLog("[MacKZ] 已清除屏幕录制授权记录：%@", bundleID)
            notify("旧记录已清除",
                   "点「好」后 MacKZ 会重新申请权限，请在系统弹窗中点「允许」。\n若没有弹窗，请重启 MacKZ 再点一次「授权屏幕录制」。")
            requestCapturePermission()
        } catch {
            notify("自动清除失败",
                   "请在终端手动执行下面这条命令，然后重启 MacKZ：\n\ntccutil reset ScreenCapture \(bundleID)")
        }
    }

    /// 打开「系统设置 → 隐私与安全性 → 屏幕录制」面板
    private func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 授权后必须重启进程才能拿到画面，这里自动重启自身
    private func relaunch(afterGrant: Bool) {
        notify(afterGrant ? "授权成功" : "需要重启", afterGrant
               ? "权限已授予，MacKZ 将自动重启以让权限生效。"
               : "请重启 MacKZ 让权限生效。")
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }   // 直接跑二进制时不自动重启
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// 极简提示（不激活其它窗口时用 NSAlert 会抢焦点，这里仅在需要时弹一次）
    private func notify(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
