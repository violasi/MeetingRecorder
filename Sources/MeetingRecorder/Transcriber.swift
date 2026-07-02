import Foundation

/// 后台转写 + 说话人分离（「我 / 对方」）。
///
/// 利用录音阶段已经分开的两条音轨：
///   - mic.caf    → 你的声音    → 标注「我」
///   - system.caf → 远端的声音  → 标注「对方」
/// 分别用 whisper 转写（各自带 VAD，跳过对方说话时的静音），拿到带时间戳的分段，
/// 再按时间戳合并成一份带说话人标签的 transcript.txt。
final class Transcriber {
    private var config: Config
    private let queue = DispatchQueue(label: "MeetingRecorder.transcriber", qos: .utility)

    init(config: Config) { self.config = config }

    func updateConfig(_ c: Config) { config = c }

    private struct Segment {
        let ms: Int          // 起始毫秒
        let speaker: String
        let text: String
    }

    /// dir 内应含 system.caf / mic.caf（可只有其一）。progress/completion 回调在后台线程。
    func transcribe(dir: URL,
                    progress: @escaping (String) -> Void,
                    completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async {
            do {
                let tracks: [(file: String, speaker: String)] = [
                    ("system.caf", "对方"),
                    ("mic.caf", "我")
                ]
                var segments: [Segment] = []
                var anyTrack = false

                for t in tracks {
                    let caf = dir.appendingPathComponent(t.file)
                    guard self.fileNonEmpty(caf) else { continue }
                    anyTrack = true
                    progress("转写「\(t.speaker)」轨…")
                    let base = (t.file as NSString).deletingPathExtension  // "system" / "mic"
                    let wav = dir.appendingPathComponent("\(base)-16k.wav")
                    try self.toMonoWav(input: caf, output: wav)
                    segments += try self.whisperSegments(wav: wav, speaker: t.speaker,
                                                          outBase: dir.appendingPathComponent(base))
                }
                guard anyTrack else {
                    throw self.err("没有可用的音频文件（system.caf / mic.caf 都为空）")
                }

                // 按时间戳合并
                segments.sort { $0.ms < $1.ms }
                let body = segments
                    .map { "[\(Self.hms($0.ms))] \($0.speaker)：\($0.text.trimmingCharacters(in: .whitespaces))" }
                    .joined(separator: "\n")
                let txt = dir.appendingPathComponent("transcript.txt")
                try (body + "\n").write(to: txt, atomically: true, encoding: .utf8)

                // 额外混一份 mixed.wav 方便整体回放（失败不影响转写结果）
                progress("生成回放音频…")
                _ = try? self.mixdown(dir: dir)

                completion(.success(txt))
            } catch {
                completion(.failure(error))
            }
        }
    }

    // MARK: - 单轨转写（whisper JSON → 分段）

    private func whisperSegments(wav: URL, speaker: String, outBase: URL) throws -> [Segment] {
        let threads = String(max(4, ProcessInfo.processInfo.activeProcessorCount))
        var args = [
            "-m", config.expandedWhisperModel,
            "-f", wav.path,
            "-l", config.language,
            "-t", threads,
            "-sns",              // 抑制非语音 token
            "-oj",               // 输出 JSON（含时间戳），文件名 outBase.json
            "-of", outBase.path
        ]
        // 有 VAD 模型就启用：跳过静音段，避免 whisper 在安静处产生「字幕组署名」类幻觉。
        if FileManager.default.fileExists(atPath: config.expandedVadModel) {
            args += ["--vad", "--vad-model", config.expandedVadModel, "-vp", "200"]
        }
        try Transcriber.run(config.whisperBin, args)

        let jsonURL = URL(fileURLWithPath: outBase.path + ".json")
        guard let data = try? Data(contentsOf: jsonURL) else { return [] }
        let decoded = try JSONDecoder().decode(WhisperJSON.self, from: data)
        return decoded.transcription.compactMap { seg in
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return Segment(ms: seg.offsets.from, speaker: speaker, text: text)
        }
    }

    private struct WhisperJSON: Decodable {
        struct Seg: Decodable {
            struct Offsets: Decodable { let from: Int; let to: Int }
            let offsets: Offsets
            let text: String
        }
        let transcription: [Seg]
    }

    // MARK: - ffmpeg

    /// 单个 caf → 16kHz 单声道 wav（whisper 输入要求）。
    private func toMonoWav(input: URL, output: URL) throws {
        try Transcriber.run(config.ffmpegBin,
            ["-y", "-hide_banner", "-loglevel", "error",
             "-i", input.path, "-ar", "16000", "-ac", "1", output.path])
    }

    /// 把两轨混成一份 mixed.wav 供回放（只是方便听，不参与转写）。
    @discardableResult
    private func mixdown(dir: URL) throws -> URL {
        let sys = dir.appendingPathComponent("system.caf")
        let mic = dir.appendingPathComponent("mic.caf")
        let mixed = dir.appendingPathComponent("mixed.wav")
        let hasSys = fileNonEmpty(sys), hasMic = fileNonEmpty(mic)

        var args: [String] = ["-y", "-hide_banner", "-loglevel", "error"]
        if hasSys && hasMic {
            args += ["-i", sys.path, "-i", mic.path,
                     "-filter_complex", "amix=inputs=2:duration=longest:normalize=0"]
        } else if hasSys {
            args += ["-i", sys.path]
        } else if hasMic {
            args += ["-i", mic.path]
        } else {
            throw err("没有可用的音频文件")
        }
        args += ["-ar", "16000", "-ac", "1", mixed.path]
        try Transcriber.run(config.ffmpegBin, args)
        return mixed
    }

    // MARK: - helpers

    private func fileNonEmpty(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        return size > 1024
    }

    private func err(_ msg: String) -> NSError {
        NSError(domain: "Transcriber", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func hms(_ ms: Int) -> String {
        let s = ms / 1000
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// 运行外部进程。stdout 丢弃避免管道堵塞，只捕获 stderr 用于报错。
    @discardableResult
    static func run(_ launchPath: String, _ args: [String]) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else {
            throw NSError(domain: "Process", code: 127,
                          userInfo: [NSLocalizedDescriptionKey: "找不到可执行文件: \(launchPath)"])
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let errPipe = Pipe()
        p.standardOutput = FileHandle.nullDevice
        p.standardError = errPipe
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let errStr = String(data: errData, encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw NSError(domain: "Process", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                            "\((launchPath as NSString).lastPathComponent) 退出码 \(p.terminationStatus): \(errStr)"])
        }
        return errStr
    }
}
