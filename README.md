# MeetingRecorder

> 自动录制并转写 Zoom / 飞书(Lark) 会议的 macOS 菜单栏小工具，100% 本地离线。

一个**轻量的 macOS 菜单栏小应用**：自动检测 Zoom / Lark（飞书）会议的开始与结束，
自动录音（系统音频 + 麦克风，**无需 BlackHole 虚拟声卡**），会议一结束就在后台用
**本地 whisper.cpp** 把整段录音转写成带说话人标签的文本。全程离线，音频不出本机。

## 特性

- 🎯 **自动检测**：Zoom / 飞书会议开始自动录，结束自动停，全程无需手动
- 🎙️ **双轨录音**：系统音频（对方）+ 麦克风（你），基于 ScreenCaptureKit，**不装虚拟声卡**
- 📝 **本地转写**：whisper.cpp 离线转写，音频与文本都不出本机
- 👥 **说话人分离**：分轨转写 → 输出 `[时间戳] 我 / 对方：…` 带标签文本
- 🔇 **VAD 去幻觉**：语音活动检测跳过静音段，消除 whisper 在安静处的乱码
- 🚀 **开机自启**：菜单栏一键开关
- 🪶 **零第三方依赖**：纯系统框架（Swift + ScreenCaptureKit + AVFoundation + AppKit）

平台：macOS 13+（在 macOS 15.3 / Intel 上开发验证）。外部工具：`whisper-cli` + `ffmpeg`。

---

## 工作原理

```
菜单栏常驻
   │  每 3 秒轮询窗口列表 (CGWindowList)
   ▼
检测到 Zoom/Lark「会议窗口」──► 开始录音   系统音频(SCK)→system.caf  +  麦克风(AVAudioEngine)→mic.caf
   │  会议窗口消失 ≥3 次(去抖)
   ▼
停止录音 ──► 分轨转写(各带 VAD)  system.caf→whisper→对方  +  mic.caf→whisper→我
                                          │  按时间戳合并
                                          ▼
                                   transcript.txt (带说话人标签)
```

会议判定 = **进程名命中** 且 **窗口标题命中**（规则见 `config.json`，可热改）。

---

## 安装与构建

### 1) 安装依赖 + 下载模型
```bash
bash scripts/setup.sh
```
装 `whisper-cpp` + `ffmpeg`，并下载 `ggml-small`（多语种，中英通用）到
`~/MeetingRecordings/models/`。

### 2) 构建 App
```bash
bash scripts/build_app.sh
```
产出 `MeetingRecorder.app`（直接用 `swiftc` 编译并打包、ad-hoc 签名）。

> ⚠️ **若报 `redefinition of module 'SwiftBridging'` 或编译卡住不动**，见下方
> 「故障排查 · 工具链」。这是 Command Line Tools 16.x 的已知 bug，需一条 `sudo`
> 命令修复，与本项目代码无关。

### 3) 首次运行与授权
```bash
open ./MeetingRecorder.app
```
菜单栏会出现 🎙️。首次会请求两项权限，请到
**系统设置 → 隐私与安全性** 里勾选本 App：
- **屏幕录制**（SCK 抓系统音频 + 读取窗口标题都需要它）
- **麦克风**

授权后从菜单栏「退出」再 `open` 一次，权限才会生效。

---

## 使用

菜单栏图标状态：🎙️ 空闲 / 🔴 录音中 / ⏳ 转写中。

菜单项：
- **手动开始 / 停止录音**：不依赖检测的兜底开关
- **自动检测：开/关**
- **开机自启：开/关**（`SMAppService`；首次可能要到「系统设置 → 通用 → 登录项」点允许）
- **打开上次转写文本 / 打开录音文件夹**
- **重新加载配置 / 编辑配置文件**

每场会议输出到 `~/MeetingRecordings/<时间戳>-<平台>/`：
- `system.caf`（对方声音）、`mic.caf`（你的声音）—— 原始双轨
- `system-16k.wav` / `mic-16k.wav`、`system.json` / `mic.json` —— 转写中间产物
- `mixed.wav`（两轨混音，方便整体回放）
- **`transcript.txt`（带说话人标签的最终文本）**

### 说话人分离（「我 / 对方」）
录音天然分两轨（你的麦克风 vs 远端系统音频），转写时**分别**跑 whisper（各自带 VAD
跳过对方说话时的静音），再按时间戳合并成带标签的文本：
```
[00:00:03] 对方：你好，我们开始吧
[00:00:07] 我：好的，这边先同步一下进度
[00:00:15] 对方：收到
```
> 说明：远端多个人都会标成「对方」，本方案不区分远端具体是谁（那需要 pyannote 等重型模型）。

