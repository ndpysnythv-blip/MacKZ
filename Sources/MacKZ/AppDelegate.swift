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
    /// 手机遥控（演示用）：局域网 HTTP 服务
    private let remote = RemoteControl()
    /// 官网中转通道（MQTT over WebSocket）：手机在官网页面上操作，陀螺仪也能用
    private let relay = RemoteRelay()
    private var remoteStatus = "未启动"
    /// 中转通道状态文本
    private var relayStatus = "中转未启动"
    /// 手机陀螺仪数据有效期：收到数据后一段时间内由手机接管角度，本机传感器读数被忽略
    private var phoneHingeDeadline: CFTimeInterval = 0
    private var phoneHingeWatchdog: Timer?
    /// 手机陀螺仪标定（放稳判定 + 两点标定，按钮都在设置面板上）
    private let phoneGyro = PhoneGyroCalibration()
    /// 手机陀螺仪是否已「开始使用」：引导走完之前只收数据用于标定，不驱动动画
    private var phoneGyroActive = false
    /// 引导弹窗本轮是否已经弹过（手机重新开始报数会重置）
    private var gyroWizardShown = false
    /// 设置引导弹窗
    private var gyroSetup: PhoneGyroSetupWindow?
    /// 最近一次收到手机角度的时间（用来识别手机重新开始报数）
    private var lastPhoneSample: CFTimeInterval = 0
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
        status.onOpenHomepage = { NSWorkspace.shared.open(UpdateChecker.homepageURL) }
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
        settings.onRefreshRemote = { [weak self] in self?.restartRemote() }
        settings.onOpenPairPage = { [weak self] in
            guard let url = self?.relay.pairPageURL, !url.isEmpty, let target = URL(string: url) else { return }
            NSWorkspace.shared.open(target)
        }
        settings.onOpenHomepage = { NSWorkspace.shared.open(UpdateChecker.homepageURL) }
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

        // ---------- 手机遥控 ----------
        // 主路径：手机在官网页面上操作，指令经公共中转（MQTT over WebSocket）回到 Mac；
        // 备用路径：局域网 HTTP 服务（中转不通时同 Wi-Fi 直连，但没有陀螺仪）。
        /// 把手机上的一条指令落到引擎上（两条路径共用）
        let handleCommand: (RemoteControl.Command) -> Void = { [weak self] command in
            guard let self else { return }
            switch command {
            case .close:
                self.engine.playSingle(to: 1.0, duration: 1.2)
            case .open:
                self.engine.playSingle(to: 0.0, duration: 1.2)
            case .play:
                self.engine.playDemo()
            case .progress(let value):
                self.engine.setManualProgress(value)
            }
        }
        remote.onCommand = handleCommand
        relay.onCommand = handleCommand
        remote.onStatus = { [weak self] text in
            self?.remoteStatus = text
            self?.settings?.refreshRemoteInfo()
        }
        // 中转状态只在局域网服务没给出结论时兜底显示，避免两行状态互相覆盖
        relay.onStatus = { [weak self] text in
            self?.relayStatus = text
            self?.settings?.refreshRemoteInfo()
        }
        // 手机陀螺仪：手机贴在屏幕上时，用手机姿态角代替铰链传感器
        remote.onHinge = { [weak self] angle in self?.acceptPhoneHinge(angle) }
        relay.onHinge = { [weak self] angle in self?.acceptPhoneHinge(angle) }
        // 中转需要把本机进度回传给手机页面显示
        relay.stateProvider = { [weak self] in
            guard let self else { return (progress: 0, angle: nil, phoneGyro: "setup") }
            return (progress: self.engine.progress, angle: self.engine.lastAngleDeg,
                    phoneGyro: self.phoneGyroActive ? "running" : "setup")
        }
        settings.remoteInfoProvider = { [weak self] in
            guard let self else {
                return (enabled: false, code: "", status: "未启动", localURL: "", pairURL: "")
            }
            let status = self.relay.isConnected ? "中转已连接" : self.relayStatus
            return (enabled: self.config.remoteControl, code: self.relay.code, status: status,
                    localURL: self.remote.accessURL, pairURL: self.relay.pairPageURL)
        }

        // ---------- 手机陀螺仪标定：手机贴在屏幕上时点不到手机页面，所以按钮都放这边 ----------
        settings.phoneGyroProvider = { [weak self] in
            guard let self, self.config.phoneGyro else {
                return (status: "手机姿态：未启用（先打开「允许手机陀螺仪接管角度」）", mapping: "", canCalibrate: false)
            }
            return (status: self.phoneGyro.statusText(), mapping: self.phoneGyro.mappingText(),
                    canCalibrate: self.phoneGyro.canCalibrate)
        }
        settings.onGyroCalibrateZero = { [weak self] in self?.calibratePhoneGyro { $0.calibrateClosedHere() } }
        settings.onGyroCalibrateOpen = { [weak self] in self?.calibratePhoneGyro { $0.calibrateOpenHere() } }
        settings.onGyroCalibrateReset = { [weak self] in
            self?.phoneGyro.reset()
            self?.phoneGyroActive = false
            self?.settings?.flashMessage("手机陀螺仪标定已复位（回到手机原始角度）")
            self?.settings?.refreshRemoteInfo()
        }
        settings.onOpenGyroSetup = { [weak self] in self?.showGyroSetup() }

        // 按配置启停手机遥控
        if config.remoteControl {
            relay.start()
            remote.start(port: UInt16(clamping: config.remoteControlPort))
        }

        // 传感器线程 -> 主线程（30Hz 级别的派发开销可忽略）
        sensor.onAngle = { [weak self] angle in
            DispatchQueue.main.async {
                guard let self else { return }
                // 手机陀螺仪接管期间忽略本机读数，避免两个数据源互相打架
                if CACurrentMediaTime() < self.phoneHingeDeadline { return }
                self.engine.update(angle: angle, timestamp: CACurrentMediaTime())
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
        relay.stop()
        remote.stop()
        phoneHingeWatchdog?.invalidate()
        phoneHingeWatchdog = nil
    }

    // MARK: - 手机陀螺仪接管铰链角度

    /// 手机把自身姿态换算成「屏幕开合角」后以 20Hz 上报（0 = 完全合上，与内置传感器同一套定义）。
    /// 收到第一帧即由手机接管角度，本机传感器读数被忽略；
    /// 超过 1.5 秒没有新数据（锁屏 / 切后台 / 离开 Wi-Fi）自动交还本机传感器。
    private func acceptPhoneHinge(_ angle: Double) {
        guard config.phoneGyro, angle.isFinite else { return }
        let now = CACurrentMediaTime()
        // 手机上报的是原始姿态角，这里按面板上的标定映射成铰链角
        let hinge = phoneGyro.ingest(raw: angle, at: now)
        maybeShowGyroSetup(now: now)
        // 引导没走完（还没点「开始使用」）之前，只收数据用于标定，不让手机驱动动画
        guard phoneGyroActive else { return }
        if now > phoneHingeDeadline {
            status.setSensorStatus("手机陀螺仪接管中")
            NSLog("[MacKZ] 手机陀螺仪开始接管铰链角度")
        }
        phoneHingeDeadline = now + 1.5
        engine.update(angle: hinge, timestamp: now, fromPhone: true)
        startPhoneHingeWatchdog()
    }

    // MARK: - 手机陀螺仪设置引导

    /// 手机拿到权限开始报数后，Mac 这边自动把引导弹出来（本轮只弹一次，关掉就不再打扰）
    private func maybeShowGyroSetup(now: CFTimeInterval) {
        if now - lastPhoneSample > 3 { gyroWizardShown = false }   // 手机重新开始报数 = 新一轮设置
        lastPhoneSample = now
        guard !phoneGyroActive, !gyroWizardShown else { return }
        gyroWizardShown = true
        showGyroSetup()
    }

    /// 打开设置引导弹窗（手机端点了「启用陀螺仪」后自动弹，也可以从设置面板手动打开）
    private func showGyroSetup() {
        if gyroSetup == nil {
            let window = PhoneGyroSetupWindow()
            window.onFixed = { [weak self] in self?.markPhoneFixed() }
            window.onOpenedMax = { [weak self] in self?.markScreenMaxOpen() }
            window.onStart = { [weak self] in self?.startPhoneGyroSession() }
            window.onRedo = { [weak self] in
                self?.phoneGyro.reset()
                self?.phoneGyroActive = false
                self?.settings?.refreshRemoteInfo()
            }
            window.statusProvider = { [weak self] in self?.phoneGyro.statusText() ?? "" }
            window.mappingProvider = { [weak self] in self?.phoneGyro.mappingText() ?? "" }
            gyroSetup = window
        }
        gyroSetup?.show()
    }

    /// 引导第 1 步：把手机当前位置记成「完全合上」（返回 nil 表示通过，否则是拦下的原因）
    private func markPhoneFixed() -> String? {
        guard phoneGyro.hasFreshData else {
            return "还没收到手机角度：先在手机控制页点「启用陀螺仪」并允许「运动与方向访问」"
        }
        guard phoneGyro.isSteady else { return "手机还在晃（\(gyroWobbleText)）：贴稳一点再点一次" }
        phoneGyro.calibrateClosedHere()
        return nil
    }

    /// 引导第 2 步：把手机当前位置记成「完全打开」
    private func markScreenMaxOpen() -> String? {
        guard phoneGyro.hasFreshData else { return "手机上没在上报角度了：检查它是否还在控制页前台" }
        guard phoneGyro.isSteady else { return "手机还在晃（\(gyroWobbleText)）：等屏幕停稳再点一次" }
        phoneGyro.calibrateOpenHere()
        return nil
    }

    /// 引导第 3 步：开始使用（此后手机陀螺仪接管铰链角度）
    private func startPhoneGyroSession() {
        phoneGyroActive = true
        phoneHingeDeadline = CACurrentMediaTime() + 1.5
        status.setSensorStatus("手机陀螺仪接管中")
        NSLog("[MacKZ] 手机陀螺仪设置完成，开始接管铰链角度")
        settings?.flashMessage("手机陀螺仪已开始使用")
        settings?.refreshRemoteInfo()
    }

    /// 晃动幅度文本（提示用）
    private var gyroWobbleText: String {
        phoneGyro.wobble.map { String(format: "±%.1f°", $0) } ?? "读数中"
    }

    /// 执行一次手机陀螺仪标定。
    /// 手机贴在屏幕上时读数会一直轻微晃动，晃着标定会把基准点标歪，
    /// 所以这里强制「收到数据 + 已放稳」才允许标，否则只在面板上提示。
    private func calibratePhoneGyro(_ action: (PhoneGyroCalibration) -> Void) {
        guard phoneGyro.hasFreshData else {
            settings.flashMessage("还没收到手机角度：先在手机控制页点「启用陀螺仪」")
            return
        }
        guard phoneGyro.isSteady else {
            let wobble = phoneGyro.wobble.map { String(format: "±%.1f°", $0) } ?? "读数中"
            settings.flashMessage("手机还在晃（\(wobble)），放稳后再点标定")
            return
        }
        action(phoneGyro)
        settings.flashMessage(phoneGyro.isCalibrated ? "标定完成：\(phoneGyro.mappingText())" : "标定已复位")
        settings.refreshRemoteInfo()
    }

    /// 看门狗：手机数据中断后把角度控制权交还本机传感器
    private func startPhoneHingeWatchdog() {
        guard phoneHingeWatchdog == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard CACurrentMediaTime() >= self.phoneHingeDeadline else { return }
            timer.invalidate()
            self.phoneHingeWatchdog = nil
            self.status.setSensorStatus(self.sensor.isRunning ? "运行中（Lid Angle Sensor）" : "已停用")
            NSLog("[MacKZ] 手机陀螺仪数据中断，已交还本机传感器")
        }
        RunLoop.main.add(timer, forMode: .common)
        phoneHingeWatchdog = timer
    }

    // MARK: - 手机遥控

    /// 换一个新连接码并重连官网中转；同时重启局域网直连服务（备用路径）。
    /// 手机上的旧连接码随即失效。
    private func restartRemote() {
        guard config.remoteControl else {
            relay.stop()
            remoteStatus = "未启动"
            relayStatus = "中转未启动"
            settings.refreshRemoteInfo()
            return
        }
        relay.start()
        remote.start(port: UInt16(clamping: config.remoteControlPort))
        settings.refreshRemoteInfo()
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

        // 手机遥控跟着配置热重启（开关/端口可能已改）
        if config.remoteControl {
            relay.start()
            remote.start(port: UInt16(clamping: config.remoteControlPort))
        } else {
            relay.stop()
            remote.stop()
            remoteStatus = "未启动"
            relayStatus = "中转未启动"
        }
        settings.refreshRemoteInfo()
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
            case .failure(let error):
                self.notify("设置失败", """
                \(error.localizedDescription)

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
        MacKZDialog(title: "发现新版本 \(release.version)",
                    message: "当前版本：\(UpdateChecker.currentVersion)",
                    notes: release.notes,
                    buttons: ["立即更新并重启", "打开官网", "查看更新说明", "稍后"]) { [weak self] index in
            switch index {
            case 0: self?.beginUpdate(release)
            case 1: NSWorkspace.shared.open(UpdateChecker.homepageURL)
            case 2: NSWorkspace.shared.open(release.pageURL)
            default: break
            }
        }.show()
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
                self?.showUpdateFailure(error)
            }
        })
    }

    /// 更新失败提示：给出具体错误 + 可用的兜底安装方式
    private func showUpdateFailure(_ error: Error) {
        MacKZDialog(title: "更新下载失败",
                    message: """
                    \(error.localizedDescription)

                    已自动尝试 GitHub 直连与多个加速节点。若仍失败，可用终端一键安装（多镜像下载，通常更容易连通）：
                    """,
                    buttons: ["复制终端命令", "打开官网", "关闭"]) { [weak self] index in
            switch index {
            case 0:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(UpdateChecker.terminalInstallCommand, forType: .string)
                self?.notify("命令已复制", "粘贴到「终端」里执行，即可安装最新版本。")
            case 1:
                NSWorkspace.shared.open(UpdateChecker.homepageURL)
            default:
                break
            }
        }.show()
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

    /// 菜单/面板「授权屏幕录制」：只负责「申请权限」这一件事。
    ///
    /// 这里刻意**不再**顺带弹出「修复权限」对话框：修复流程最后会再调用本方法，
    /// 两个弹窗互相调用会让用户点几次就开始来回弹（重复循环）。
    /// 修复权限只能从「修复屏幕录制权限」入口进入。
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
        // 走到这里说明系统这次不会再弹授权框（通常是之前拒绝过，或被系统记住不再询问）
        MacKZDialog(title: "请在系统设置里勾选 MacKZ",
                    message: """
                    系统这次没有弹出授权框，一般是因为之前拒绝过。

                    请到「系统设置 → 隐私与安全性 → 屏幕录制」中勾选 MacKZ，然后重新启动本插件。

                    如果列表里已经勾选却仍显示未授权（更新后常见），请用菜单里的「修复屏幕录制权限」清除过期记录。
                    """,
                    buttons: ["打开系统设置", "好"]) { [weak self] index in
            if index == 0 { self?.openPrivacySettings() }
        }.show()
    }

    /// 清除本应用的「屏幕录制」授权记录（tccutil reset），让系统重新询问。
    /// 这是解决“更新后再也无法授权”的标准做法。
    ///
    /// 两点注意：
    /// 1) tccutil 是外部进程，等它退出要几秒，放后台线程跑，否则界面会假死（点了没反应）；
    /// 2) 清完只再申请一次，绝不再弹「修复权限」对话框（否则会来回循环）。
    private func repairCapturePermission() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.mackz.plugin"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "ScreenCapture", bundleID]
            var succeeded = false
            do {
                try task.run()
                task.waitUntilExit()
                succeeded = task.terminationStatus == 0
            } catch {
                succeeded = false
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if succeeded {
                    NSLog("[MacKZ] 已清除屏幕录制授权记录：%@", bundleID)
                    self.notify("旧记录已清除",
                                "点「好」后 MacKZ 会重新申请一次「屏幕录制」权限，请在系统弹窗里点「允许」。") {
                        self.requestCapturePermission()
                    }
                } else {
                    self.notify("自动清除失败",
                                "请在终端手动执行下面这条命令，然后重启 MacKZ：\n\ntccutil reset ScreenCapture \(bundleID)")
                }
            }
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

    /// 极简提示。统一走 MacKZDialog：
    /// 非模态 + nonactivatingPanel + 按钮接受首次点击，不会被系统吞掉，也不会把 App 卡在模态会话里。
    /// - Parameter then: 用户点掉提示后要接着做的事（例如清完权限记录后重新申请）
    private func notify(_ title: String, _ text: String, then: (() -> Void)? = nil) {
        MacKZDialog(title: title, message: text, buttons: ["好"]) { _ in then?() }.show()
    }
}
