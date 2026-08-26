# local-ASR-service

**Windows-first local ASR gateway for Agents, Skills and automation.**

`local-ASR-service` 是一个本机共享语音转文字服务。它把 FFmpeg、FSMN-VAD、SenseVoiceSmall、标点恢复、Queue 和稳定 API 封装在一个项目里，让其它 Agent / Skill / 脚本只负责“把本地媒体交给它”。

```text
Agent / Skill / Tool
        ↓
local-ASR-service
        ↓
FFmpeg → FSMN-VAD → SenseVoiceSmall → CT-Transformer
        ↓
text / raw_text / segments / TXT / SRT
```

默认只监听 `127.0.0.1:8001`，当前公开版以 **Windows + CPU** 为主要使用方式。

---

## 第一次使用：推荐让 Agent 帮你安装

**推荐使用 Codex、Claude Code、WorkBuddy、Hermes 或其它可以操作本地终端的 Agent 完成安装。**

不推荐手工逐个安装 Python 包，也不需要把开发者电脑已经安装好的 `.venv` 或模型上传到 GitHub。

仓库只提供源码、安装脚本、示例配置和文档。每个用户在自己的机器上运行自动安装脚本，生成自己的环境和模型缓存。

完整教程：**[安装教程](docs/INSTALL.md)**

如果已经把仓库克隆到本地，可以直接把下面这段发给 Agent：

```text
请阅读 README.md 和 docs/INSTALL.md，然后帮我安装并验证 local-ASR-service。
优先使用项目自带的 scripts/install-cpu.ps1，不要手工逐个 pip install。
检查 Python 3.11 和 FFmpeg；缺少时先补齐系统前置条件。
安装后启动服务，执行 health-check.ps1 -WaitSeconds 120，并完成一次可用性测试。
不要提交 .venv、models、runtime、logs、input、output、backups 或 config/local.json。
默认按 CPU 方案安装，不要擅自切换 GPU。
```

---

# 快速上手

## 1. 自动安装 CPU 环境

在仓库根目录运行：

```powershell
.\scripts\install-cpu.ps1
```

这个脚本会自动：

- 检查 Python 3.11；
- 创建或复用 `.venv-cpu`；
- 安装 CPU PyTorch / torchaudio；
- 安装 `requirements-cpu.txt`；
- 首次创建 `config/local.json`；
- 检查 FFmpeg；
- 验证主要 Python 依赖。

> Python 3.11 和 FFmpeg 属于系统前置条件。如果缺少，推荐让 Agent 帮你安装，然后再运行本脚本。

## 2. 启动服务

```powershell
.\scripts\start-server.ps1
.\scripts\health-check.ps1 -WaitSeconds 120
```

第一次启动可能需要下载并加载 SenseVoiceSmall、FSMN-VAD 和 CT-Transformer。

CPU 冷启动需要时间。开发机实测约 60–70 秒，因此推荐使用 `-WaitSeconds 120` 等待服务真正就绪。

正常状态类似：

```text
Status       : ok
Service      : local-ASR-service
Device       : cpu
Model        : SenseVoiceSmall
Vad          : True
Punctuation  : True
QueueRunning : 0
QueueWaiting : 0
Ffmpeg       : True
BaseUrl      : http://127.0.0.1:8001
```

## 3. 转写一个文件

```powershell
.\bin\asr.cmd transcribe "C:\media\demo.mp4"
```

支持：

```text
WAV / MP3 / FLAC / M4A / OGG / WebM / MP4 / MOV / MKV
```

返回 JSON 中最常用的是：

- `text`：带标点的完整可读文本；
- `raw_text`：标点恢复前的 ASR 文本；
- `segments`：带真实 VAD 时间轴的文本段；
- `segments_punctuated`：这些时间段是否已安全回写标点。

## 4. 直接生成 TXT / SRT

```powershell
.\scripts\transcribe-file.ps1 "C:\media\demo.mp4"
```

默认会在媒体文件旁创建：

```text
ASR_Output/
├─ demo_sensevoice-small_CPU.txt
└─ demo_sensevoice-small_CPU.srt
```

## 5. 停止服务

```powershell
.\scripts\stop-server.ps1
```

---

# 给其它 Agent / Skill 使用

这个项目最适合被其它自动化项目当作共享基础设施。

上游项目不应该重新实现：

- FunASR 安装；
- ASR 模型加载；
- FFmpeg 音频规范化；
- VAD；
- 标点模型；
- 并发 Queue；
- SRT 时间轴处理。

最简单的接入要求：

```text
需要本地语音转文字时，优先调用 local-ASR-service。
先检查 http://127.0.0.1:8001/health。
服务可用后，通过项目 CLI 或 /v1/audio/transcriptions 提交本地媒体。
不要在当前业务项目中再安装另一套 ASR Pipeline。
```

详细接入教程：**[Agent / Skill 接入教程](docs/integration.md)**

---

# HTTP API

