// 用法: swift scripts/debug_windows.swift
//
// 打印当前所有「有标题」的屏上窗口的 进程名 + 窗口标题。
// 开一场真实的 Zoom / Lark 会议后运行本脚本，把会议窗口对应的
// ownerName / title 填进 ~/MeetingRecordings/config.json 的 platforms 里。
//
// 注意: 从终端运行时，需要给「终端 (Terminal / iTerm)」授予「屏幕录制」权限，
// 否则窗口标题会是空的（会被本脚本过滤掉）。

import CoreGraphics
import Foundation

let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
    FileHandle.standardError.write("无法读取窗口列表\n".data(using: .utf8)!)
    exit(1)
}

print("OWNER                | TITLE")
print("---------------------+----------------------------------------")
var shown = 0
for w in list {
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let title = (w[kCGWindowName as String] as? String) ?? ""
    if title.isEmpty { continue }
    let o = owner.padding(toLength: 20, withPad: " ", startingAt: 0)
    print("\(o) | \(title)")
    shown += 1
}
if shown == 0 {
    print("(没有可见窗口标题 —— 多半是终端没有「屏幕录制」权限，请到系统设置里授予后重试)")
}
