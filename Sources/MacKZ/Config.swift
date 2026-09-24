import Foundation

/// 插件运行配置（JSON 持久化，支持菜单栏热重载）。
/// 所有字段都有默认值：用户配置文件里只写需要覆盖的项即可。
struct Config: Codable {
    // MARK: 启停
    /// 插件总开关
    var enabled = true

    // MARK: 停顿判定与加速
    /// 角度静止超过该时长（毫秒）即判定“用户已停止抬/合屏”
    var stallDurationMs = 350
    /// 角度累积变化阈值（度）：超过即视为一次有效移动，可过滤传感器噪声
    var angleEpsilon = 0.8
    /// 停顿后补完剩余片段的加速倍率（相对 1:1 跟随速度）
    var catchUpSpeed = 3.0
    /// 一次完整 0→1 片段的基准时长（秒），1:1 跟随与加速补完都以它为时间基准
    var clipDuration = 0.6
    /// 加速补完的最短时长（毫秒）：避免剩余片段太短时“秒切”导致观感突兀
    var minCatchUpMs = 120
    /// 同向重触发阈值：进度离开端点超过该值，才允许再次触发同向序列（端点防抖）
    var rearmProgress = 0.05

    // MARK: 角度标定（与 DuoHinge 一致的单参数触发模型）
    /// 触发角（度）：铰链角度 ≥ 该值 → 进度 0（完全展开，不显示动画）
    /// v1.11.0 起改名为「动画起点角」，默认 130°（= 完全打开）→ 特效全程跟随开合角（对齐 iPhone Duo / Mac Duo）
    var triggerAngleDeg = 130.0
    /// 是否已把动画起点角纠正为「全程跟随」（v1.11.0 一次性迁移标记）
    var followAngleMigrated = false
    /// 完全合上角（度）：铰链角度 ≤ 该值 → 进度 1（玻璃完全立起）
    var closeAngleDeg = 0.0
    /// 传感器方向反转（若打开屏幕时角度反而变小，置 true）
    var invertAngle = false

    // MARK: 采样
    /// 采样频率（Hz）：低频用于兜底轮询，真实刷新依赖传感器上报回调
    var sampleHz = 60.0
    /// 指数平滑系数 0~1，0 表示不平滑
    var smoothing = 0.45

    // MARK: 覆盖渲染层
    /// 窗口层级，默认 999（高于菜单栏、状态栏、Dock，可覆盖其它 App 全屏）
    var overlayLevel = 999
    /// 覆盖层最大不透明度
    var overlayAlpha = 1.0
    /// 是否禁止被屏幕录制/共享捕获
    var excludedFromCapture = false
    /// 是否用实时屏幕画面做折叠重投影（需「屏幕录制」权限）
    var captureScreen = true
    /// 采集帧率（跟随屏幕刷新的上限）
    var captureFPS = 60
    /// 是否在完全打开/完全合上时停掉采集省电（false = 常驻采集，响应更快）
    var captureIdleStop = true
    /// 渲染分辨率比例 0.5~1（越低越省电，模糊会掩盖分辨率损失）
    var renderScale = 0.75
    /// 视觉效果预设：clear（轻模糊）/ frosted（磨砂玻璃，默认）/ cinematic（深模糊 + 棱镜色散）
    var visualStyle = "frosted"
    /// 视点：desk（坐桌前俯看，默认）/ front（支架抬升后平视）
    var viewpoint = "desk"
    /// 玻璃完全立起时的角度（度）。90 = 与参考实现完全一致；调小可让完全折上时仍保留画面（末端不会整屏归黑）
    var foldAngleDeg = 90.0
    /// 折叠方向：up = 参考实现（DuoHinge）方向，铰链在屏幕底边、内容折向键盘侧收走（默认）；
    /// down = 铰链在屏幕顶边、内容往屏幕上方抽走（反方向）
    var foldDirection = "up"
    /// 折叠方向是否已纠正为参考实现方向（v1.10.1 一次性迁移标记，用户不必了解）
    var foldDirectionMigrated = false
    /// 折叠动画样式：hinge = 玻璃透视折叠（DuoHinge 方向）；corner = iPhone Duo 同款膨胀（锚点在左下角）
    var foldStyle = "hinge"
    /// 是否显示进度角标
    var showBadge = true
    /// 手机遥控（演示用）：在局域网内开一个极简 HTTP 服务，手机浏览器可控制动画
    var remoteControl = true
    /// 手机遥控端口
    var remoteControlPort = 52800
    /// 是否允许手机陀螺仪接管铰链角度（手机贴在屏幕上模拟铰链，适合没有 Lid Angle Sensor 的机型）。
    /// 注意：手机遥控服务固定用纯 HTTP，而 iOS 只允许 https 页面读取运动传感器，
    /// 所以手机上实际取不到陀螺仪数据；这个开关只决定 Mac 是否接受手机上报的角度。
    var phoneGyro = true
    /// 启动后自动检查更新（发现新版本才提示，平时完全静默）
    var autoCheckUpdate = true