如果调用方不是 PowerShell，也可以直接使用 HTTP：

```text
GET  /health
GET  /v1/models
POST /v1/audio/transcriptions
```

示例：

```powershell
curl.exe -X POST http://127.0.0.1:8001/v1/audio/transcriptions `
  -F "file=@C:\media\demo.mp4" `
  -F "model=custom" `
  -F "language=zh" `
  -F "response_format=verbose_json"
```

返回示例：

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
      "end": 3.2,
      "text": "与真实 VAD 时间段对应的可读文本。"
    }
  ],
  "segments_punctuated": true
}
```

默认上传以 4 MiB 分块写入 `runtime/temp`，默认单文件上限 2 GiB；请求完成后临时上传文件和规范化 WAV 会被清理。

---

# SRT 时间轴和标点是怎么处理的

`segments` 的 `start / end` 来自真实 FSMN-VAD 语音边界。

项目不会为了生成更漂亮的字幕而按字符数量伪造细时间轴。

当 SenseVoice 返回的 VAD 段没有标点时，服务会尝试把顶层 `text` 的标点安全投影回每个原始 VAD 段：

```text
完整带标点 text
→ 去除标点后与所有 VAD 段逐字核对（拉丁字母大小写无关）
→ 完全匹配
→ 只回写标点
→ start / end 不变
```

成功：

```json
"segments_punctuated": true
```

无法可靠对齐：

```json
"segments_punctuated": false
```

此时保留原始 VAD 文本，不猜测。

---

# Queue 怎么工作

并发控制位于 Server。

CLI 与直接 HTTP 请求都会经过同一个单任务 Queue，因此每个上游 Agent 不需要再实现一套客户端 Mutex。

运行中可以从 `/health` 看到：

```json
{
  "queue": {
    "running": 1,
    "waiting": 1
  }
}
```

开发者可使用：

```powershell
.\scripts\queue-smoke-test.ps1
```

验证两个客户端确实共用 Server Queue。

---

# 已验证的长视频

2026-08-26 完成一次真实长媒体 CPU 测试：

| 项目 | 实测结果 |
|---|---:|
| 视频时长 | 52 分 02 秒 |
| 文件大小 | 354 MiB |
| CPU 转写耗时 | 4 分 55 秒 |
| 处理速度 | 约 10.6× 实时 |
| TXT | 18,072 字符，UTF-8，带标点 |
| SRT | 890 个真实 VAD 时间段 |
| 临时文件 | 完成后已清理 |
| Queue | 完成后恢复空闲 |

这是单台机器的实际测试数据，不代表其它 CPU、媒体编码和内容类型会获得相同速度。

---

# GitHub 仓库会包含什么

会提交：

```text
service/
scripts/
bin/
config/local.example.json
docs/
tests/
requirements-cpu.txt
README.md
LICENSE
THIRD_PARTY.md
```

不会提交：

```text
.venv*/
models/
runtime/
logs/
input/
output/
backups/
config/local.json
```

因此：

- 开发者机器已经安装好的 `.venv-cpu` **不会上传**；
- 已下载的 SenseVoice / VAD / punctuation 模型 **不会上传**；
- 用户媒体、日志、测试结果 **不会上传**；
- 每个用户都在自己的机器运行安装脚本建立环境。

这也是推荐 Agent 安装而不是分发“整套现成环境”的原因。

---

# 测试和故障排查

基础测试：

```powershell
.\scripts\smoke-test.ps1
```

Queue 测试：

```powershell
.\scripts\queue-smoke-test.ps1
```

字幕标点映射测试：

```powershell
.\.venv-cpu\Scripts\python.exe .\tests\test_segment_punctuation.py
```

发布隐私检查：

```powershell
.\scripts\release-audit.ps1
```

遇到安装问题时，优先把报错交给 Agent 分析，不建议用户根据网络搜索结果随意替换 PyTorch、FunASR 或模型版本。

---

# 项目边界

这个服务只负责：

```text
本地媒体 → ASR → 可消费 transcript
```

它不负责：

- B 站 / YouTube 下载；
- 网页解析；
- Cookie；
- 笔记模板；
- 业务数据库；
- 用户系统；
- 公网部署所需的鉴权 / TLS / 安全网关。

上游项目只需要先取得本地媒体，再调用本服务。

---

# 文档导航

- **[安装教程](docs/INSTALL.md)**：第一次安装、Agent 自动安装、升级与常见问题；
- **[接入教程](docs/integration.md)**：让其它 Agent / Skill / 脚本调用本服务；
- **[第三方组件说明](THIRD_PARTY.md)**：FunASR 与默认模型许可证边界；
- **[验证报告](deployment-report.md)**：当前版本已完成的工程验证。

---

# License

本项目自有代码与文档采用 [MIT License](LICENSE)。

FunASR 和预训练模型属于第三方组件，许可证由各自上游项目决定。本仓库不重新分发模型权重，详情见 [THIRD_PARTY.md](THIRD_PARTY.md)。
