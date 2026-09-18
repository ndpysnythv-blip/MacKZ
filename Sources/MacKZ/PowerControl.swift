import AppKit
import Foundation

/// 合盖休眠控制。
///
/// 背景：MacBook 合上盖子默认会立刻休眠；休眠后开盖需要重新输入密码解锁，
/// 而插件叠加的折叠动画位于锁屏之下，用户根本看不到，等于动画白做。
///
/// 解决办法：`pmset -a disablesleep 1` 让系统忽略「合盖」这个休眠触发条件，
/// 合盖后机器继续运行（显示器仍会关闭，也不会因为休眠而要求解锁），
/// 开盖时插件就能正常把折叠动画播出来。
///
/// 注意事项：
/// - 该设置是系统级且持久化的，需要管理员授权（首次会弹出系统密码框）；
/// - 合盖后机器仍在运行且不散热，放进包里可能过热/耗电，不用时请点「恢复系统默认」；
/// - 若开盖仍要求输入密码，那是「锁定屏幕」策略，需要在系统设置里把
///   「关闭显示器后需要密码」改为「永不」（本类只提供直达该设置面板的入口）。
enum PowerControl {

    /// 设置失败的原因（含用户取消授权）
    enum PowerError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            if case .failed(let message) = self { return message }
            return nil
        }
    }

    /// 当前系统是否已开启「合盖不休眠」
    static var isSleepDisabled: Bool {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return false }
        // pmset -g 的输出里，开启后会出现一行 SleepDisabled ... 1；不出现即表示未开启
        for line in output.split(separator: "\n") where line.contains("SleepDisabled") {
            return line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last == "1"
        }
        return false
    }

    /// 设置「合盖不休眠」（会弹出系统管理员授权框）
    static func setSleepDisabled(_ disabled: Bool, completion: @escaping (Result<Void, PowerError>) -> Void) {
        // do shell script ... with administrator privileges 会弹出标准系统密码框
        let script = "do shell script \"/usr/bin/pmset -a disablesleep \(disabled ? 1 : 0)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.terminationHandler = { finished in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                if finished.terminationStatus == 0 {
                    completion(.success(()))
                } else {
                    // 用户点「取消」同样会走到这里（osascript 返回 -128）
                    let reason = message.isEmpty ? "命令执行失败（代码 \(finished.terminationStatus)）" : message
                    completion(.failure(.failed(reason)))
                }
            }
        }
        do {
            try process.run()
        } catch {
            DispatchQueue.main.async { completion(.failure(.failed(error.localizedDescription))) }
        }
    }

    /// 打开「系统设置 → 锁定屏幕」：这里的「关闭显示器后需要密码」决定开盖是否弹锁屏
    static func openLockScreenSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.security?General"
        ]
        for text in candidates {
            if let url = URL(string: text), NSWorkspace.shared.open(url) { return }
        }
    }

    /// 同步执行一个命令并取回标准输出
    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
