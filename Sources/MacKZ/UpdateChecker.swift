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

    /// 产品官网（介绍页）：插件内所有「官网」入口统一指向这里
    static let homepageURL = URL(string: "https://kdxzhx.top/mackz")!

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
        case badAsset
        case network(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "服务器返回异常（HTTP \(code)）"
            case .noAsset:               return "该版本没有可下载的安装包"
            case .badAsset:              return "下载到的不是有效安装包（加速节点返回了错误页），请重试或改用终端安装"
            case .network(let message):  return "网络错误：\(message)"
            case .cannotWrite(let path): return "没有写入权限：\(path)"
            }
        }
    }

    /// 终端一键安装命令（下载失败时给用户兜底）
    /// 指向 install-raw.sh：它优先整包下载并带假死检测与多镜像回退，比 git 拉源码更适应受限网络
    static let terminalInstallCommand =
        "curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-raw.sh | bash"

    // MARK: - 下载源（GitHub 直连 + 加速镜像）

    /// 国内常用的 GitHub 加速前缀（均已实测可正常拉取 Release 资源）。
    /// 它们只是把同一个 release 直链反代一层，文件内容完全一致，
    /// 用来解决「直连 GitHub 超时（网络错误 -1001）」——只影响下载，不影响检查更新。
    /// 注意：这类公共服务会失效，所以是「整串依次尝试」而不是只用一个。
    private static let acceleratorPrefixes = [
        "https://ghfast.top/",
        "https://gh-proxy.com/",
        "https://ghproxy.net/",
        "https://gh.xxooo.cf/",
        "https://gitproxy.click/",
    ]

    /// 组装候选下载源：第 0 个始终是 GitHub 直链（网络好时最快），后面依次是各加速节点
    static func downloadCandidates(for url: URL) -> [URL] {
        guard let host = url.host, host.contains("github") else { return [url] }
        var list = [url]
        for prefix in acceleratorPrefixes {
            guard let mirrored = URL(string: prefix + url.absoluteString), !list.contains(mirrored) else { continue }
            list.append(mirrored)
        }
        return list
    }

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

        let downloader = UpdateDownloader(release: release,
                                          candidates: downloadCandidates(for: release.zipURL),
                                          destination: zipPath, progress: progress) { result in
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

    /// 把所有候选源走完算一轮，最多两轮
    private static let maxRounds = 2

    private let release: UpdateChecker.Release
    /// 候选下载源：GitHub 直链 + 各加速镜像（内容一致，哪个通用哪个）
    private let candidates: [URL]
    private let destination: URL
    private let progress: (Double, String) -> Void
    private let completion: (Result<Void, UpdateChecker.UpdateError>) -> Void

    private var session: URLSession?
    private var index = 0             // 当前候选源下标
    private var round = 1             // 当前轮次
    private var currentLabel = ""     // 当前源的名字（显示在进度文字里，方便确认走的是哪条通道）
    private var finished = false
    private var movedToDestination = false
    private var lastError: UpdateChecker.UpdateError?

    init(release: UpdateChecker.Release, candidates: [URL], destination: URL,
         progress: @escaping (Double, String) -> Void,
         completion: @escaping (Result<Void, UpdateChecker.UpdateError>) -> Void) {
        self.release = release
        self.candidates = candidates.isEmpty ? [release.zipURL] : candidates
        self.destination = destination
        self.progress = progress
        self.completion = completion
    }

    /// 依次尝试候选源（直连 → 各加速节点），全部失败才整体重试一轮
    func start() {
        guard !finished else { return }
        if index >= candidates.count {
            guard round < Self.maxRounds else {
                finish(.failure(lastError ?? .badResponse(-1)))
                return
            }
            round += 1
            index = 0
        }
        let isDirect = index == 0
        let url = candidates[index]
        currentLabel = isDirect ? "GitHub 直连" : (url.host ?? "加速节点")
        index += 1
        movedToDestination = false

        let config = URLSessionConfiguration.default
        // 直连只给 8 秒：GitHub 不可达时连接会一直挂着，早失败早换加速节点
        config.timeoutIntervalForRequest = isDirect ? 8 : 15
        config.timeoutIntervalForResource = 120     // 单个源最长 2 分钟
        config.waitsForConnectivity = false         // 不通就尽快失败并换源，而不是无限等待
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        self.session = session

        let prefix = round > 1 ? "第 \(round) 轮 · " : ""
        let tip = "\(prefix)\(currentLabel) · 正在连接…"
        DispatchQueue.main.async { [weak self] in self?.progress(-1, tip) }
        session.downloadTask(with: url).resume()
    }

    /// 取消下载：不再重试、不再回调
    func cancel() {
        finished = true
        session?.invalidateAndCancel()
        session = nil
    }

    /// 收尾（保证只回调一次）
    private func finish(_ result: Result<Void, UpdateChecker.UpdateError>) {
        guard !finished else { return }
        finished = true
        session?.finishTasksAndInvalidate()
        session = nil
        DispatchQueue.main.async { [weak self] in self?.completion(result) }
    }

    // MARK: 下载进度
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        let text = String(format: "%@ · 已下载 %.0f%%（%.0f KB / %.0f KB）",
                          currentLabel,
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
        // 校验文件头真的是 zip：加速节点偶尔会返回一个 HTML 错误页，
        // 若当成成功交给替换脚本，解压会失败（甚至把已装好的 App 换坏），所以先拦下来换下一个源
        guard Self.looksLikeZip(location) else {
            lastError = .badAsset
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

    /// 文件头是不是 zip 的 "PK"
    private static func looksLikeZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 2) else { return false }
        return magic == Data([0x50, 0x4B])
    }

    // MARK: 任务结束（成功则接着安装，失败则换下一个源继续）
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        guard !finished else { return }

        if movedToDestination {
            finish(.success(()))
            return
        }
        if let error {
            lastError = .network((error as NSError).localizedDescription + "（代码 \((error as NSError).code)）")
        }

        NSLog("[MacKZ] 该下载源失败，换下一个源：%@", lastError?.localizedDescription ?? "未知")
        // 稍等一下再换源：网络刚切换时连续重试容易连着失败
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.start() }
    }
}

