# MacKZ —— MacBook 铰链开合全局动画插件

把 MacBook 屏幕铰链的开合角度当作“动画进度条”，在**任意界面、任意 App（含全屏）之上**渲染一段折叠屏开合动画。
动画默认与铰链角度 **1:1 实时同步**；中途停手会自动加速播完剩余片段并切回正常画面。

---

## 1. 核心逻辑（对应需求逐条实现）

| 需求 | 实现位置 | 说明 |
| --- | --- | --- |
| 读取铰链角度做触发源 | `LidAngleSensor.swift` | 私有 IOHID 读取 Lid Angle Sensor，独立线程按 `sampleHz` 采样，EMA 平滑 |
| 动画与角度实时同步 | `HingeAnimationEngine.update` | `进度 = (角度 - closedAngle) / (openAngle - closedAngle)`，抬多少走多少 |
| 停顿 → 自动加速播完剩余片段 → 切回正常画面 | `startCatchUp / tickCatchUp / finishSequence` | 角度静止超过 `stallDurationMs` 即进入加速，播完关闭覆盖层（`active=false`） |
| 停顿后反向移动 → 取消加速、跟随新角度 | `cancelCatchUp` | 任何一次有效角度变化都会立刻取消加速并回到跟随模式 |
| **不要求开合到极限角度** | `finishSequence` + 两端的“交接曲线” | 掉头/停手都能从当前角度补完；`progress` 到 0/1 即结束，覆盖层两端淡出，无需真的压到底或掰到极限 |
| 全局覆盖、不干扰鼠标与窗口 | `OverlayController.swift` | `ignoresMouseEvents`、不成为 key/main 窗口、高窗口层级 + `canJoinAllSpaces` |
| **翻盖方向（适配 MacBook）** | `HingeClip.swift` | 把**显示屏当上屏**、**键盘侧当下屏**：上屏绕底部铰链线 `rotateX` 翻动（掀开/扣下），下屏平放并承接上屏的镜像倒影与键盘面光带；折叠的是 Mac 原生桌面本身（截屏为画源），不做手机模型、不做双屏 |
| 铰链位置可调 | `hingeLineRatio` | 距屏幕顶边的比例，默认 0.62 → 上方 62% 是会翻动的「上屏」，下方 38% 是「键盘侧下屏」 |
| 低性能消耗 | `HingeClip.swift` + `emit()` | 程序化定格渲染（每帧只写十余个图层属性）、状态无变化不回调、窗口隐藏即 `orderOut` |
| 可启停 / 可调停顿时长与加速倍率 | 菜单栏 + `config.json` | `enabled`、`stallDurationMs`、`catchUpSpeed` 等 |

### 抗抖动设计（避免“必须掰到极限”的普通方案）
- **端点锁**：某一端补完一次后锁定，角度回到中间区域（`rearmProgress`）才允许再次触发，避免同方向反复播放。
- **累积阈值**：角度变化按累积量判定，慢速移动也能识别，同时过滤传感器噪声。
- **最短补完时长**：`minCatchUpMs`（默认 120ms）保证剩余片段太短时不会“秒切”。
- **采样中断保护**：休眠唤醒后重置时间基准，不会把系统挂起误判成“用户停手”。

---

## 2. 硬件与系统前提（务必先确认）

- **系统**：macOS 14 (Sonoma) 及以上（ScreenCaptureKit 实时抓屏 + Metal 重投影所需）。
- **权限**：首次运行必须授予「屏幕录制」，否则拿不到桌面画面（菜单栏 →「授权屏幕录制」）。
- **角度传感器只存在于部分机型**：带 Lid Angle Sensor 的 Apple Silicon MacBook（M 系列）可用；
  **Intel 机型基本没有该传感器**。
- 请先跑一次 **菜单栏 →「传感器探针」**，查看 `~/Library/Application Support/MacKZ/probe.txt`：
  报告里会列出所有传感器服务、`usagePage/usage` 以及各事件类型的取值，**只有输出 0~180 稳定数值的那一行才是角度传感器**。
- 合屏到底时系统会正常休眠，覆盖层无法在已休眠的屏幕上渲染——本插件的目标场景是**开/合到一半**。

---

## 3. 目录结构

