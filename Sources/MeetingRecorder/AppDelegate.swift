import AppKit
import AVFoundation
import CoreGraphics
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var config = Config.load()
    private lazy var detector = MeetingDetector(config: config)
    private let recorder = AudioRecorder()
    private lazy var transcriber = Transcriber(config: config)

    private enum State { case idle, recording, transcribing }
    private var state: State = .idle
    private var recordingPlatform: String?
    private var lastTranscript: URL?
    private var autoDetect = true

    // MARK: - lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        requestPermissions()
        setupMenuBar()

        detector.onStart = { [weak self] platform in self?.handleStart(platform, manual: false) }
        detector.onEnd = { [weak self] platform in self?.handleEnd(platform) }
        detector.start()
    }

    private func requestPermissions() {
        // 屏幕录制：SCK 抓系统音频 + 读窗口标题都需要
        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    // MARK: - menu bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎙️"
        rebuildMenu(status: "空闲 · 等待会议")
    }

    private func rebuildMenu(status: String) {
        let menu = NSMenu()
        menu.addItem(withTitle: status, action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        switch state {
        case .idle:
            menu.addItem(item("● 手动开始录音", #selector(manualStart)))
        case .recording:
            menu.addItem(item("■ 停止录音并转写", #selector(manualStop)))
        case .transcribing:
            let m = NSMenuItem(title: "转写进行中…", action: nil, keyEquivalent: "")
            m.isEnabled = false
            menu.addItem(m)
        }

        let toggle = item(autoDetect ? "自动检测：开 ✓" : "自动检测：关", #selector(toggleAuto))
        menu.addItem(toggle)

        let loginOn = SMAppService.mainApp.status == .enabled
        menu.addItem(item(loginOn ? "开机自启：开 ✓" : "开机自启：关", #selector(toggleLoginItem)))
        menu.addItem(.separator())

        if lastTranscript != nil {
            menu.addItem(item("打开上次转写文本", #selector(openLastTranscript)))
        }
        menu.addItem(item("打开录音文件夹", #selector(openFolder)))
        menu.addItem(item("重新加载配置", #selector(reloadConfig)))
        menu.addItem(item("编辑配置文件", #selector(editConfig)))
        menu.addItem(.separator())
        menu.addItem(item("退出", #selector(quit)))

        statusItem.menu = menu
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        m.target = self
        return m
    }

    // MARK: - recording flow

    private func handleStart(_ platform: String, manual: Bool) {
        guard state == .idle else { return }
        if !manual && !autoDetect { return }

        let dir = config.expandedOutputDir
            .appendingPathComponent("\(Self.timestamp())-\(platform)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        state = .recording
        recordingPlatform = platform
        setStatusIcon("🔴")
        rebuildMenu(status: "● 录音中 · \(platform)")
        notify("开始录音", "检测到 \(platform) 会议")

        Task {
            do {
                try await recorder.start(dir: dir)
            } catch {
                NSLog("[App] 录音启动失败: \(error)")
                await MainActor.run {
                    self.state = .idle
                    self.recordingPlatform = nil
                    self.setStatusIcon("🎙️")
                    self.rebuildMenu(status: "录音启动失败：\(error.localizedDescription)")
                    self.notify("录音启动失败", error.localizedDescription)
                }
            }
        }
    }

    private func handleEnd(_ platform: String) {
        guard state == .recording else { return }
        state = .transcribing
        recordingPlatform = nil
        setStatusIcon("⏳")
        rebuildMenu(status: "⏳ 转写中…")

        let dir = recorder.currentDir
        Task {
            await recorder.stop()
            guard let dir = dir else {
                await MainActor.run { self.finishToIdle(status: "转写失败：无录音目录") }
                return
            }
            transcriber.transcribe(dir: dir, progress: { [weak self] msg in
                DispatchQueue.main.async { self?.rebuildMenu(status: "⏳ " + msg) }
            }, completion: { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    switch result {
                    case .success(let txt):
                        self.lastTranscript = txt
                        self.notify("转写完成 ✓", dir.lastPathComponent)
                        self.finishToIdle(status: "完成 · \(dir.lastPathComponent)")
                    case .failure(let e):
                        self.notify("转写失败", e.localizedDescription)
                        self.finishToIdle(status: "转写失败：\(e.localizedDescription)")
                    }
                }
            })
        }
    }

    private func finishToIdle(status: String) {
        state = .idle
        recordingPlatform = nil
        setStatusIcon("🎙️")
        rebuildMenu(status: status)
    }

    // MARK: - menu actions

    @objc private func manualStart() { handleStart("manual", manual: true) }

    @objc private func manualStop() {
        handleEnd(recordingPlatform ?? "manual")
    }

    @objc private func toggleAuto() {
        autoDetect.toggle()
        detector.setEnabled(autoDetect)
        rebuildMenu(status: autoDetect ? "自动检测已开启" : "自动检测已关闭")
    }

    @objc private func toggleLoginItem() {
        let svc = SMAppService.mainApp
        do {
            if svc.status == .enabled {
                try svc.unregister()
                rebuildMenu(status: "已关闭开机自启")
            } else {
                try svc.register()
                if svc.status == .requiresApproval {
                    rebuildMenu(status: "请到「系统设置 → 通用 → 登录项」允许本 App")
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                } else {
                    rebuildMenu(status: "已开启开机自启")
                }
            }
        } catch {
            rebuildMenu(status: "开机自启设置失败：\(error.localizedDescription)")
            notify("开机自启设置失败", error.localizedDescription)
        }
    }

    @objc private func openFolder() {
        let dir = config.expandedOutputDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func openLastTranscript() {
        if let t = lastTranscript { NSWorkspace.shared.open(t) }
    }

    @objc private func reloadConfig() {
        config = Config.load()
        detector.updateConfig(config)
        transcriber.updateConfig(config)
        rebuildMenu(status: "配置已重新加载")
    }

    @objc private func editConfig() {
        let url = Config.configURL()
        if !FileManager.default.fileExists(atPath: url.path) { config.save() }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: - helpers

    private func setStatusIcon(_ s: String) { statusItem.button?.title = s }

    private func notify(_ title: String, _ body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f.string(from: Date())
    }
}
