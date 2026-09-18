import AppKit
import QuartzCore

/// 应用装配：传感器（数据源） -> 状态机（智能逻辑） -> 覆盖层（渲染），外加菜单栏开关。
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = ConfigStore.load()
    private let sensor = LidAngleSensor()
    private var engine: HingeAnimationEngine!
    private var overlay: OverlayController!
    private var status: StatusBarController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        ConfigStore.ensureExists()

        overlay = OverlayController(config: config)
        overlay.onStatus = { [weak self] message in self?.status.setRenderStatus(message) }
        engine = HingeAnimationEngine(config: config)
        engine.onUpdate = { [weak self] state in self?.overlay.render(state) }

        status = StatusBarController(config: config)
        status.engine = engine
        status.onToggleEnabled = { [weak self] on in self?.setEnabled(on) }
        status.onCalibrate = { [weak self] edge in self?.calibrate(edge) }
        status.onReload = { [weak self] in self?.reloadConfig() }
        status.onOpenConfig = { NSWorkspace.shared.open(ConfigStore.defaultURL) }
        status.onProbe = { [weak self] in self?.runProbe() }
        status.onRequestCapture = { [weak self] in self?.requestCapturePermission() }
        status.onDemo = { [weak self] in self?.engine.playDemo() }
        status.onQuit = { NSApp.terminate(nil) }

        // 传感器线程 -> 主线程（30Hz 级别的高频事实在太低，直接派发即可）
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        sensor.stop()
    }

    // MARK: - 菜单动作

    private func setEnabled(_ on: Bool) {
        config.enabled = on
        ConfigStore.save(config)
        engine.apply(config: config)
        engine.reset()                 // 清状态并隐藏覆盖层
        overlay.apply(config: config)
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
            notify("暂时读不到角度", "请先确认传感器可用（菜单：传感器探针）。")
            return
        }
        switch edge {
        case .closed: config.closedAngle = angle
        case .open: config.openAngle = angle
        }
        ConfigStore.save(config)
        engine.apply(config: config)
        notify("标定完成", String(format: "已把 %.1f° 设为「%@」。", angle, edge == .closed ? "完全闭合" : "完全打开"))
    }

    private func reloadConfig() {
        config = ConfigStore.load()
        engine.apply(config: config)
        overlay.apply(config: config)
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

    /// 申请「屏幕录制」权限：实时桌面重投影必需；未授权时动画无法显示画面。
    private func requestCapturePermission() {
        if CGPreflightScreenCaptureAccess() {
            notify("已获得屏幕录制权限", "现在可以实时重投影桌面画面了。")
            overlay.apply(config: config)
            return
        }
        let granted = CGRequestScreenCaptureAccess()
        notify(granted ? "授权成功" : "需要手动授权",
               granted ? "已可使用实时桌面画面。"
                       : "请在「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacKZ，然后退出并重新启动本插件。")
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
