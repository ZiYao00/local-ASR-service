# local-ASR-service 接入教程

这份文档面向：

- Agent；
- Skill；
- 自动化脚本；
- 本地工具；
- 需要统一语音转文字能力的业务项目。

目标不是教上游项目如何实现 ASR，而是教它们**如何复用已经运行的 local-ASR-service**。

---

## 先理解一条原则

上游项目只负责：

```text
取得本地媒体
→ 调用 local-ASR-service
→ 使用 transcript
```

不要在每个业务项目里重复实现：

- FunASR 环境；
- SenseVoice 模型；
- FSMN-VAD；
- punctuation 模型；
- FFmpeg 规范化；
- Queue；
- SRT 时间轴映射。

这些都属于 `local-ASR-service` 的职责。

---

# 推荐接入方式

## 方案 A：Agent / Windows 工具优先使用 CLI

如果调用方本身就在 Windows 本机运行，最简单的是直接调用项目 CLI。

先检查服务：

```powershell
.\bin\asr.cmd health
```

转写：

```powershell
.\bin\asr.cmd transcribe "C:\media\demo.mp4"
```

CLI 输出就是稳定 JSON，可以直接交给上游 Agent 解析。

这种方式适合：

- Codex；
- WorkBuddy；
- Hermes；
- Claude Code；
- PowerShell 自动化；
- Windows 本地 Skill。

### 推荐给 Agent 的调用说明

可以把下面这段作为业务 Agent 的长期规则：

```text
当任务需要把本地音频或视频转成文字时，优先复用 local-ASR-service。

调用前先检查服务健康状态。
如果服务可用，使用 local-ASR-service 的 CLI 或 HTTP API，不要在当前项目里重新安装 FunASR、Whisper、FFmpeg Pipeline、VAD 或标点模型。

默认使用返回的 text 作为可读完整转录。
需要时间轴时读取 segments。
需要判断字幕段是否已经回写标点时读取 segments_punctuated。
raw_text 只用于调试、质量对比或需要原始 ASR 文本的场景。
```

---

## 方案 B：其它语言 / 程序使用 HTTP

服务默认地址：

```text
http://127.0.0.1:8001
```

接口：

```text
GET  /health
GET  /v1/models
POST /v1/audio/transcriptions
```

### 第一步：先检查健康状态

请求：

```text
GET http://127.0.0.1:8001/health
```

典型响应：

```json
{
  "status": "ok",
  "service": "local-ASR-service",
  "device": "cpu",
  "model": "SenseVoiceSmall",
  "vad": true,
  "punctuation": true,
  "queue": {
    "running": 0,
    "waiting": 0
  },
  "ffmpeg": true
}
```

上游至少应确认：

```text
status == ok
ffmpeg == true
vad == true
punctuation == true
```

如果服务未运行，不建议业务项目自己临时启动另一套 ASR；应该启动 `local-ASR-service` 本身。

---

# 提交一个媒体文件

multipart 请求：

```text
POST http://127.0.0.1:8001/v1/audio/transcriptions
```

字段：

```text
file=<本地媒体文件>
model=custom
language=zh
response_format=verbose_json
```

PowerShell 示例：

```powershell
curl.exe -X POST http://127.0.0.1:8001/v1/audio/transcriptions `
  -F "file=@C:\media\demo.mp4" `
  -F "model=custom" `
  -F "language=zh" `
  -F "response_format=verbose_json"
```

支持媒体：

```text
WAV
MP3
FLAC
M4A
OGG
WebM
MP4
MOV
MKV
```

调用方不需要先手工抽取音轨。服务会统一调用 FFmpeg 规范化媒体。

---

# 如何使用返回结果

典型响应：

```json
{
  "status": "ok",
  "text": "这是恢复标点后的完整可读文本。",
  "raw_text": "这是恢复标点前的完整原始文本",
  "language": "zh",
  "duration": 17.972,
  "model": "SenseVoiceSmall",
  "segments": [
    {
      "start": 0.0,
      "end": 3.2,
      "text": "这是第一个带真实时间轴的文本段。"
    }
  ],
  "segments_punctuated": true
}
```

## 普通摘要 / 笔记 / LLM 处理

直接使用：

```text
text
```

这是默认推荐字段。

## 需要 SRT / 时间轴

使用：

```text
segments
```

每个 segment 包含：

```text
start
end
text
```

## 需要判断字幕是否有标点

检查：

```text
segments_punctuated
```

含义：

- `true`：segment 文本已安全回写标点；
- `false`：服务无法保证标点与原始 VAD 文本完全对齐，因此保留了原文本。拉丁字母大小写差异不会单独导致对齐失败。

