import Foundation

/// 单个平台的检测规则：进程名 + 窗口标题模式（子串，大小写不敏感）。
struct PlatformRule: Codable {
    let name: String            // "zoom" / "lark"
    let ownerNames: [String]    // 进程/App 名，任一命中即可
    let titlePatterns: [String] // 窗口标题子串，任一命中即判定为「会议中」
}

/// 全局配置。持久化在 ~/MeetingRecordings/config.json，可热加载。
struct Config: Codable {
    var pollIntervalSec: Double   // 轮询窗口的间隔（秒）
    var endDebounceCount: Int     // 连续多少次未检测到才判定会议结束（去抖）
    var language: String          // whisper 语言："auto" / "zh" / "en" ...
    var outputDir: String         // 录音与转写输出目录
    var whisperBin: String        // whisper-cli 可执行文件路径
    var whisperModel: String      // ggml 模型路径
    var ffmpegBin: String         // ffmpeg 路径
    var vadModel: String?         // VAD(语音活动检测)模型路径；存在则启用，跳过静音段避免幻觉
    var platforms: [PlatformRule]

    static let `default` = Config(
        pollIntervalSec: 3,
        endDebounceCount: 3,
        language: "auto",
        outputDir: "~/MeetingRecordings",
        whisperBin: "/usr/local/bin/whisper-cli",
        whisperModel: "~/MeetingRecordings/models/ggml-small.bin",
        ffmpegBin: "/usr/local/bin/ffmpeg",
        vadModel: "~/MeetingRecordings/models/ggml-silero-v5.1.2.bin",
        platforms: [
            PlatformRule(
                name: "zoom",
                ownerNames: ["zoom.us"],
                titlePatterns: ["Zoom Meeting", "Zoom 会议"]
            ),
            PlatformRule(
                name: "lark",
                // Lark 真实进程名/窗口标题需运行时用 scripts/debug_windows.swift 校正
                ownerNames: ["Lark", "LarkSuite", "Feishu", "飞书"],
                titlePatterns: ["Meeting", "会议", "视频会议", "语音通话", "视频通话", "Video Call", "Group Call"]
            )
        ]
    )

    var expandedOutputDir: URL {
        URL(fileURLWithPath: (outputDir as NSString).expandingTildeInPath)
    }
    var expandedWhisperModel: String {
        (whisperModel as NSString).expandingTildeInPath
    }
    /// VAD 模型的展开路径（未配置时用默认位置）。文件是否存在由 Transcriber 判断。
    var expandedVadModel: String {
        let p = vadModel ?? "~/MeetingRecordings/models/ggml-silero-v5.1.2.bin"
        return (p as NSString).expandingTildeInPath
    }

    static func configURL() -> URL {
        let dir = URL(fileURLWithPath: ("~/MeetingRecordings" as NSString).expandingTildeInPath)
        return dir.appendingPathComponent("config.json")
    }

    /// 读取配置；不存在则写入默认值再返回，方便用户直接编辑。
    static func load() -> Config {
        let url = configURL()
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(Config.self, from: data) {
            return cfg
        }
        let cfg = Config.default
        cfg.save()
        return cfg
    }

    func save() {
        let url = Config.configURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try? enc.encode(self).write(to: url)
    }
}