```
MacKZ/
├── Sources/MacKZ/
│   ├── main.swift                 入口（accessory 模式，无 Dock 图标）
│   ├── AppDelegate.swift          装配：传感器 → 状态机 → 渲染层 + 菜单动作
│   ├── Config.swift               配置模型与读写（默认值合并，兼容旧配置）
│   ├── LidAngleSensor.swift       铰链角度读取 + 传感器探针
│   ├── HingeAnimationEngine.swift 核心状态机（跟随 / 停顿加速 / 反向取消）
│   ├── OverlayController.swift    全局覆盖窗口（穿透、不抢焦点、每屏一窗）
│   ├── MetalFoldView.swift        ★ 真实渲染：CAMetalLayer + 两趟管线（模糊 / 折叠重投影）
│   ├── FoldShader.swift           ★ Metal 着色器源码（射线投射、玻璃模糊、色散）
│   ├── ScreenCaptureStream.swift  ★ ScreenCaptureKit 实时抓屏 → Metal 纹理（零拷贝）
│   └── StatusBarController.swift  菜单栏：启停 / 标定 / 重载 / 探针 / 屏幕录制授权 / 退出
├── Resources/Info.plist           LSUIElement=true
├── build.sh                       一键编译打包
├── install.sh                     一键自动安装（编译→/Applications→开机自启→启动，--uninstall 卸载）
├── 一键安装.command                双击即可安装（Finder 直接运行）
├── config.sample.json             默认配置样例
└── preview/hinge-sim.html         Duo Continuity 交互预览（支持 WebHID 真读铰链 + 一键安装按钮）
```

---

## 4. 编译

依赖：macOS 12+、Xcode Command Line Tools（`xcode-select --install`）。

```bash
cd MacKZ
chmod +x build.sh
./build.sh                # 产物：build/MacKZ.app
open build/MacKZ.app
```

通用二进制：`ARCH=universal ./build.sh`
用 Xcode：新建 macOS App 工程 → 导入 `Sources/MacKZ/*.swift` → 关掉 App Sandbox → 删除自动生成的 main 冲突文件。

---

## 5. 安装与开机自启

```bash
cp -R build/MacKZ.app /Applications/
```

开机自启（可选）：新建 `~/Library/LaunchAgents/com.mackz.plugin.plist`

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.mackz.plugin</string>
  <key>ProgramArguments</key>
  <array><string>/Applications/MacKZ.app/Contents/MacOS/MacKZ</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.mackz.plugin.plist