// MARK: - 顶层窗口层级

/// 让「需要用户点击」的窗口真正可用。
/// 说明：本应用是 LSUIElement（无 Dock 图标），macOS 14 起无法无条件抢焦点，
/// 所以弹窗一律走 `MacKZDialog`（nonactivatingPanel + 接受首次点击的按钮），
/// 不再依赖「临时切换激活策略」这类副作用较大的做法。
let macKZTopWindowLevel = NSWindow.Level(rawValue: 3000)

// MARK: - 下载进度窗口

/// 更新下载进度浮窗：显示进度条与实时状态，浮在所有窗口之上，可随时取消。
final class UpdateProgressWindow: NSObject {

    /// 用户点击「取消」
    var onCancel: (() -> Void)?

    private let window: NSWindow
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    /// 用 MacKZDialogButton：应用不在前台时第一次点击也要能生效（否则「取消」点不动）
    private let cancelButton = MacKZDialogButton()
    /// 右下角署名：作者 logo + KDXZHX
    private let logoView = NSImageView()
    private let authorLabel = NSTextField(labelWithString: "KDXZHX")

    override init() {
        // nonactivatingPanel：点它不需要先激活 App，鼠标事件直接进面板
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 168),
                         styleMask: [.titled, .nonactivatingPanel],
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

        // 右下角署名：作者 logo + KDXZHX
        logoView.image = StatusBarController.logoMark(pointSize: 15)
        logoView.contentTintColor = .secondaryLabelColor    // 模板图按次要文字色渲染，深浅色外观都清晰
        logoView.imageScaling = .scaleProportionallyUpOrDown
        logoView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoView.widthAnchor.constraint(equalToConstant: 15),
            logoView.heightAnchor.constraint(equalToConstant: 15)
        ])
        authorLabel.font = .systemFont(ofSize: 10, weight: .medium)
        authorLabel.textColor = .tertiaryLabelColor

        // 撑开的占位：把「取消」留在左边，把署名推到右下角
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttonRow = NSStackView(views: [cancelButton, spacer, logoView, authorLabel])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [titleLabel, bar, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        // 底部这行撑满宽度，署名才会贴在右下角（垂直 stack 是 leading 对齐，默认不拉伸子视图）
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

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
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
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
