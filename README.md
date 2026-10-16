# local-ASR-service

**给 Windows 本地 Agent、Skill 与自动化提供共享 ASR / 字幕对齐的 HTTP + CLI 服务。**

- 普通转写：SenseVoiceSmall + FSMN-VAD + CT-Transformer 标点；输出文本、真实 VAD 时间段、TXT/SRT。
- 已有准确口播稿：可选 Qwen3 Forced Aligner，生成字/词级时间戳和剪辑字幕（适用于约 5 分钟以内单人口播）。
- 默认本机 CPU、`127.0.0.1:8001`；同一服务端 Queue 供多个 Agent 共享。
- **项目准备自己的 FFmpeg / ffprobe，不需要系统安装或 PATH 配置。**
- **源码仓库与发布包都不包含模型权重。** 首次安装自动下载基础模型；显式启用字幕对齐时才下载可选 Qwen3 模型；支持手动下载。

> 推荐 Windows 10/11 x64、Python 3.11。当前为 v0.5.0-beta 测试版本；完整的新机器首次联网安装尚未完成端到端验收。下载依赖及模型需要互联网连接和磁盘空间。

## 让 Agent 安装（推荐）

Clone 仓库后，把下面任务发给具备本地工作区和终端权限的 Agent：

```text
请阅读当前 local-ASR-service 仓库的 AGENTS.md 与 docs/INSTALL.md，
在 Windows 本机按 CPU 默认模式完成安装和验收：
1. 检查 Python 3.11 与磁盘空间；系统前置依赖如缺失，先报告并取得安装授权。
2. 优先执行项目 scripts/install-cpu.ps1，复用现有环境与模型，
   准备项目内置 FFmpeg、基础三模型，不要安装全局 FFmpeg。
3. service.bat start，然后 health-check.ps1 -WaitSeconds 120。
4. 运行 scripts/smoke-test.ps1，必须有一次实际语音转写成功才能报告安装完成。
5. 报告执行结果、服务地址、模型状态、失败项；不修改其他项目，
   不提交模型/缓存/私有配置，不擅自 Git commit/push。
无需默认安装 Qwen3 可选字幕对齐环境。
```

完整说明：[安装与手动下载教程](docs/INSTALL.md)。

## 手动快速开始

在项目根目录的 Windows PowerShell 中执行（前提：Python 3.11 已安装）：

```powershell
.\scripts\install-cpu.ps1
.\service.bat start
.\scripts\health-check.ps1 -WaitSeconds 120
.\scripts\smoke-test.ps1
```

`install-cpu.ps1` 自动准备隔离 `.venv-cpu`、固定版本 CPU 依赖、项目内 FFmpeg/ffprobe，以及必要的 ModelScope 模型。首次网络下载会比后续启动慢。安装脚本不会覆盖已有 `config/local.json` 或删除现有模型。

日常使用：

```powershell
.\service.bat status
.\service.bat start
.\bin\asr.cmd transcribe "C:\media\example.mp4"
.\scripts\transcribe-file.ps1 "C:\media\example.mp4"
.\service.bat stop
```

默认将 TXT / SRT 输出到源媒体旁边的 `ASR_Output\`。如果需要自定义输出目录，参考 [Agent 接入说明](docs/integration.md)。服务可保持后台运行；如果不需要，正常停止后可释放模型进程资源。停止服务前先确认 Queue 空闲。

## 已有口播稿的精细字幕（可选）

只有需要精细字幕时才执行：

```powershell
.\scripts\install-aligner-cpu.ps1
.\service.bat start
.\scripts\align-subtitles.ps1 "C:\media\voice.mp3" "C:\media\script.txt" -Preset voiceover
```

首次安装对齐环境时会准备独立 Python 环境并下载官方 `Qwen/Qwen3-ForcedAligner-0.6B`。原有 Qwen3-ASR 对照实验模型只有主动运行实验脚本时才会准备。

## 下载与交付说明

- **Git clone 或 GitHub 的自动 Source ZIP：** 不附带 FFmpeg 二进制；`install-cpu.ps1` 自动下载校验并安装到 `tools/ffmpeg/bin/`。
- **正式 Windows Release ZIP：** 内置经过 SHA-256 校验的 LGPL FFmpeg/ffprobe、许可资料和安装脚本；解压即可开始项目依赖安装。
- **所有方式：** 均不附带 SenseVoice、VAD、标点、Qwen 权重、虚拟环境、用户媒体、日志及 `config/local.json`。
- 自动下载失败、离线搬运、手动安装见 [INSTALL.md](docs/INSTALL.md)。仅把模型权重文件拖入项目根目录并不能完成安装。

## HTTP API

```text
GET  http://127.0.0.1:8001/health
GET  http://127.0.0.1:8001/v1/models
POST http://127.0.0.1:8001/v1/audio/transcriptions
POST http://127.0.0.1:8001/v1/audio/alignments
```

模型加载需要时间。发起请求前确认 `/health.status == ok`，再检查 `vad`、`punctuation` 和 `ffmpeg`。HTTP 请求取消后模型任务不一定立即停止；不要在 Queue 忙碌时强制关机或重复安装。

## 文档

- [INSTALL.md](docs/INSTALL.md)：首次安装、自动/手动下载模型、离线导入、升级和修复。
- [integration.md](docs/integration.md)：Agent、Skill、HTTP/CLI 调用与输出归属。
- [AGENTS.md](AGENTS.md)：Agent 接手入口和工作范围。
- [THIRD_PARTY.md](THIRD_PARTY.md)：第三方源码、模型、FFmpeg 的许可证与出处。
- [deployment-report.md](deployment-report.md)：已有实测、当前回归与待验证事项。

## 许可证

本项目自有代码和文档采用 [MIT](LICENSE)。FFmpeg 与模型遵循各自上游许可，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。本项目**不是**公网 ASR 服务；不内置公网身份认证和 TLS。
