# 接入 local-ASR-service

## 推荐调用方式

业务脚本、Agent、Skill 或其它工具统一调用本项目提供的 HTTP API 或 CLI。不要在上游项目中复制 FunASR 模型加载、VAD、标点、设备选择或并发队列逻辑。

### CLI

```powershell
.\bin\asr.cmd health
.\bin\asr.cmd transcribe "D:\temp\audio.wav"
```

`transcribe` 的标准输出是单个 JSON 对象：

```json
{
  "status": "ok",
  "text": "恢复标点后的可读文本。",
  "raw_text": "恢复标点前的ASR文本",
  "language": "zh",
  "duration": 17.972,
  "model": "SenseVoiceSmall",
  "segments": [
    {
      "start": 0.0,
      "end": 17.95,
      "text": "与该时间段对应的文本。"
    }
  ]
}
```

业务默认使用 `text`。`raw_text` 主要用于模型对比、调试或质量分析。

### HTTP

```text
GET  http://127.0.0.1:8001/health
GET  http://127.0.0.1:8001/v1/models
POST http://127.0.0.1:8001/v1/audio/transcriptions
```

multipart form-data：

```text
file=<本地媒体文件>
model=custom
language=zh
response_format=verbose_json
```

服务支持 WAV、MP3、FLAC、M4A、OGG、WebM、MP4、MOV、MKV。所有媒体均由服务端统一调用 FFmpeg 规范化为 16 kHz 单声道 WAV，调用方不需要自行抽音轨或预处理采样率。

上传按 4 MiB 分块写入项目 `runtime/temp`，默认单文件上限为 2 GiB；长媒体不会以完整文件形式占用服务进程内存。HTTP 调用方应将总超时设为不低于本机 `config/local.json` 的 `requestTimeoutSeconds`。

## 服务端统一能力

当前默认生产链为：

```text
本地媒体
→ FFmpeg 规范化（所有媒体统一为 16 kHz 单声道 WAV）
→ FSMN-VAD
→ SenseVoiceSmall
→ CT-Transformer 标点恢复
→ 稳定 JSON
```

并发治理位于服务端。CLI 与直接 HTTP 调用共用同一队列；调用方不需要自行实现互斥锁。

`/health` 会返回模型、设备、VAD、标点、FFmpeg 与队列状态，Agent 可先据此判断服务是否可用。

## 时间轴说明

`segments` 优先使用 FunASR 的句级时间信息。SenseVoice 缺少可精确对齐标点的词级时间戳时，FunASR 会退回真实 VAD 语音段；本项目不会再使用“按字符比例估算时间”的伪时间轴。

因此：

- `text` 始终是优先给阅读、摘要和 LLM 使用的完整可读文本；
- `segments` 的起止时间来自真实语音活动边界；
- 某些 VAD 段内部的标点粒度可能低于顶层 `text`，但不会伪造更细的时间位置。

## 上游项目职责

上游只负责取得本地媒体和业务后处理，例如：

```text
视频来源 → 本地媒体 → local-ASR-service → transcript → 笔记/摘要/业务流程
```

下载网页、Cookie、业务数据库、笔记模板等都不属于本服务职责。
