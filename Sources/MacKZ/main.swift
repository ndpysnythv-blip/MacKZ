import AppKit

// MacKZ 入口。
// 以 .accessory 模式启动：没有 Dock 图标、不会抢占前台焦点，
// 因此插件在任意 App 前台运行时都能静默工作（不干扰窗口操作）。
let app = NSApplication.shared
let delegate = AppDelegate()          // 全局强引用（NSApplication.delegate 是 weak）
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
