import AppKit
import QuartzCore

/// 应用装配：传感器（数据源） -> 状态机（智能逻辑） -> 覆盖层（渲染），
/// 外加菜单栏开关与 App 内可视化设置面板。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = ConfigStore.load()
    private let sensor = LidAngleSensor()
    private var engine: HingeAnimationEngine!
    private var overlay: OverlayController!
    private var status: StatusBarController!
    private var settings: SettingsWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.ensureExists()

        overlay = OverlayController(config: config)
        overlay.onStatus = { [weak self] message in self?.status.setRenderStatus(message) }
        engine = HingeAnimationEngine(config: config)
        engine.onUpdate = { [weak self] state in self?.overlay.render(state) }

        // ---------- 菜单栏 ----------
        status = StatusBarController(config: config)
        status.engine = engine
        status.onToggleEnabled = { [weak self] on in self?.setEnabled(on) }
        status.onCalibrate = { [weak self] edge in self?.calibrate(edge) }
        status.onReload = { [weak self] in self?.reloadConfig() }
        status.onOpenConfig = { NSWorkspace.shared.open(ConfigStore.defaultURL) }
        status.onOpenSettings = { [weak self] in self?.showSettings() }
        status.onProbe = { [weak self] in self?.runProbe() }
        status.onRequestCapture = { [weak self] in self?.requestCapturePermission() }
        status.onDemo = { [weak self] in self?.engine.playDemo() }
        status.onQuit = { NSApp.terminate(nil) }

        // ---------- 可视化设置面板 ----------
        settings = SettingsWindowController(config: config)
        settings.onApply = { [weak self] newConfig in self?.apply(newConfig) }
        settings.onReload = { [weak self] in self?.reloadConfig() }
        settings.onProbe = { [weak self] in self?.runProbe() }
        settings.onDemo = { [weak self] in self?.engine.playDemo() }
        settings.onRequestCapture = { [weak self] in self?.requestCapturePermission() }
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
            DispatchQueue.main.async { self?.status.setSensorStatus(text) }
        }

        if config.enabled {
            sensor.start(with: config)
        } else {
            status.setSensorStatus("已停用")
        }

        // 启动自检：主动申请「屏幕录制」权限（拿到桌面画面才能做 Duo Continuity 重投影）
        ensureCapturePermission()
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
        overlay.apply(config: config)
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
        overlay.apply(config: config)
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
        overlay.apply(config: config)
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
            overlay.apply(config: config)
            return
        }
        if CGRequestScreenCaptureAccess() {
            relaunch(afterGrant: true)
        } else {
            notify("需要手动授权",
                   "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacKZ，然后重新启动本插件。")
            openPrivacySettings()
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
