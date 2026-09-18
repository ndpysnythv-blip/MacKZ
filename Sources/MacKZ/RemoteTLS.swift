import Foundation
import Network
import Security

/// 手机遥控服务的本地 TLS 支持。
///
/// 为什么需要 HTTPS：iOS 13+ / 现代浏览器都要求「安全上下文」（https 或 localhost）
/// 才允许网页读取运动传感器（DeviceMotion），用 http://192.168.x.x 打开的手机页面
/// 拿不到任何陀螺仪数据。所以手机遥控服务优先以 HTTPS 起监听。
///
/// 做法：用 macOS 自带的 /usr/bin/openssl 生成一张自签证书（SAN 里带上当前局域网 IP，
/// Safari 要求 SAN 与访问地址匹配才允许「继续访问」），打包成 PKCS#12 后用
/// SecPKCS12Import 取出 SecIdentity 交给 Network.framework。
///
/// 取舍：不引入任何第三方依赖；证书只在本机生成、只服务局域网；私钥用完即删，
/// 只保留 p12（目录权限 0700）。
enum RemoteTLS {

    /// 证书存放目录：~/Library/Application Support/MacKZ/tls
    static var directory: URL { ConfigStore.directory.appendingPathComponent("tls", isDirectory: true) }

    private static var p12URL: URL { directory.appendingPathComponent("identity.p12") }
    private static var hostStampURL: URL { directory.appendingPathComponent("host.txt") }
    /// p12 的导出密码（本地自用，不对外分发，写在代码里即可）
    private static let passphrase = "mackz-local"

    /// 取得可用于 NWListener 的 TLS 身份；失败返回 nil，调用方回退到 HTTP。
    /// - Parameter host: 手机访问用的局域网 IP，会写进证书 SAN；IP 变了会自动重新签一张。
    static func identity(for host: String) -> sec_identity_t? {
        guard !host.isEmpty else { return nil }

        let cachedHost = (try? String(contentsOf: hostStampURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedHost != host || !FileManager.default.fileExists(atPath: p12URL.path) {
            guard generateCertificate(for: host) else { return nil }
        }
        return loadIdentity()
    }

    // MARK: - 生成自签证书

    /// 生成自签证书并导出 p12，成功返回 true
    private static func generateCertificate(for host: String) -> Bool {
        let fm = FileManager.default
        // 0700：证书目录仅当前用户可读写
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])

        let keyURL = directory.appendingPathComponent("key.pem")
        let certURL = directory.appendingPathComponent("cert.pem")
        let cnfURL = directory.appendingPathComponent("openssl.cnf")

        // 纯数字/点 视为 IP，其余按域名写进 SAN
        let isIP = host.range(of: #"^[0-9]+(\.[0-9]+){3}$"#, options: .regularExpression) != nil
        let san = isIP ? "IP:\(host),DNS:mackz.local" : "DNS:\(host),DNS:mackz.local"
        let cnf = """
        [req]
        distinguished_name = dn
        x509_extensions  = v3
        prompt           = no
        [dn]
        CN = MacKZ
        [v3]
        basicConstraints = critical,CA:TRUE
        subjectAltName   = \(san)
        """
        guard (try? cnf.write(to: cnfURL, atomically: true, encoding: .utf8)) != nil else { return false }
        defer {
            // 私钥/中间文件用完即删，只留 p12
            try? fm.removeItem(at: keyURL)
            try? fm.removeItem(at: certURL)
            try? fm.removeItem(at: cnfURL)
        }

        // 1) 自签证书（RSA 2048，十年有效）
        guard runOpenSSL(["req", "-x509", "-newkey", "rsa:2048", "-sha256", "-nodes",
                          "-days", "3650", "-keyout", keyURL.path, "-out", certURL.path,
                          "-config", cnfURL.path]) else {
            NSLog("[MacKZ] 生成自签证书失败，手机遥控将回退到 HTTP")
            return false
        }

        // 2) 导出 PKCS#12：Security 框架只认 p12。
        //    先试 -legacy（传统加密，兼容性最好），老版本 openssl 不认该参数时再去掉重试。
        let common = ["pkcs12", "-export", "-out", p12URL.path, "-inkey", keyURL.path,
                      "-in", certURL.path, "-passout", "pass:\(passphrase)", "-name", "MacKZ"]
        if runOpenSSL(common + ["-legacy"]) || runOpenSSL(common) {
            guard (try? host.write(to: hostStampURL, atomically: true, encoding: .utf8)) != nil else { return false }
            NSLog("[MacKZ] 已生成本地 HTTPS 自签证书（SAN: %@）", san)
            return true
        }
        NSLog("[MacKZ] 导出 PKCS#12 失败，手机遥控将回退到 HTTP")
        return false
    }

    // MARK: - 载入身份

    /// 从 p12 取出 SecIdentity，并包装成 Network.framework 用的 sec_identity_t
    private static func loadIdentity() -> sec_identity_t? {
        guard let data = try? Data(contentsOf: p12URL) else { return nil }
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: passphrase] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)
        guard status == errSecSuccess,
              let list = items as? [[String: Any]],
              let entry = list.first?[kSecImportItemIdentity as String] else {
            NSLog("[MacKZ] 自签证书导入失败（OSStatus %d），手机遥控将回退到 HTTP", status)
            return nil
        }
        // 注意：这里必须用强制转换。SecIdentity 是 CoreFoundation 类型，
        // 写成 as? 会被编译器判为「条件转换永远成功」而直接编译失败。
        let identity = entry as! SecIdentity
        return sec_identity_create(identity)
    }

    // MARK: - 工具

    /// 执行 openssl 子命令，成功返回 true（输出全部丢弃，避免污染日志）
    private static func runOpenSSL(_ arguments: [String]) -> Bool {
        let executable = "/usr/bin/openssl"
        guard FileManager.default.isExecutableFile(atPath: executable) else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return false
        }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
