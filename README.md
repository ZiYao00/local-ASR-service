# local-ASR-service

本机共享语音转文字基础服务。上游 Agent、Skill 或业务项目只提交本地媒体，即可获得稳定 JSON 转录结果；无需了解 FunASR 模型目录、Python 环境、VAD、标点模型或并发控制。

当前默认生产链：

```text
本地媒体
→ FFmpeg 规范化（所有媒体统一为 16 kHz 单声道 WAV）
→ FSMN-VAD
→ SenseVoiceSmall
→ CT-Transformer 标点恢复
→ JSON / TXT / SRT
```

服务默认监听 `127.0.0.1:8001`，CPU-first。Qwen3-ASR-0.6B 继续保留为离线对比候选，不参与默认共享路由。

## 边界

服务负责：

- 本地音频/视频输入；
- 媒体规范化；
- VAD 长音频切分；
- SenseVoiceSmall 转写；
- 中文标点恢复；
- 服务端串行队列；
- 稳定 JSON，以及可选 TXT/SRT 输出。

服务不负责下载视频、网页解析、Cookie、业务笔记、数据库或用户系统。

## 首次配置

从示例创建不提交 Git 的机器配置：

```powershell
Copy-Item .\config\local.example.json .\config\local.json
```

`config/local.example.json` 默认将 SenseVoice 与 FSMN-VAD 指向项目内本地模型，标点模型使用 `ct-punc` 别名。首次加载时 FunASR 会将官方 CT-Transformer 下载到项目的 ModelScope 缓存；之后可像当前机器一样把 `puncModel` 改为实际本地模型路径，实现完全本地加载。

当前机器的 `config/local.json` 已指向项目内的 SenseVoice、FSMN-VAD 和 CT-Transformer 模型。服务不会使用项目外的模型、缓存、临时目录或输出目录。

## 启动与停止

默认 CPU：

```powershell
.\scripts\start-server.ps1
.\scripts\health-check.ps1
```

显式 GPU：

```powershell
.\scripts\start-server-gpu.ps1
```

停止：

```powershell
.\scripts\stop-server.ps1
```

默认入口不会自动切到 GPU；显式 GPU 启动失败时也不会修改 CPU 配置。

## HTTP API

```text
GET  /health
GET  /v1/models
POST /v1/audio/transcriptions
```

提交示例：

```powershell
curl.exe -X POST http://127.0.0.1:8001/v1/audio/transcriptions `
  -F "file=@.\sample.wav" `
  -F "model=custom" `
  -F "language=zh" `
 -F "response_format=verbose_json"
```

上传以 4 MiB 分块写入项目 `runtime/temp`，不会把整个视频读入内存；默认单文件上限 2 GiB。默认请求与排队等待上限均为 3 小时，可在不提交 Git 的 `config/local.json` 中按实际硬件调整。

返回结构：

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
      "text": "与该语音时间段对应的文本。"
    }
  ]
}
```

业务默认使用 `text`。`raw_text` 用于模型对比和调试。

## 时间轴说明

当前服务不再使用按字符数量比例估算出来的伪时间轴。

SenseVoice 能与标点结果精确对齐时，`segments` 使用句级时间信息；无法精确对齐时，FunASR 退回真实 FSMN-VAD 语音段。因此 `segments` 的粒度可能较粗，但起止时间来自真实语音活动边界。

## 服务端 Queue

并发控制已移到服务端。CLI、HTTP 和文件输出工具最终都经过同一服务队列，不要求每个调用方自行实现互斥锁。

`/health` 会返回：

- `device`
- `model`
- `vad`
- `punctuation`
- `queue.running`
- `queue.waiting`
- `ffmpeg`

## CLI

```powershell
.\bin\asr.cmd health
.\bin\asr.cmd models
.\bin\asr.cmd transcribe .\sample.wav
```

CLI 只作为 HTTP 客户端，不加载模型、不维护独立 Queue。

## TXT / SRT

```powershell
.\scripts\transcribe-file.ps1 "D:\Video\demo.mp4"
```

默认输出到媒体同级 `ASR_Output`；`-UseProjectOutput` 时输出到项目 `output`。脚本不再重复实现 FFmpeg/ASR 请求链，而是消费统一服务返回结果。

## 验证

短样本端到端：

```powershell
.\scripts\smoke-test.ps1
```

验收重点包括：服务健康、VAD、标点、`raw_text`、时长和 segments。

30–60 分钟长音频属于下一阶段压力验收项目，不应以短样本结果替代。

## 仓库边界

`config/local.json`、模型、虚拟环境、缓存、日志、临时文件、测试媒体、生成结果和备份均不提交 Git。

不要提交：

- `.venv*`
- `models/`
- `runtime/`
- `logs/`
- `input/`
- `output/`
- `backups/`
- `config/local.json`

其它项目接入约定见 [docs/integration.md](docs/integration.md)。
