import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 同时采集两路音频：
///   - 系统音频（对方声音）：ScreenCaptureKit，无需 BlackHole 虚拟声卡 → system.caf
///   - 麦克风（你的声音）：AVAudioEngine 输入 tap → mic.caf
/// 两路各写一个文件，转写前由 ffmpeg 混音。
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private(set) var currentDir: URL?

    // 系统音频
    private var stream: SCStream?
    private var systemURL: URL!
    private var systemFile: AVAudioFile?
    private let audioQueue = DispatchQueue(label: "MeetingRecorder.systemAudio")

    // 麦克风
    private let engine = AVAudioEngine()
    private var micURL: URL!
    private var micFile: AVAudioFile?
    private var micTapInstalled = false

    /// 开始录音。两路互相独立：任一路失败不影响另一路；只有两路都失败才抛错。
    func start(dir: URL) async throws {
        currentDir = dir
        systemURL = dir.appendingPathComponent("system.caf")
        micURL = dir.appendingPathComponent("mic.caf")

        // 麦克风先起，且不因系统音频失败而被跳过
        let micOK = startMicCapture()

        var systemOK = false
        do {
            try await startSystemCapture()
            systemOK = true
        } catch {
            NSLog("[AudioRecorder] 系统音频采集失败（继续录麦克风）: \(error)")
        }

        if !micOK && !systemOK {
            throw NSError(domain: "AudioRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "系统音频和麦克风都启动失败——请检查【屏幕录制】和【麦克风】权限"])
        }
    }

    func stop() async {
        if let s = stream { try? await s.stopCapture() }
        stream = nil

        if micTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            micTapInstalled = false
        }
        engine.stop()

        // 关闭文件（置 nil 触发 flush/close）
        audioQueue.sync { systemFile = nil }
        micFile = nil
    }

    // MARK: - 系统音频 (ScreenCaptureKit)

    private func startSystemCapture() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw NSError(domain: "AudioRecorder", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可用显示器（屏幕录制权限？）"])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true   // 不录本 App 自身声音，避免回授
        // 仍需给个最小视频配置，但我们只添加 .audio 输出，视频帧不消费
        cfg.width = 128
        cfg.height = 128
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await s.startCapture()
        stream = s
    }

    // MARK: - 麦克风 (AVAudioEngine)

    /// 返回是否成功开始录麦克风。
    @discardableResult
    private func startMicCapture() -> Bool {
        let input = engine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0 else {
            NSLog("[AudioRecorder] 无可用麦克风输入，跳过麦克风录制")
            return false
        }
        do {
            micFile = try AVAudioFile(forWriting: micURL, settings: fmt.settings)
        } catch {
            NSLog("[AudioRecorder] 创建麦克风文件失败: \(error)")
            return false
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: fmt) { [weak self] buffer, _ in
            try? self?.micFile?.write(from: buffer)
        }
        micTapInstalled = true
        engine.prepare()
        do {
            try engine.start()
            return true
        } catch {
            NSLog("[AudioRecorder] 启动麦克风引擎失败: \(error)")
            input.removeTap(onBus: 0)
            micTapInstalled = false
            return false
        }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        do {
            if systemFile == nil {
                systemFile = try AVAudioFile(forWriting: systemURL, settings: pcm.format.settings)
            }
            try systemFile?.write(from: pcm)
        } catch {
            NSLog("[AudioRecorder] 写入系统音频失败: \(error)")
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[AudioRecorder] 系统音频流停止: \(error)")
    }

    // MARK: - CMSampleBuffer → AVAudioPCMBuffer

    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = sb.formatDescription,
              var asbd = fd.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buf
    }
}
