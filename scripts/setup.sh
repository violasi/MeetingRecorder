#!/usr/bin/env bash
set -euo pipefail

echo "== 1/3 安装 whisper-cpp 与 ffmpeg (brew) =="
brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
brew list ffmpeg      >/dev/null 2>&1 || brew install ffmpeg

MODELDIR="$HOME/MeetingRecordings/models"
mkdir -p "$MODELDIR"
MODEL="$MODELDIR/ggml-small.bin"

echo "== 2/3 下载 whisper small 模型 (~466MB，多语种，中英通用) =="
if [ ! -f "$MODEL" ]; then
  curl -L --fail -o "$MODEL" \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin"
else
  echo "已存在，跳过: $MODEL"
fi

VAD="$MODELDIR/ggml-silero-v5.1.2.bin"
echo "== 2.5/3 下载 VAD 模型 (~864KB，跳过静音段，避免转写幻觉) =="
if [ ! -f "$VAD" ]; then
  curl -L --fail -o "$VAD" \
    "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
else
  echo "已存在，跳过: $VAD"
fi

echo "== 3/3 校验 =="
WHISPER_BIN="$(command -v whisper-cli || true)"
if [ -z "$WHISPER_BIN" ]; then
  echo "⚠️  未找到 whisper-cli。检查 brew 安装的可执行文件名："
  ls -1 "$(brew --prefix)/bin" | grep -i whisper || true
  echo "   若名字不同，请把它填进 ~/MeetingRecordings/config.json 的 whisperBin 字段。"
else
  echo "whisper-cli: $WHISPER_BIN"
fi
echo "ffmpeg:      $(command -v ffmpeg)"
echo "模型:        $MODEL"
echo ""
echo "✅ setup 完成。若 whisper-cli 路径不是 /usr/local/bin/whisper-cli，"
echo "   记得更新 ~/MeetingRecordings/config.json。"
