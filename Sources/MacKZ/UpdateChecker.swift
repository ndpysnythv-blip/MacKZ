import AppKit

/// 更新检查与自更新。
/// 数据源：GitHub Releases（公开仓库，无需 token）。
/// 自更新流程：下载 zip → 落盘到 Application Support → 生成替换脚本 → 退出自身 → 脚本解压覆盖并重启。
///
/// 网络说明：GitHub 的 release 资源域名在部分网络环境下不稳定，
/// 因此这里做了「超时放宽 + 等待网络 + 失败自动重试 3 次 + 详细错误上报」。
enum UpdateChecker {

    /// 仓库标识（owner/repo）
    static let repository = "ndpysnythv-blip/MacKZ"

    /// 一个可用的新版本
    struct Release {
        let version: String      // 规范化版本号，如 "1.3.1"
        let notes: String        // Release 说明
        let zipURL: URL          // MacKZ.zip 直链
        let pageURL: URL         // Release 页面
    }

    enum UpdateError: LocalizedError {
        case badResponse(Int)
        case noAsset
        case network(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "服务器返回异常（HTTP \(code)）"
            case .noAsset:               return "该版本没有可下载的安装包"
            case .network(let message):  return "网络错误：\(message)"
            case .cannotWrite(let path): return "没有写入权限：\(path)"
            }
        }
    }

    /// 终端一键安装命令（下载失败时给用户兜底）
    /// 指向 install-raw.sh：它优先整包下载并带假死检测与多镜像回退，比 git 拉源码更适应受限网络
    static let terminalInstallCommand =
        "curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-raw.sh | bash"

    // MARK: - 版本信息

    /// 当前 App 版本（读取 Info.plist 的 CFBundleShortVersionString）
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 版本号规范化："v1.3.1" → [1, 3, 1]
    private static func versionParts(_ text: String) -> [Int] {
        text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
    }

    /// a 是否比 b 新
    private static func isNewer(_ a: [Int], than b: [Int]) -> Bool {
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - 检查更新

    /// 检查最新 Release；回调在主线程，`nil` 表示已是最新版本
    static func check(completion: @escaping (Result<Release?, UpdateError>) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            completion(.failure(.badResponse(-1)))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        URLSession.shared.dataTask(with: request) { data, _, error in
            let finish: (Result<Release?, UpdateError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(.failure(.network(error.localizedDescription)))
                return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                finish(.failure(.badResponse(-1)))
                return
            }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            let zipURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repository)/releases")!

            guard isNewer(versionParts(tag), than: versionParts(currentVersion)) else {
                finish(.success(nil))
                return
            }
            guard let zipURL else {
                finish(.failure(.noAsset))
                return
            }
            finish(.success(Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")),
                                    notes: (json["body"] as? String) ?? "",
                                    zipURL: zipURL,
                                    pageURL: pageURL)))
        }.resume()
    }

    // MARK: - 下载并安装

    /// 保持下载器强引用（URLSession delegate 需要对象存活到任务结束）
    private static var activeDownloader: UpdateDownloader?

    /// 下载新版本并安排替换重启。
    /// - progress: (进度 0~1，状态文本)，进度 < 0 表示不确定进度（连接中/重试中）
    /// - completion: 成功后调用方应主动退出 App，交棒给更新脚本
    static func downloadAndInstall(_ release: Release,
                                   progress: @escaping (Double, String) -> Void,
                                   completion: @escaping (Result<Void, UpdateError>) -> Void) {
        // 直接跑二进制（非 .app）时无法自替换
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            DispatchQueue.main.async { completion(.failure(.cannotWrite(bundlePath))) }
            return
        }
        let updateDir = ConfigStore.directory.appendingPathComponent("update", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: updateDir, withIntermediateDirectories: true)
        } catch {
            DispatchQueue.main.async { completion(.failure(.cannotWrite(updateDir.path))) }
            return
        }
        let zipPath = updateDir.appendingPathComponent("MacKZ.zip")

        let downloader = UpdateDownloader(release: release, destination: zipPath, progress: progress) { result in
            activeDownloader = nil
            switch result {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                do {
                    let script = try makeInstallScript(updateDir: updateDir, zipPath: zipPath, targetApp: bundlePath)
                    launchDetached(script)
                    completion(.success(()))
                } catch {
                    completion(.failure(.cannotWrite(error.localizedDescription)))
                }
            }
        }
        activeDownloader = downloader
        downloader.start()
    }

    /// 取消正在进行的下载（用户点「取消」时调用）
    static func cancelDownload() {
        activeDownloader?.cancel()
        activeDownloader = nil
    }

    /// 生成替换脚本：等主进程退出 → 解压 → 覆盖原 .app → 清 TCC 旧记录 → 重新启动
    private static func makeInstallScript(updateDir: URL, zipPath: URL, targetApp: String) throws -> URL {
        let script = """
        #!/bin/sh
        # MacKZ 自动更新脚本（由 App 生成，执行完自行删除）
        set -u
        APP="\(targetApp)"
        ZIP="\(zipPath.path)"
        WORK="\(updateDir.path)/unzip"

        # 1) 等待主程序退出，最多 30 秒
        i=0
        while [ $i -lt 60 ]; do
          pgrep -f "$APP/Contents/MacOS/MacKZ" >/dev/null 2>&1 || break
          sleep 0.5
          i=$((i + 1))
        done

        # 2) 解压
        rm -rf "$WORK"
        mkdir -p "$WORK"
        ditto -x -k "$ZIP" "$WORK" || exit 1

        # 3) 覆盖安装（保持原路径，避免用户手动搬运）
        if [ -d "$WORK/MacKZ.app" ]; then
          rm -rf "$APP"
          cp -R "$WORK/MacKZ.app" "$APP" || exit 1
          xattr -cr "$APP" 2>/dev/null
          codesign --force --deep --sign - "$APP" 2>/dev/null
          # 4) 清掉上一个版本残留的屏幕录制授权记录：
          #    更新后签名变化会让 TCC 记录与新版本失配，
          #    表现为「系统设置里已勾选，程序却一直显示未授权且无法再授权」
          tccutil reset ScreenCapture com.mackz.plugin 2>/dev/null || true
          open "$APP"
        fi

        # 5) 清理
        rm -rf "$WORK" "$ZIP" "$0"
        """
        let scriptURL = updateDir.appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    /// 用 nohup 脱离当前进程启动脚本，保证 App 退出后脚本仍能继续执行
    private static func launchDetached(_ scriptURL: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "nohup /bin/sh '\(scriptURL.path)' >/dev/null 2>&1 &"]
        try? process.run()
    }
}

