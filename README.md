# MacKZ —— MacBook 铰链开合全局动画插件

> 作者 **KDXZHX** · 官网页面 <https://kdxzhx.top/mackz.html> · 当前版本 **v1.7.0**

把 MacBook 屏幕铰链的开合角度当作“动画进度条”，在**任意界面、任意 App（含全屏）之上**渲染一段折叠屏开合动画。
动画默认与铰链角度 **1:1 实时同步**；中途停手会自动加速播完剩余片段并切回正常画面。

---

## 快速开始

### 方式一：源码一键安装（最推荐，不需要任何“信任”操作）

```bash
curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-raw.sh | bash
```

本机拉源码 → 本机编译 → 装到「应用程序」→ 设置开机自启。
产物**不带 `com.apple.quarantine` 隔离属性**，双击即可打开，系统设置里也不会出现拦截提示。
需要 Xcode Command Line Tools，脚本会自动检测并引导安装。

脚本内置抗假死策略：优先整包下载源码（1 条连接），失败再逐文件回退，并内置多个镜像；
每个请求都带 `--max-time` 与 `--speed-limit/--speed-time`，网络假死会在 8 秒内被判超时并自动换源，不会像旧脚本那样一直卡住。

### 方式二：下载预编译版（快，但可能被 Gatekeeper 拦）

```bash
curl -fsSL https://raw.githubusercontent.com/ndpysnythv-blip/MacKZ/main/scripts/install-app.sh | bash
```

从 GitHub Release 拉取最新 `MacKZ.zip` 安装。若系统仍然拦下它，执行一次：

```bash
sudo xattr -cr /Applications/MacKZ.app
sudo codesign --force --deep --sign - /Applications/MacKZ.app
open /Applications/MacKZ.app
```

### 方式三：浏览器下载

