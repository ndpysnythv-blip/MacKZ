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
    /// 更新下载进度窗口
    private var updateProgressWindow: UpdateProgressWindow?
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
            if let reason = controller.unavailableReason { self.status?.setRenderStatus(reason) }
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
        settings.onManualProgress = { [weak self] value in self?.engine.setManualProgress(value) }
        // 模拟动画放慢到 2.2 秒，方便观察；replayIfFinished 让两个按钮都能反复点击
        settings.onSimulateClose = { [weak self] in
            self?.engine.playSingle(to: 1.0, duration: 2.2, replayIfFinished: true)
        }
        settings.onSimulateOpen = { [weak self] in
            self?.engine.playSingle(to: 0.0, duration: 2.2, replayIfFinished: true)
        }
        settings.onSetSleepDisabled = { [weak self] disabled in self?.setSleepDisabled(disabled) }
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

        // 启动后延迟自动检查更新（可在设置面板关闭）；发现新版本会直接弹出更新弹窗
        if config.autoCheckUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
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
        case .foldStart: config.triggerAngleDeg = angle
        case .foldEnd: config.closeAngleDeg = angle
        }
        // 触发角必须大于完全合上角，否则进度映射会反向
        if config.triggerAngleDeg - config.closeAngleDeg < 1 {
            notify("标定被拒绝", "「开始折叠」角必须比「完全合上」角至少大 1°，请重新标定。")
            return
        }
        ConfigStore.save(config)
        engine.apply(config: config)
        settings?.sync(config: config)
        notify("标定完成",
               String(format: "已把 %.1f° 设为「%@」。", angle, edge == .foldStart ? "开始折叠角" : "完全合上角"))
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

    // MARK: - 合盖休眠

    /// 设置「合盖不休眠」：让开盖时不再因为休眠弹锁屏，折叠动画才看得到。
    /// 需要管理员授权（会弹出系统密码框），完成后回写设置面板的状态显示。
    private func setSleepDisabled(_ disabled: Bool) {
        PowerControl.setSleepDisabled(disabled) { [weak self] result in
            guard let self else { return }
            self.settings?.refreshSleepState()
            switch result {
            case .success:
                self.notify(disabled ? "已开启「合盖不休眠」" : "已恢复「合盖即休眠」", disabled
                    ? """
                    合盖后系统会继续运行（显示器仍然会关闭），开盖时不会再因为休眠而要求解锁，
                    折叠动画就能正常播出来了。

                    注意：合盖状态下机器仍在耗电、不散热，放进包里前请点「恢复系统默认（合盖即休眠）」。

                    如果开盖后仍然要求输入密码，那不是休眠造成的，而是「锁定屏幕」策略：
                    点「打开「锁定屏幕」设置」，把「关闭显示器后需要密码」改成「永不」。
                    """
                    : "已恢复系统默认：合盖后正常休眠。")
            case .failure(let message):
                self.notify("设置失败", """
                \(message)

                也可以手动打开「终端」执行下面这条命令（需要输入开机密码）：

                    sudo pmset -a disablesleep \(disabled ? 1 : 0)
                """)
            }
        }
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
        alert.informativeText = "当前版本：\(UpdateChecker.currentVersion)"

        // 更新说明放进固定高度的滚动区域：
        // 之前把 600 字说明塞进 informativeText，会把按钮挤出弹窗，用户根本找不到按钮。
        let notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: 130))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.drawsBackground = true
            let textView = NSTextView(frame: scroll.bounds)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.font = .systemFont(ofSize: 11)
            textView.textContainerInset = NSSize(width: 6, height: 6)
            textView.string = notes
            scroll.documentView = textView
            alert.accessoryView = scroll
        }

        alert.addButton(withTitle: "立即更新并重启")
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "稍后")

        // 本应用没有 Dock 图标，弹窗可能被其它窗口挡住，这里强制置顶
        switch present(alert) {
        case .alertFirstButtonReturn:
            beginUpdate(release)
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
            self?.engine.playSingle(to: 0.0, duration: 0.7)      // 0 = 展开，收回正常画面
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            NSLog("[MacKZ] 即将睡眠（合盖）→ 播放合上动画")
            self?.engine.playSingle(to: 1.0, duration: 0.4)      // 1 = 折上
        }

        status?.setSensorStatus("无传感器，已用开盖/合盖触发")
        NSLog("[MacKZ] 本机无铰链角度传感器，已切换为「开盖唤醒 / 合盖睡眠」触发模式")
    }

    // MARK: - 更新下载

    /// 下载并安装更新：显示进度窗口（可随时取消）；成功则退出并交棒给替换脚本
    private func beginUpdate(_ release: UpdateChecker.Release) {
        let progressWindow = UpdateProgressWindow()
        progressWindow.show(version: release.version)
        updateProgressWindow = progressWindow

        // 允许随时取消：网络不通时不必干等
        progressWindow.onCancel = { [weak self] in
            UpdateChecker.cancelDownload()
            self?.updateProgressWindow = nil
            NSLog("[MacKZ] 用户取消更新下载")
        }

        UpdateChecker.downloadAndInstall(release, progress: { [weak progressWindow] fraction, detail in
            progressWindow?.update(fraction: fraction, detail: detail)
        }, completion: { [weak self] result in
            self?.updateProgressWindow?.close()
            self?.updateProgressWindow = nil
            switch result {
            case .success:
                NSLog("[MacKZ] 更新包下载完成，退出以便替换并重启")
                NSApp.terminate(nil)          // 交棒给更新脚本完成替换与重启
            case .failure(let error):
                self?.showUpdateFailure(error, release: release)
            }
        })
    }

    /// 更新失败提示：给出具体错误 + 可用的兜底安装方式
    private func showUpdateFailure(_ error: Error, release: UpdateChecker.Release) {
        let alert = NSAlert()
        alert.messageText = "更新下载失败"
        alert.informativeText = """
        \(error.localizedDescription)

        GitHub 的更新资源域名在部分网络环境下不稳定。可以改用终端命令安装（走 git 拉源码，通常更容易连通）：
        """
        alert.addButton(withTitle: "复制终端命令")
        alert.addButton(withTitle: "打开发布页")
        alert.addButton(withTitle: "关闭")
        switch present(alert) {
        case .alertFirstButtonReturn:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(UpdateChecker.terminalInstallCommand, forType: .string)
            notify("命令已复制", "粘贴到「终端」里执行，即可安装最新版本。")
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
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
        switch present(alert) {
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

    /// 统一配置弹窗：设置面板 1200 层、动画覆盖层 999 层、更新进度窗 1300 层，
    /// 普通 NSAlert 是默认层级会被它们压在下面（用户根本看不到），所以这里强制置顶到最高层，
    /// 并加入「所有空间」，保证全屏 App 上也能弹出。
    @discardableResult
    private func present(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let window = alert.window
        window.level = NSWindow.Level(rawValue: 2000)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.animationBehavior = .none
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        return alert.runModal()
    }

    /// 极简提示（统一走 present，保证不会被设置面板/覆盖层挡住）
    private func notify(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "好")
        present(alert)
    }
}