    // MARK: 视觉预设派生参数（数值 1:1 对应 DuoHinge 的 HingeStyle 预设）
    /// 玻璃散射模糊强度
    var styleBlur: Double {
        switch visualStyle {
        case "clear": return 0.25
        case "cinematic": return 1.3
        default: return 1.0            // frosted
        }
    }
    /// 幕布压暗强度
    var styleDarkness: Double {
        switch visualStyle {
        case "clear": return 0.2
        case "cinematic": return 1.2
        default: return 1.0            // frosted
        }
    }
    /// 径向色散强度（仅 cinematic 开启）
    var styleDispersion: Double {
        return visualStyle == "cinematic" ? 1.0 : 0.0
    }
}

/// 配置读写：默认值 + 用户配置合并（这样新增字段不会让老配置文件解析失败）。
enum ConfigStore {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacKZ", isDirectory: true)
    }

    static var defaultURL: URL { directory.appendingPathComponent("config.json") }

    /// 读取配置，失败时回退默认值并打印日志
    static func load(from url: URL = defaultURL) -> Config {
        let defaults = Config()
        guard FileManager.default.fileExists(atPath: url.path) else { return defaults }
        do {
            let userData = try Data(contentsOf: url)
            let user = (try JSONSerialization.jsonObject(with: userData)) as? [String: Any] ?? [:]
            let baseData = try JSONEncoder().encode(defaults)
            let base = (try JSONSerialization.jsonObject(with: baseData)) as? [String: Any] ?? [:]
            // 用户值覆盖默认值，再整体解码，保证缺字段时依然可用
            var merged = base.merging(user) { _, new in new }
            // v1.10.1 修正：此前的默认折叠方向与参考实现（DuoHinge）相反，
            // 升上来的老配置里存的仍是那个旧默认值，这里纠正一次；
            // 用户之后再手动改方向不会被反复覆盖（标记已落盘）。
            if (merged["foldDirectionMigrated"] as? Bool) != true {
                merged["foldDirection"] = Config().foldDirection
                merged["foldDirectionMigrated"] = true
            }
            // v1.11.0：特效改为「全程跟随开合角」（对齐 iPhone Duo / Mac Duo 的观感）。
            // 旧默认值是 90°（合到 90° 以下才插手），升上来时纠正一次；
            // 用户手动改过的其它值（不等于 90）保持不动。
            if (merged["followAngleMigrated"] as? Bool) != true {
                if (merged["triggerAngleDeg"] as? Double) == 90 {
                    merged["triggerAngleDeg"] = Config().triggerAngleDeg
                }
                merged["followAngleMigrated"] = true
            }
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            return try JSONDecoder().decode(Config.self, from: mergedData)
        } catch {
            NSLog("[MacKZ] 配置解析失败，已回退默认配置：%@", String(describing: error))
            return defaults
        }
    }

    /// 写回配置（首次运行会生成一份带默认值的文件，便于用户修改）
    static func save(_ config: Config, to url: URL = defaultURL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            NSLog("[MacKZ] 配置写入失败：%@", String(describing: error))
        }
    }

    /// 确保配置文件存在
    static func ensureExists() {
        guard !FileManager.default.fileExists(atPath: defaultURL.path) else { return }
        save(Config())
    }
}