1. 打开 [Releases](https://github.com/ndpysnythv-blip/MacKZ/releases/latest)，下载 `MacKZ.zip`
2. 解压得到 `MacKZ.app`，拖进「应用程序」
3. 浏览器下载的文件一定带隔离属性，必须执行下面两条（**注意有 `sudo`**）：

```bash
sudo xattr -cr /Applications/MacKZ.app
open /Applications/MacKZ.app
```

### 装好之后

- 首次启动会自动申请「屏幕录制」权限，授权后程序自动重启让权限生效
- 菜单栏出现 **MacKZ logo 图标** → 点「设置…」调参
- 设置面板已按“新手优先”重排：实时状态 → 总开关 → 权限 → 手机遥控 → 常用设置，
  角度标定 / 采集性能等细节收进底部可折叠的「高级设置」
- 更新：菜单栏 →「检查更新…」，发现新版本会自动弹窗，可一键下载替换并重启

### 打不开时的排查顺序

| 现象 | 处理 |
| --- | --- |
| “Apple 无法验证 MacKZ…” | `sudo xattr -cr /Applications/MacKZ.app` 后重新 `open` |
| 系统设置里根本没有“仍要打开” | 隔离属性没清干净，用上面的 `sudo` 命令；必要时补一次 `sudo codesign --force --deep --sign -` |
| 提示“MacKZ 已损坏，请移到废纸篓” | 解压导致签名结构失效，`sudo xattr -cr` + `sudo codesign --force --deep --sign -` 重新签名 |
| 上面都没用 | 改用**方式一**源码安装，本机编译不带隔离属性，必定能开 |

---

## 1. 核心逻辑（对应需求逐条实现）

| 需求 | 实现位置 | 说明 |
| --- | --- | --- |
| 读取铰链角度做触发源 | `LidAngleSensor.swift` | 规范 IOHIDManager 匹配 `vendor=0x05AC / product=0x8104 / usagePage=0x0020 / usage=0x008A`，角度元素 `0x0020/0x047F`；独立线程 RunLoop + 上报回调 + 低频兜底轮询，并请求 `ReportInterval=8ms` 提速 |
| 动画与角度实时同步 | `HingeAnimationEngine.progress(for:)` | `进度 = (triggerAngleDeg − 角度) ÷ (triggerAngleDeg − closeAngleDeg)`，抬多少走多少 |
| 停顿 → 自动加速播完剩余片段 → 切回正常画面 | `startCatchUp / tickCatchUp / finishSequence` | 角度静止超过 `stallDurationMs` 即进入加速；补完到「展开」端（进度 0）立即 `active=false` 隐藏覆盖层交回正常桌面 |
| 停顿后反向移动 → 取消加速、跟随新角度 | `cancelCatchUp` | 任何一次有效角度变化都会立刻取消加速并回到跟随模式；折到底后锁定，掀开才解除 |
| **不要求开合到极限角度** | `finishSequence` + 平滑对齐 | 停手即从当前进度补完；进度与真实角度差过大（>0.25）时用一小段平滑追赶，避免画面瞬跳 |
| 全局覆盖、不干扰鼠标与窗口 | `OverlayController.swift` | `ignoresMouseEvents`、不成为 key/main 窗口、高窗口层级 + `canJoinAllSpaces` |
| **折叠视错觉（1:1 复刻 DuoHinge）** | `FoldShader.swift` + `MetalFoldView.swift` | 桌面固定在 z=0 平面，一整块「虚拟玻璃」绕屏幕**顶边铰链**立起；每像素从固定视点发射线穿过玻璃、打到桌面平面求交采样 → 呈现桌面被“折倒收进屏幕下方”。四趟 GPU 管线：投影 → 横向高斯 → 纵向高斯 → 径向色散 |
| 折叠方向可切换 | `foldDirection`（默认 `down`） | `down` = 铰链在屏幕顶边、内容向屏幕下方收（默认，符合“往下收”的直觉）；`up` = 参考实现的原始方向 |
| 低性能消耗 | `MetalFoldView.tick` + `emit()` | 有变化才渲染、静止时 `displayLink` 暂停；进度 0 时隐藏窗口并停采集 |
| 可启停 / 可调停顿时长与加速倍率 | 菜单栏 + `config.json` | `enabled`、`stallDurationMs`、`catchUpSpeed` 等 |
| **手机遥控 / 手机陀螺仪（演示用）** | `RemoteControl.swift`、`RemoteTLS.swift` | Network.framework 起一个仅监听局域网的服务（优先自签证书 HTTPS），手机浏览器打开设置面板显示的地址即可「合上 / 打开 / 播放一次 / 拖进度」；手机页面还能把**手机自身的陀螺仪姿态换算成屏幕开合角**（`GET /hinge`，20Hz），替代缺失的铰链传感器；每次启动随机生成口令 `t=xxxx`，关闭开关即完全停止 |
| 合盖不休眠（让动画不被锁屏吞掉） | `PowerControl.swift` | `pmset -a disablesleep 1`，经 osascript 申请一次性管理员授权 |

### 抗抖动设计（避免“必须掰到极限”的普通方案）
- **端点锁**：某一端补完一次后锁定，进度离开端点（`rearmProgress`）才允许再次触发，避免同方向反复播放。
- **折上锁定**：加速补完到「完全折上」后保持画面，直到用户反向掀开才重新跟随真实角度。
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
│   ├── AppDelegate.swift          装配：传感器 → 状态机 → 渲染层 + 菜单动作 + 手机遥控接线
│   ├── Config.swift               配置模型与读写（默认值合并，兼容旧配置）
│   ├── LidAngleSensor.swift       铰链角度读取 + 传感器探针
│   ├── HingeAnimationEngine.swift 核心状态机（跟随 / 停顿加速 / 反向取消）
│   ├── OverlayController.swift    全局覆盖窗口（穿透、不抢焦点、每屏一窗）
│   ├── MetalFoldView.swift        ★ 真实渲染：CAMetalLayer + 四趟管线接力绘制
│   ├── FoldShader.swift           ★ Metal 着色器源码（射线投射重投影、两趟高斯、径向色散）
│   ├── ScreenCaptureStream.swift  ★ ScreenCaptureKit 实时抓屏 → Metal 纹理（零拷贝）
│   ├── SettingsWindow.swift        App 内可视化设置面板（新手优先 + 可折叠高级设置）
│   ├── RemoteControl.swift        手机遥控：局域网服务（HTTPS/HTTP）+ 手机控制页 + 陀螺仪角度上报
│   ├── RemoteTLS.swift            手机遥控的本地自签证书（openssl 生成 + PKCS#12 → SecIdentity）
│   ├── PowerControl.swift         合盖不休眠（pmset）与「锁定屏幕」设置直达
│   ├── UpdateChecker.swift        检查 GitHub Release / 下载并交棒给替换脚本
│   └── StatusBarController.swift   菜单栏：启停 / 标定 / 重载 / 探针 / 授权 / 更新 / 退出
├── Resources/
│   ├── Info.plist                 LSUIElement=true，图标 AppIcon，版权署名 KDXZHX
│   └── logo.jpg                   作者 KDXZHX 的 logo（build.sh 自动转 AppIcon.icns，同时作菜单栏图标）
├── build.sh                       一键编译打包（含 logo → icns 转换）
├── install.sh                     一键自动安装（编译→/Applications→开机自启→启动，--uninstall 卸载）
├── 一键安装.command                双击即可安装（Finder 直接运行）
├── config.sample.json             默认配置样例
├── scripts/install-raw.sh         低网络要求终端安装脚本（推荐）
└── preview/hinge-sim.html         Duo Continuity 交互预览（WebGL2 四趟管线 + CPU 降级，无需 Mac 即可验证）
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
| `triggerAngleDeg` | 90 | **开始折叠角**：角度 ≥ 该值 → 进度 0（正常画面） |
| `closeAngleDeg` | 0 | **完全合上角**：角度 ≤ 该值 → 进度 1（玻璃完全立起） |
| `invertAngle` | false | 掀开屏幕时角度反而变小就设 true |
| `rearmProgress` | 0.05 | 进度离开端点超过该值才允许再次触发同向序列 |
| `sampleHz` | 60 | 兜底轮询频率；真实刷新依赖传感器的上报回调 |
| `smoothing` | 0.45 | EMA 平滑系数，0 关闭 |
| `overlayLevel` | 999 | 窗口层级，高于菜单栏(24)/状态栏(25)/Dock，可覆盖全屏 App |
| `visualStyle` | "frosted" | 视觉预设：`clear` / `frosted` / `cinematic`（对应 blur 0.25/1/1.3，darkness 0.2/1/1.2，色散 0/0/1） |
| `viewpoint` | "desk" | 视点：`desk` 俯看（笔记本放桌面）/ `front` 平视（支架抬升） |
| `foldAngleDeg` | 90 | 玻璃完全立起时的角度。90 = 与参考实现完全一致（末端几何退化为整屏黑）；调小到 70~80 可让完全折上时仍保留桌面画面 |
| `foldDirection` | "down" | **折叠方向**：`down` = 铰链在屏幕顶边、画面内容向屏幕下方收（默认，MacBook 观感）；`up` = 参考实现的原始方向（内容向上抽走） |
| `captureScreen` | true | 是否实时抓屏做重投影（关闭则只显示暗场） |
| `captureFPS` | 60 | 采集帧率上限 |
| `captureIdleStop` | true | 完全展开时停采集省电；false = 常驻采集响应更快 |
| `renderScale` | 0.75 | 渲染分辨率比例，越低越省电（模糊会掩盖损失） |
| `overlayAlpha` | 1.0 | 覆盖层最大不透明度 |
| `excludedFromCapture` | false | true 时录屏/共享看不到动画 |
| `remoteControl` | true | **手机遥控**开关：局域网 HTTP 服务，手机浏览器可远程控制动画（演示用） |
| `remoteControlPort` | 52800 | 手机遥控监听端口（优先 HTTPS，证书由 RemoteTLS 自动生成） |
| `phoneGyro` | true | 是否允许手机陀螺仪接管铰链角度（手机贴屏幕上模拟铰链，见第 15 节） |
| `autoCheckUpdate` | true | 启动后自动检查更新，发现新版本直接弹窗 |

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

**Q：脚本报 `MACOS_MIN: unbound variable`（变量名后面还带个乱码字符）？**
macOS 自带 bash 3.2 的已知坑：`$VAR` 后面紧跟中文（多字节）字符时，这些字节会被吞进变量名。
本项目脚本已全部改用 `${VAR}` 花括号写法，`git pull` 更新即可解决。


| 现象 | 原因与解决 |
| --- | --- |
| 菜单栏显示“未检测到铰链角度传感器” | 机型确实没有该硬件（Intel 机型常见）。跑「传感器探针」看报告：若 `Lid Angle Sensor 设备数: 0`，说明本机没有这颗传感器，角度跟随无法工作——这是硬件限制，不是程序问题（可用设置面板的「手动预览」滑块体验动画） |
| 探针里所有取值都是 0 | 系统权限或机型限制：在「系统设置 → 隐私与安全性 → 输入监控」中允许 MacKZ，或终端用 `sudo` 运行一次 App 再试 |
| 动画完全不出现 | ① 插件未启用 ② 角度没变化（先确认菜单里「铰链角度」有数值在动）③ 角度一直在 `triggerAngleDeg`(默认 90°) 以上 —— 只有低于该角才开始折叠，可用菜单栏「标定」把「开始折叠角」改到你实际会到的位置 |
| 动画一出现就消失 | `angleEpsilon` 太大或 `minCatchUpMs` 太小；也可能进度已到端点被锁（把屏幕开到中间再试） |
| 合盖后开盖看不到动画 | 合盖会立刻触发系统休眠，休眠唤醒要解锁，动画被压在锁屏之下。设置面板 →「合盖与休眠」→ 点「开启合盖不休眠」（需一次性管理员授权）；若开盖仍要求输密码，点「打开「锁定屏幕」设置」把「关闭显示器后需要密码」改为「永不」 |
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

安装后要做两件事：
1. 菜单栏 →「设置…」（或 ⌘,）打开 App 内可视化设置面板，所有参数可直接调；
2. 首次启动会自动申请「屏幕录制」权限（Duo Continuity 的桌面画源）；若当时点了拒绝，
   到 系统设置 → 隐私与安全性 → 屏幕录制 勾选 MacKZ，再点菜单「授权屏幕录制」自动重启生效。

---

## 14. App 内设置面板（推荐方式）

点菜单栏 logo 图标 →「设置…」，面板按**新手优先**排布，改完点「保存并应用」（回车）即可热生效，无需重启：

| 分区 | 可以调什么 |
| --- | --- |
| 实时状态 | 当前铰链角度 / 状态机阶段（待机、跟随、加速补完）/ 权限状态，每 0.6s 刷新 |
| 总开关 | 启用 / 停用整个插件（最常用，放在最前） |
| 权限 | 一键申请授权、修复权限（清更新后的过期记录）、跳转系统设置页 |
| 手机遥控（演示用） | 显示局域网访问地址（HTTPS）+ 复制链接 / 在本机打开 / 刷新地址，遥控开关，以及「允许手机陀螺仪接管角度」开关 |
| 常用设置 | 折叠方向、开始折叠角、视觉风格、手动预览滑块 + 「模拟合上 / 模拟打开 / 播放一次开合 / 复位」 |
| 合盖与休眠 | 开启合盖不休眠、恢复系统默认、直达「锁定屏幕」设置 |
| 高级设置（默认收起） | 角度标定、智能逻辑（停顿判定 / 加速倍率 / 片段时长 / 阈值）、视觉细节（视点、玻璃最大立起角、层级）、采集与性能（抓屏、帧率、渲染比例、采样率、平滑、遥控端口、自动检查更新） |
| 操作 | 恢复默认、放弃修改并重载、传感器探针、检查更新、保存并应用（版本号与作者 KDXZHX 也在这里） |

---

## 15. 手机遥控（演示用）与手机陀螺仪铰链

给演示场景准备的：手机连同一个 Wi-Fi，就能远程控制折叠动画，不用伸手去掰屏幕。

1. 设置面板 →「手机遥控（演示用）」，确认开关是打开的，面板上会显示形如
   `https://192.168.x.x:52800/?t=ab12cd` 的地址；
2. 点「复制链接」，发给自己的手机（或直接在手机上照着输入）；
3. 手机浏览器打开后是一个大字按钮页面：**合上 / 打开 / 播放一次开合 / 复位**，外加一个实时进度滑杆。
   首次打开会提示「证书不受信任」（本机自签证书），点「显示详细信息 → 继续访问」即可。

细节说明：
- 服务基于 `Network.framework`，**只监听局域网、不对外联网、不写任何文件**，关掉开关即完全停止；
- `t=xxxx` 是每次启动随机生成的 6 位口令，只在局域网内有效，插件重启后旧链接自动失效；
- 换端口在「高级设置 → 手机遥控端口」里改（默认 `52800`）；
- 服务优先以 **HTTPS** 起监听（`RemoteTLS.swift` 用系统自带 `openssl` 现场签一张含本机 IP 的自签证书），
  拿不到证书时自动回退 HTTP——遥控按钮两种模式都能用，但**手机陀螺仪必须走 HTTPS**。

### 手机陀螺仪铰链模式（没有铰链传感器的机型也能“抬屏即折叠”）

MacBook Air 等机型没有 Lid Angle Sensor，本插件原本只能退回「开盖/合盖事件」触发。
现在可以用手机当传感器：

1. 手机竖着贴（或用皮筋绑）在 MacBook 屏幕上，**手机顶部朝屏幕顶边**；
2. MacBook 放在水平桌面上，手机页面点「启用陀螺仪」并在系统弹窗里允许「运动与方向访问」；
3. 合上屏幕，点一次「标定为完全合上」把零位对齐（底座没放平、贴的位置有偏差都靠这一步校正）；
4. 掀开屏幕，页面上的角度就会实时变化，并**以 20Hz 直接把角度推给 Mac**，驱动折叠动画。

原理与实现要点：
- 屏幕法线绕铰链轴旋转，重力在手机 y/z 轴上的投影可直接解出开合角：
  贴屏幕背面（合盖时手机屏朝上）`lid = 180 − atan2(−gy, gz)`；贴屏幕正面 `lid = atan2(−gy, gz)`，
  与内置传感器同为「0° = 完全合上」，因此菜单栏标定（开始折叠角 / 完全合上角）继续有效；
- 手机 → Mac 走 `GET /hinge?t=口令&v=角度`，Mac 端默认复用同一条连接（keep-alive），避免 20Hz 反复 TLS 握手；
- 手机数据到达时由手机**接管**角度，本机传感器读数被忽略；超过 1.5 秒没有新数据
  （锁屏 / 切后台 / 离开 Wi-Fi）自动交还本机传感器，不会卡在最后一个角度上。

---

## 16. 更新日志

### v1.7.2
- 修复**菜单栏图标黑边**：等比缩放会在非正方形 logo 两侧留下透明留白，这些像素亮度为 0，
  旧算法直接取 `255 − 亮度` 把它们算成了「不透明黑」，于是在菜单栏上表现为 logo 两侧各挂一条黑边。
  现在最终 alpha 改为 `原有 alpha × (255 − 亮度) / 255`，并先清空画布，只保留纯 logo 本身；
- 新增**手机陀螺仪铰链模式**：手机贴在屏幕上，用手机姿态角模拟 MacBook 铰链开合，
  适合没有 Lid Angle Sensor 的机型（见第 15 节）；
- 手机遥控服务改为优先 **HTTPS**（自签证书自动生成），并把连接改为 keep-alive：
  浏览器读取运动传感器必须安全上下文，且 20Hz 上报不能反复重开 TLS 连接；
- 新增配置项 `phoneGyro`（可在设置面板关闭），`Info.plist` 补充本地网络用途说明。

### v1.7.1
- 菜单栏图标改为**去白底 + 裁留白**：原 logo 是白底深色图形且四周留白很大（图形只占约 55%），
  直接放进菜单栏是一个显眼的小白方块。现在会自动定位图形外接框、裁掉留白并把白底刷成透明，
  图形视觉上放大约 1.8 倍；同时图标尺寸从 18pt 提到 20pt，并设为模板图，
  浅色菜单栏显示黑色字形、深色菜单栏由系统自动反白。

### v1.7.0
- 新增**手机遥控**：手机浏览器远程控制折叠 / 展开动画，主要用于演示；
- 接入作者 **KDXZHX** 的 logo：`Resources/logo.jpg` 由 `build.sh` 自动转成 `AppIcon.icns`，
  并同时作为菜单栏图标（取不到时回退为代码绘制的 KZ 字样），`Info.plist` 版权署名同步更新；
- 设置面板按**新手优先**重排：手机遥控 / 常用设置前置，角度标定与采集性能收进可折叠的「高级设置」；
- 模拟动画放慢到 2.2 秒，且「模拟合上 / 模拟打开」支持反复点击；
- 折叠方向默认「向下收」（`foldDirection = down`，铰链在屏幕顶边）；
- 更新弹窗层级提到 2000 并加入所有空间，不再被设置面板挡住；
- 新增「合盖不休眠」开关，解决休眠 + 锁屏把开合动画吞掉的问题；
- 安装脚本改为抗假死版本（整包优先 + 多镜像 + 超时保护）；
- 官网产品页上线：<https://kdxzhx.top/mackz.html>

### v1.6.0
- 四趟 Metal 管线（重投影 → 横向高斯 → 纵向高斯 → 径向色散）1:1 复刻 DuoHinge 折叠视错觉。

### v1.5.x
- 折叠方向可切换、手动预览、启动自动检查更新与弹窗提示。

---

## 17. 更新 · 卸载 · 反馈

- **更新**：菜单栏 →「检查更新…」，发现新版本会自动弹窗，一键下载替换并重启；
  也可以重新执行一次上面的终端安装命令。
- **卸载**：

```bash
rm -rf /Applications/MacKZ.app ~/Library/LaunchAgents/com.mackz.plugin.plist
```

- **反馈**：<https://github.com/ndpysnythv-blip/MacKZ/issues>

