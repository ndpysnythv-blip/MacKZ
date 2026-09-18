import AppKit

/// 更新检查与自更新。
/// 数据源：GitHub Releases API（公开仓库，无需 token）。
/// 自更新流程（非 App Store 应用的标准做法，与 Sparkle 思路一致）：
///   下载 zip → 落盘到 Application Support → 生成替换脚本 → 退出自身 → 脚本解压覆盖 → 重新启动。
enum UpdateChecker {

    /// 仓库标识（owner/repo），发布新版本只需推送 v* 标签，CI 会自动构建 Release
    static let repository = "ndpysnythv-blip/MacKZ"

    /// 一个可用的新版本
    struct Release {
        let version: String      // 规范化版本号，如 "1.1.0"
        let notes: String        // Release 说明
        let zipURL: URL          // MacKZ.zip 直链
        let pageURL: URL         // Release 页面
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case noAsset
        case network(String)
        case cannotWrite(String)

        var errorDescription: String? {
            switch self {
            case .badResponse:          return "服务器返回异常，请稍后再试。"
            case .noAsset:              return "该版本没有可下载的安装包。"
            case .network(let message): return "网络请求失败：\(message)"
            case .cannotWrite(let path):return "没有写入权限：\(path)"
            }
        }
    }

    // MARK: - 版本信息

    /// 当前 App 版本（读取 Info.plist 的 CFBundleShortVersionString）
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// 版本号规范化："v1.1.0" -> [1, 1, 0]，非法片段按 0 处理
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
            completion(.failure(.badResponse))
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            // 统一回到主线程回调，避免调用方各自 dispatch
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
                finish(.failure(.badResponse))
                return
            }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            let zipURL = (zipAsset?["browser_download_url"] as? String).flatMap(URL.init(string:))
            let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/\(repository)/releases")!

            // 版本没变或更旧 → 视为已是最新
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

    /// 下载新版本并安排替换重启；成功后调用方应主动退出 App
    static func downloadAndInstall(_ release: Release,
                                   completion: @escaping (Result<Void, UpdateError>) -> Void) {
        // 直接跑二进制（非 .app）时无法自替换，退回让用户手动下载
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

        URLSession.shared.downloadTask(with: release.zipURL) { tempURL, _, error in
            let finish: (Result<Void, UpdateError>) -> Void = { result in
                DispatchQueue.main.async { completion(result) }
            }
            if let error {
                finish(.failure(.network(error.localizedDescription)))
                return
            }
            guard let tempURL else {
                finish(.failure(.badResponse))
                return
            }
            let zipPath = updateDir.appendingPathComponent("MacKZ.zip")
            do {
                try? FileManager.default.removeItem(at: zipPath)
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
                let scriptPath = try makeInstallScript(updateDir: updateDir, zipPath: zipPath, targetApp: bundlePath)
                launchDetached(scriptPath)
                finish(.success(()))
            } catch {
                finish(.failure(.cannotWrite(error.localizedDescription)))
            }
        }.resume()
    }

    /// 生成替换脚本：等主进程退出 → 解压 → 覆盖原 .app → 重新启动
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