---

## 配置 `~/MeetingRecordings/config.json`

首次运行自动生成。字段：

| 字段 | 说明 |
|------|------|
| `pollIntervalSec` | 轮询间隔秒数（默认 3） |
| `endDebounceCount` | 连续多少次未检测到才判定结束（默认 3，约 9 秒） |
| `language` | whisper 语言：`auto` / `zh` / `en` … |
| `outputDir` | 输出目录 |
| `whisperBin` | `whisper-cli` 路径（Intel brew 默认 `/usr/local/bin/whisper-cli`） |
| `whisperModel` | ggml 模型路径 |
| `ffmpegBin` | ffmpeg 路径 |
| `vadModel` | VAD 模型路径；存在则自动启用，跳过静音段，避免 whisper 在安静处产生「字幕组署名」类幻觉。删掉此字段或文件即关闭 VAD |
| `platforms[]` | 每个平台的 `name` / `ownerNames` / `titlePatterns` |

改完在菜单里点「重新加载配置」即可生效。

### 校正 Lark 会议窗口标题（重要）
Zoom 的会议窗口标题固定是 `Zoom Meeting`，已内置。**Lark 的会议窗口真实标题需要你实测确认**：

```bash
# 先给「终端」授予「屏幕录制」权限，否则读不到标题
# 开一场真实的 Lark 会议，然后：
swift scripts/debug_windows.swift
```
把飞书会议那一行的 `OWNER` / `TITLE` 填进 `config.json` 的 lark 规则里
（`titlePatterns` 用标题里的稳定子串即可）。

---

## 故障排查

### 工具链：`redefinition of module 'SwiftBridging'` / 编译卡死
Command Line Tools 16.x 的安装 bug——`module.modulemap` 与 `bridging.modulemap`
重复定义了同一个模块。一条命令修复（可逆）：
```bash
sudo mv /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap \
        /Library/Developer/CommandLineTools/usr/include/swift/module.modulemap.disabled
```
撤销就把 `.disabled` 改回去。或彻底重装：
```bash
sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install
```

### 检测不触发
- 确认已授予**屏幕录制**权限（否则窗口标题读不到）。
- 用 `swift scripts/debug_windows.swift` 看会议窗口真实标题，校正 `config.json`。

### transcript.txt 没生成 / whisper 报错
- 确认 `whisperBin` 路径正确：`command -v whisper-cli`（brew 可能装成别的名字）。
- 确认 `whisperModel` 文件存在。

### 只有一方声音
- 只有 `mic.caf`：屏幕录制权限没给，SCK 抓不到系统音频。
- 只有 `system.caf`：麦克风权限没给，或没有可用输入设备。

### Intel 上转写慢
`ggml-small` 约 1–2x 实时。想更快可换 `ggml-base`（改 `whisperModel`，准确度略降）。
启用 VAD 后只处理有语音的片段，通常反而更快。

### 转写里出现「(字幕製作:…)」「請不吝點贊」等莫名其妙的句子
这是 whisper 在**静音段**上的幻觉。本项目默认启用 VAD（`vadModel` 字段）来跳过静音、消除这类幻觉。
若仍出现，确认 `~/MeetingRecordings/models/ggml-silero-v5.1.2.bin` 存在（`setup.sh` 会下载）。

---

## 目录结构
```
MeetingRecorder/
├── Package.swift                    # 备用（有完整 Xcode 时可 swift build）
├── Sources/MeetingRecorder/
│   ├── main.swift                   # 入口
│   ├── AppDelegate.swift            # 菜单栏 UI + 状态机串联
│   ├── MeetingDetector.swift        # 窗口检测
│   ├── AudioRecorder.swift          # SCK 系统音频 + 麦克风
│   ├── Transcriber.swift            # ffmpeg 混音 + whisper
│   └── Config.swift                 # 配置
├── Resources/Info.plist             # bundle + 权限用途说明
├── config.example.json
└── scripts/
    ├── setup.sh                     # 装 whisper-cpp/ffmpeg + 下模型
    ├── build_app.sh                 # swiftc 编译 + 打包 .app
    └── debug_windows.swift          # 抓窗口标题（校正 Lark 用）
```