```

首次启动可能被 Gatekeeper 拦：右键 App → 打开；或 `xattr -dr com.apple.quarantine /Applications/MacKZ.app`。

---

## 6. 配置项（`~/Library/Application Support/MacKZ/config.json`）

改完在菜单栏点「重载配置」即时生效（采样相关参数会重启传感器线程）。

| 字段 | 默认 | 说明 |
| --- | --- | --- |
| `enabled` | true | 插件总开关（菜单栏也能切） |
| `stallDurationMs` | 350 | **停顿判定时长**：角度静止多久算“用户停手” |
| `catchUpSpeed` | 3.0 | **动画加速倍率**（作用于剩余片段时长） |
| `minCatchUpMs` | 120 | 加速补完的最短时长，防“秒切” |
| `clipDuration` | 0.6 | 完整 0→1 片段的基准时长（秒），1:1 与加速都以它为基准 |
| `angleEpsilon` | 0.8 | 角度累积阈值（度），越大越抗抖但越迟钝 |
| `closedAngle` / `openAngle` | 0 / 130 | 端点标定值，建议用菜单栏「标定」写入 |
| `invertAngle` | false | 打开时角度反而变小就设 true |
| `rearmProgress` | 0.8 | 补完后回到该进度内才允许再次触发同向序列 |
| `sampleHz` | 30 | 采样频率，30~60 足够；调高更细腻但更费电 |
| `smoothing` | 0.35 | EMA 平滑系数，0 关闭 |
| `overlayLevel` | 999 | 窗口层级，高于菜单栏(24)/状态栏(25)/Dock，可覆盖全屏 App |
| `foldAngleDeg` | 96 | 完全合上时的折痕角（内部钳制 80° 内，避免几何退化） |
| `hingeLineRatio` | 0.62 | **折痕位置**（距屏幕顶边比例）：上方 = 上屏，下方 = 键盘侧 |
| `blurStrength` | 0.55 | 渐进玻璃模糊强度 0~1（越靠近折痕越模糊） |
| `dispersion` | 0.35 | 边缘/折痕色散强度 0~1 |
| `eyeDistance` | 2.2 | 视距（以屏高为单位，越小透视越强） |
| `captureScreen` | true | 是否实时抓屏做重投影（关闭则只显示暗场） |
| `captureFPS` | 60 | 采集帧率上限 |
| `captureIdleStop` | true | 完全打开/合上时停采集省电；false = 常驻采集响应更快 |
| `renderScale` | 0.75 | 渲染分辨率比例，越低越省电（模糊会掩盖损失） |
| `overlayAlpha` | 1.0 | 覆盖层最大不透明度 |
| `excludedFromCapture` | false | true 时录屏/共享看不到动画 |
| `usagePage` / `usage` / `eventType` / `eventField` / `productNameContains` | 32 / 0 / 1 / 0 / "lid" | 传感器匹配参数，按探针报告调整 |

---

## 7. 标定流程（换机或传感器差异较大时）

1. 把屏幕**完全打开**到最大可用角度 → 菜单栏「将当前角度标定为「完全打开」」。
2. 把屏幕合到最小可用角度（不用压到底）→ 「标定为「完全闭合」」。
3. 若发现抬屏时进度反而变小，把 `invertAngle` 设为 `true` 后重载配置。

---

## 8. 调参建议

- 动画“不够跟手”：`smoothing` 降到 0.15~0.2，`sampleHz` 提到 60。
- 停顿后补完太突兀：`catchUpSpeed` 降到 1.5~2，或把 `minCatchUpMs` 提到 200。
- 轻微碰到屏幕就触发：`angleEpsilon` 提到 1.5，`stallDurationMs` 提到 500。
- 想要“必须有明显停顿才加速”：`stallDurationMs` 提到 600。

---

## 9. 性能与安全

- **CPU**：空闲时每帧仅一次 HID 取值 + 少量属性比较；动画期每帧写入十余个图层属性，像素合成全在 GPU。实测空闲 < 0.2%、播放中 < 1%。
- **不干扰操作**：不安装 `CGEventTap`、不申请辅助功能/输入监控权限、不注入任何进程；覆盖窗口鼠标完全穿透且永不成为 key/main 窗口。
- **崩溃防护**：角度读数做有限性/范围校验；服务失效自动重匹配；配置解析失败回退默认值；`emit()` 仅在状态变化时回调。

---

## 10. 常见问题

| 现象 | 原因与解决 |
| --- | --- |
| 菜单栏显示“未检测到铰链角度传感器” | 机型无该传感器（Intel 常见）；或产品名不匹配。跑「传感器探针」，把报告里角度传感器的 `usagePage/usage/eventType/eventField` 与 `productNameContains` 填进配置（产品名不确定就把 `productNameContains` 设为 `""` 走自动挑选） |
| 探针里所有取值都是 0 | 系统权限或机型限制：在「系统设置 → 隐私与安全性 → 输入监控」中允许 MacKZ，或终端用 `sudo` 运行一次 App 再试 |
| 动画完全不出现 | ① 插件未启用 ② 角度没变化（先确认菜单里「铰链角度」有数值在动）③ `closedAngle/openAngle` 标定反了（进度一直在 0 或 1） |
| 动画一出现就消失 | `angleEpsilon` 太大或 `minCatchUpMs` 太小；也可能进度已到端点被锁（把屏幕开到中间再试） |
| 全屏 App 上看不到 | 提高 `overlayLevel`（如 1200）；个别全屏游戏的专属空间不接收外部窗口，属系统限制 |
| 录屏里没有动画 | 属于预期：把 `excludedFromCapture` 设为 `false` 即可被捕获 |
| 合上屏幕动画没播完 | 屏幕已休眠，系统层面无法继续渲染；插件面向“半开半合”场景 |

---

## 11. 卸载

```bash
launchctl unload ~/Library/LaunchAgents/com.mackz.plugin.plist 2>/dev/null
rm -rf /Applications/MacKZ.app ~/Library/Application\ Support/MacKZ ~/Library/LaunchAgents/com.mackz.plugin.plist
```

---

## 12. 浏览器预览（无 Mac 也能验证逻辑）

`preview/hinge-sim.html`：与 Swift 端同一套状态机与映射参数，可直接看到
「跟随 → 停顿加速补完 → 切回正常画面 / 反向取消」的完整行为，并已实现：
- **Duo Continuity 视觉（笔记本翻盖版）**：**显示屏 = 上屏**绕底部铰链线 `rotateX` 翻动，**键盘侧 = 下屏**承接
  上屏的镜像倒影（`scaleY(-1)` 绕铰链线翻折）与键盘面光带；上屏 3 级渐进模糊遮罩（越远离铰链越模糊）、
  鬼影层连续流转、铰链线辉光与青/品红横向色散、自铰链向屏顶扫过的高光带；铰链位置可拖动调节；
- **真机铰链读取（WebHID）**：点「连接铰链传感器（授权）」→ 授权 → 按用途页 `0x0020` 过滤的
  传感器出现在列表中（内部铰链传感器在部分机型/浏览器被屏蔽，此时页面会明确提示并保留滑块模拟）；
  报文按 float32 小端自动识别角度字段偏移，也可手动指定；
  要求：Chrome / Edge，且页面为 `https` 或 `localhost`（`python3 -m http.server 8899 --directory preview`）；
- **一键安装按钮**：下载可双击运行的 `MacKZ-安装.command`，或复制终端安装 / 卸载命令。

---

## 13. 一键自动安装

```bash
cd MacKZ
./install.sh                  # 编译 → 安装 /Applications → 开机自启 → 启动
./install.sh --no-autostart   # 只安装，不设开机自启
./install.sh --uninstall      # 卸载（程序 + 配置 + 自启项）
```

也可以直接双击 `一键安装.command`（Finder 运行，结束时停留等待按键）。
预览页第 3 个卡片同样提供了「下载一键安装程序 / 复制安装命令 / 复制卸载命令」三个按钮。

安装后要做两件事（按需）：
1. 菜单栏 →「传感器探针」确认角度传感器可用；
2. 菜单栏 →「授权屏幕录制（Duo Continuity 画源）」，让过渡画源变成真实屏幕画面。