// MARK: - 下载器（带进度回调与自动重试）

/// 用 URLSessionDownloadDelegate 拿到下载进度；失败自动重试，避免网络抖动一次就放弃。
private final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {

    private static let maxAttempts = 3

    private let release: UpdateChecker.Release
    private let destination: URL
    private let progress: (Double, String) -> Void
    private let completion: (Result<Void, UpdateChecker.UpdateError>) -> Void

    private var session: URLSession?
    private var attempt = 0
    private var finished = false
    private var movedToDestination = false
    private var lastError: UpdateChecker.UpdateError?

    init(release: UpdateChecker.Release, destination: URL,
         progress: @escaping (Double, String) -> Void,
         completion: @escaping (Result<Void, UpdateChecker.UpdateError>) -> Void) {
        self.release = release
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    func start() {
        attempt += 1
        movedToDestination = false
        lastError = nil

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 180          // 单个文件最长 3 分钟，避免长时间卡在“加载中”
        config.waitsForConnectivity = false              // 不通就尽快失败并重试，而不是无限等待
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let tip = attempt == 1 ? "正在连接 GitHub…" : "连接不稳定，正在重试（第 \(attempt)/\(Self.maxAttempts) 次）…"
        DispatchQueue.main.async { [weak self] in self?.progress(-1, tip) }
        session.downloadTask(with: release.zipURL).resume()
    }

    /// 取消下载：不再重试、不再回调
    func cancel() {
        finished = true
        session?.invalidateAndCancel()
        session = nil
    }

    // MARK: 下载进度
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let text = String(format: "已下载 %.0f%%（%.0f KB / %.0f KB）",
                          fraction * 100,
                          Double(totalBytesWritten) / 1024,
                          Double(totalBytesExpectedToWrite) / 1024)
        DispatchQueue.main.async { [weak self] in self?.progress(fraction, text) }
    }

    // MARK: 下载完成（临时文件在此处必须同步搬走）
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            lastError = .badResponse(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            movedToDestination = true
        } catch {
            lastError = .cannotWrite(error.localizedDescription)
        }
    }

    // MARK: 任务结束（成功或失败）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        guard !finished else { return }

        if movedToDestination {
            finished = true
            DispatchQueue.main.async { [weak self] in self?.completion(.success(())) }
            return
        }
        if let error {
            lastError = .network((error as NSError).localizedDescription + "（代码 \((error as NSError).code)）")
        }

        if attempt < Self.maxAttempts {
            NSLog("[MacKZ] 下载失败（第 %d 次），1.2 秒后重试：%@",
                  attempt, lastError?.localizedDescription ?? "未知")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.start() }
        } else {
            finished = true
            let finalError = lastError ?? .badResponse(-1)
            DispatchQueue.main.async { [weak self] in self?.completion(.failure(finalError)) }
        }
    }
}