## 调试 ASR 原始文本

使用：

```text
raw_text
```

业务默认不需要使用这个字段。

---

# 为什么 segments 的时间轴可信

服务不会按文本长度平均分配时间。

`segments.start / end` 来自 FunASR / FSMN-VAD 的真实语音边界。

当顶层 `text` 有标点，而 VAD segment 本身没有标点时，服务只做：

```text
核对主体文字
→ 完整一一匹配
→ 把标点投影回原 segment
→ 时间戳完全不动
```

无法完整对齐就返回：

```json
"segments_punctuated": false
```

不会为了字幕更好看而伪造新的时间位置。

---

# 并发时怎么处理

调用方**不需要自己排队**。

Server 内部只有一个转写执行位：

```text
请求 A → running
请求 B → waiting
请求 C → waiting
```

可以从 `/health` 查看：

```json
{
  "queue": {
    "running": 1,
    "waiting": 2
  }
}
```

所以多个 Agent 可以共享同一个服务，而不用每个 Agent 再写一套 Mutex。

---

# 长视频调用注意事项

服务支持长媒体分块上传。

默认：

- 上传按 4 MiB 分块写入 `runtime/temp`；
- 不会把整个视频一次性读入服务进程内存；
- 默认单文件上限 2 GiB；
- 默认请求 / Queue 等待上限为 3 小时；
- 请求结束后会清理上传临时文件和规范化 WAV。

已完成一条 52 分 02 秒、354 MiB 视频的真实 CPU 验证。

因此上游不需要因为媒体较长而自行切成很多小文件，除非业务本身有其它原因需要切分。

---

# 推荐的 Agent 接入流程

一个业务 Agent 在需要 ASR 时，推荐这样做：

```text
1. 判断输入是否已经是本地媒体文件
2. GET /health 或调用 asr.cmd health
3. 如果服务健康：提交媒体
4. 等待 Queue / 转写完成
5. 普通业务使用 text
6. 字幕业务使用 segments
7. 完成后继续自己的笔记 / 摘要 / 分析流程
```

不要这样做：

```text
业务 Agent
→ 发现需要 ASR
→ pip install FunASR
→ 再下载一套模型
→ 自己写 FFmpeg
→ 自己写 Queue
```

`local-ASR-service` 存在的目的就是避免每个项目重复造这部分。

---

# 如果服务没有启动

推荐由 Agent 启动本项目：

```powershell
.\scripts\start-server.ps1
.\scripts\health-check.ps1 -WaitSeconds 120
```

如果机器还没有安装环境，先按：

**[安装教程](INSTALL.md)**

处理。

上游业务项目不应该在自己的目录里另建 `.venv` 来补救 ASR 服务未安装的问题。

---

# 生成 TXT / SRT 的最简单方式

如果调用方只是想得到文件，而不是自己处理 JSON：

```powershell
.\scripts\transcribe-file.ps1 "C:\media\demo.mp4"
```

默认输出：

```text
媒体所在目录/
└─ ASR_Output/
   ├─ demo_sensevoice-small_CPU.txt
   └─ demo_sensevoice-small_CPU.srt
```

这适合：

- 人工字幕；
- Obsidian 笔记流程；
- 后续 LLM 总结；
- 其它只接受文件输入的工具。

---

# 故障诊断顺序

Agent 遇到问题时，推荐按这个顺序排查：

## 1. 服务是否存在

```powershell
.\bin\asr.cmd health
```

## 2. FFmpeg 是否可用

看 `/health`：

```json
"ffmpeg": true
```

## 3. 模型能力是否正常

```json
"vad": true,
"punctuation": true
```

## 4. Queue 是否只是正在等待

```json
"queue": {
  "running": 1,
  "waiting": 1
}
```

`waiting > 0` 不等于故障，可能只是前面已经有转写任务。

## 5. 再查看项目日志

只有服务本身异常时，才需要进入 `logs/` 检查错误。

不要第一反应就在业务项目里重新装依赖。

---

# 上游职责边界

`local-ASR-service` 不负责：

- B 站 / YouTube 下载；
- Cookie；
- 网页解析；
- 业务数据库；
- 笔记模板；
- LLM 摘要；
- 用户系统；
- 公网鉴权。

典型业务架构应该是：

```text
B站 / 本地视频 / 其它来源
        ↓
业务项目取得本地媒体
        ↓
local-ASR-service
        ↓
transcript
        ↓
笔记 / 摘要 / 搜索 / LLM / 业务处理
```

这样 ASR 才真正成为多个项目可以共享的基础组件。
