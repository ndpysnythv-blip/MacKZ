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

    // MARK: 角度标定（不同机型/摆放姿态有差异，用菜单栏“标定”写入）
    /// 完全合屏时的角度
    var closedAngle = 0.0
    /// 完全打开时的角度
    var openAngle = 130.0
    /// 传感器方向反转（若打开时角度反而变小，置 true）
    var invertAngle = false
    /// 补完动画后，进度回到该值以内才允许再次触发同向序列（端点防抖）
    var rearmProgress = 0.8

    // MARK: 采样
    /// 采样频率（Hz）
    var sampleHz = 30.0
    /// 指数平滑系数 0~1，0 表示不平滑
    var smoothing = 0.35

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
    /// 完全合上时的最大折痕角（度），内部钳制在 80° 内避免几何退化
    var foldAngleDeg = 96.0
    /// 铰链位置：距屏幕**顶边**的比例。默认 0.62 → 上方是「上屏」，下方是「键盘侧下屏」
    var hingeLineRatio = 0.62
    /// 渐进玻璃模糊强度 0~1
    var blurStrength = 0.55
    /// 边缘/折痕色散强度 0~1
    var dispersion = 0.35
    /// 视距（以屏高为单位，越小透视越强）
    var eyeDistance = 2.2
    /// 是否显示进度角标
    var showBadge = true

    // MARK: 传感器匹配（不同机型可能不同，用“传感器探针”确认）
    /// HID 传感器用途页，0x0020 = Sensors
    var usagePage = 0x0020
    /// HID 用途，0 = 不限定
    var usage = 0
    /// HID 事件类型，1 = VendorDefined
    var eventType = 1
    /// 事件字段偏移（字段 = eventType << 16 | eventField），0 为默认
    var eventField = 0
    /// 按产品名筛选传感器（不区分大小写），留空表示自动挑选取值在 0~180 的服务
    var productNameContains = "lid"
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
            let merged = base.merging(user) { _, new in new }
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