// MARK: - 顶层窗口层级

/// 弹窗与更新进度窗统一使用的层级。
/// 必须高于覆盖动画层（999）与设置面板（1200），否则会被自己的窗口压住 ——
/// 用户反馈的「更新弹窗老是在下面」就是这个原因。3000 只是「足够高」的示意值，
/// macOS 允许任意整数层级，层级比较优先于同层内窗口的前后顺序。
let macKZTopWindowLevel = NSWindow.Level(rawValue: 3000)

/// 把本应用激活到前台。
/// 本应用是 LSUIElement（没有 Dock 图标），macOS 14 起 `activate(ignoringOtherApps:)` 已废弃且不再可靠，
/// 因此再走一遍 NSRunningApplication，否则窗口虽然显示了却拿不到焦点、看起来像「弹在下面」。
func macKZActivateSelf() {
    NSApp.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
}

// MARK: - 下载进度窗口

/// 更新下载进度浮窗：显示进度条与实时状态，浮在所有窗口之上，可随时取消。
final class UpdateProgressWindow: NSObject {

    /// 用户点击「取消」
    var onCancel: (() -> Void)?

    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let cancelButton = NSButton()

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
                          styleMask: [.titled],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "MacKZ 更新"
        window.isReleasedWhenClosed = false
        window.level = macKZTopWindowLevel              // 高于设置面板(1200)与覆盖动画层(999)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hidesOnDeactivate = false
        window.center()

        titleLabel.font = .boldSystemFont(ofSize: 13)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle

        bar.isIndeterminate = true          // 连接阶段先转圈，拿到总大小后切成实数进度
        bar.controlSize = .small
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.widthAnchor.constraint(equalToConstant: 380).isActive = true

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        let buttonRow = NSStackView(views: [cancelButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        window.contentView = container
    }

    func show(version: String) {
        titleLabel.stringValue = "正在下载 MacKZ \(version)"
        detailLabel.stringValue = "准备中…"
        window.level = macKZTopWindowLevel
        macKZActivateSelf()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// fraction < 0 表示不确定进度（连接中 / 重试中）
    func update(fraction: Double, detail: String) {
        if fraction < 0 {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
        } else {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            bar.doubleValue = fraction
        }
        detailLabel.stringValue = detail
    }

    func close() {
        bar.stopAnimation(nil)
        window.orderOut(nil)
    }

    @objc private func cancelTapped() {
        onCancel?()
        close()
    }
}
