import Foundation
import CoreGraphics

/// 轮询屏上窗口列表，用「进程名 + 窗口标题」判定 Zoom / Lark 会议的开始与结束。
///
/// 注意：读取窗口标题 (kCGWindowName) 需要「屏幕录制」权限，否则标题为空、无法检测。
final class MeetingDetector {
    var onStart: ((String) -> Void)?   // 参数为平台名
    var onEnd: ((String) -> Void)?

    private(set) var enabled = true
    private var config: Config
    private var timer: Timer?
    private var current: String?       // 当前判定为进行中的会议平台
    private var missCount = 0

    init(config: Config) { self.config = config }

    func updateConfig(_ c: Config) { config = c }

    func setEnabled(_ v: Bool) {
        enabled = v
        if !v { missCount = 0 }
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: config.pollIntervalSec, repeats: true) {
            [weak self] _ in self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// 供 UI 展示：当前检测到的平台（nil 表示无会议）。
    var currentPlatform: String? { current }

    private func poll() {
        guard enabled else { return }
        let detected = detectPlatform()
        if let p = detected {
            missCount = 0
            if current == nil {
                current = p
                onStart?(p)
            }
        } else if let c = current {
            missCount += 1
            if missCount >= config.endDebounceCount {
                current = nil
                missCount = 0
                onEnd?(c)
            }
        }
    }

    /// 返回命中的平台名；无则 nil。
    private func detectPlatform() -> String? {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for w in list {
            let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
            let title = (w[kCGWindowName as String] as? String) ?? ""
            if title.isEmpty { continue }
            for rule in config.platforms {
                let ownerHit = rule.ownerNames.contains { owner.localizedCaseInsensitiveContains($0) }
                let titleHit = rule.titlePatterns.contains { title.localizedCaseInsensitiveContains($0) }
                if ownerHit && titleHit { return rule.name }
            }
        }
        return nil
    }
}
