# local-ASR-service 安装教程

这份教程面向第一次使用 `local-ASR-service` 的用户。

## 最推荐的安装方式：交给 Agent

**推荐使用 Codex、Claude Code、WorkBuddy、Hermes 或其它具备本地终端权限的 Agent 完成安装。**

原因很简单：这个项目本身已经提供自动安装脚本，用户没有必要手工创建虚拟环境、逐个安装 Python 包、查模型目录或处理依赖冲突。Agent 只需要负责检查系统前置条件，然后运行项目提供的脚本并完成验收。

不推荐照着网上教程逐条执行 `pip install`。手工安装最容易出现 Python 版本、CPU/GPU PyTorch、FFmpeg PATH 和模型缓存位置不一致的问题。

### 可以直接复制给 Agent 的安装任务

把仓库克隆到本机后，将下面这段内容发给 Agent：

```text
请帮我安装并验证当前 local-ASR-service 项目。

要求：
1. 先阅读 README.md 和 docs/INSTALL.md，按项目现有设计执行，不要另起一套 ASR 环境。
2. 当前公开版以 Windows + CPU 为默认方案，不要擅自改成 GPU。
3. 检查 Python 3.11 和 FFmpeg。缺少时可以使用当前机器可用的正常安装方式补齐，并确保 ffmpeg.exe 可以被系统找到。
4. 不要手工逐个安装项目 Python 依赖，优先运行：
   .\scripts\install-cpu.ps1
5. 安装完成后启动服务：
   .\scripts\start-server.ps1
6. 等待模型加载并检查：
   .\scripts\health-check.ps1 -WaitSeconds 120
7. 如果项目内存在可用测试媒体，再运行：
   .\scripts\smoke-test.ps1
8. 最后告诉我：Python 版本、FunASR 是否可用、FFmpeg 是否可用、服务地址、health 结果，以及是否完成测试。

重要边界：
- 不要把 .venv、models、runtime、logs、input、output、backups 或 config/local.json 提交到 Git。
- 不要修改项目业务代码，除非现有安装流程确实报错；如果报错，先分析原因再决定是否需要修改。
- 不要下载或复制另一套重复的 ASR 项目。
```

如果 Agent 可以访问整个仓库，这通常就是最省事的安装方式。

---

## 安装前需要什么

公开 CPU 方案主要面向：

- Windows 10 / 11；
- Python 3.11；
- FFmpeg；
- 可正常访问 Python / PyTorch / ModelScope 下载源的网络；
- 足够的磁盘空间保存 Python 环境与模型。

GPU **不是必需条件**。默认教程只介绍 CPU 方案。

### 为什么固定 Python 3.11

当前项目是在 Python 3.11 环境完成主要验证的。安装脚本会检查版本，避免在其它 Python 大版本上生成一个表面能安装、实际运行不稳定的环境。

### FFmpeg 做什么

服务接收到 MP4、MOV、MKV、MP3 等媒体后，会统一通过 FFmpeg 规范化为 16 kHz 单声道 WAV，再交给 ASR Pipeline。

因此 FFmpeg 属于系统前置依赖，不建议绕过。

---

## 仓库里不会包含什么

GitHub 仓库只应该保存：

- 项目源码；
- PowerShell / CMD 工具脚本；
- 示例配置；
- requirements；
- 测试代码；
- 文档。

下面这些内容是**每台机器本地生成或下载的运行数据，不应该上传 GitHub**：

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

这意味着：开发者电脑上已经安装好的 Python 环境和已经下载好的模型，不会随仓库一起发布。

新用户 clone 后，由安装脚本和首次启动流程在自己的电脑上建立这些内容。

---

## 自动安装流程

如果不用 Agent，也不要手工逐个装包。最简方式是在仓库根目录打开 PowerShell，然后只执行：

```powershell
.\scripts\install-cpu.ps1
```

脚本会自动完成项目内部的 Python 环境准备：

1. 检查 Python 3.11；
2. 创建或复用 `.venv-cpu`；
3. 安装 CPU 版 PyTorch / torchaudio；
4. 安装 `requirements-cpu.txt` 中的服务依赖；
5. 首次安装时从 `config/local.example.json` 创建本机 `config/local.json`；
6. 检查 FFmpeg 是否能被找到；
7. 验证主要 Python 依赖是否可以正常导入。

### 安装脚本不会做什么

它不会：

- 上传任何本地文件；
- 把模型写入 Git；
- 修改你的业务项目；
- 自动切换到 GPU；
- 覆盖已经存在的 `config/local.json`；
- 删除已经存在的 `.venv-cpu`。

如果 Python 3.11 或 FFmpeg 本身不存在，推荐让 Agent 帮你补齐系统前置条件，再重新运行安装脚本。

---

## 第一次启动

安装完成后执行：

```powershell
.\scripts\start-server.ps1
```

然后等待服务真正完成模型加载：

```powershell
.\scripts\health-check.ps1 -WaitSeconds 120
```

第一次启动可能需要下载：

- SenseVoiceSmall；
- FSMN-VAD；
- CT-Transformer punctuation。

它们会进入本机项目的模型缓存，不进入 Git。

模型已经存在时，之后启动会直接使用本地文件。

### 为什么要等待 120 秒

CPU 冷启动需要把三个模型加载进内存。开发机实测约需 60–70 秒，因此不要在刚执行 `start-server.ps1` 后立刻把“端口还没打开”判断成启动失败。

当健康检查成功时，你应该看到类似：

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

---

## 做一次测试

如果仓库里已经准备了本地测试媒体，可以运行：

```powershell
.\scripts\smoke-test.ps1
```

或者直接用自己的媒体：

```powershell
.\bin\asr.cmd transcribe "C:\media\demo.mp4"
```

需要输出 TXT / SRT：

```powershell
.\scripts\transcribe-file.ps1 "C:\media\demo.mp4"
```

默认会在媒体文件旁创建 `ASR_Output` 文件夹。

---

## 日常使用

启动：

```powershell
.\scripts\start-server.ps1
.\scripts\health-check.ps1 -WaitSeconds 120
```

检查：

```powershell
.\bin\asr.cmd health
```

转写：

```powershell
.\bin\asr.cmd transcribe "C:\media\demo.mp4"
```

停止：

```powershell
.\scripts\stop-server.ps1
```

---

## 给其它 Agent / Skill 使用

当服务已经运行，上游 Agent 不需要知道 FunASR、模型目录或虚拟环境。

最简单的要求可以写成：

```text
需要把本地音频或视频转成文字时，优先调用 local-ASR-service。
先检查 http://127.0.0.1:8001/health。
服务可用时，通过项目 CLI 或 /v1/audio/transcriptions 提交本地媒体。
不要在当前业务项目里重新安装 ASR 模型、FFmpeg Pipeline 或另一套 FunASR。
```

更完整的接入方式见 [integration.md](integration.md)。

---

## 常见问题

### 1. `Python 3.11 is required`

说明当前机器没有可用的 Python 3.11。

推荐：让 Agent 安装 Python 3.11，然后重新运行 `install-cpu.ps1`。

### 2. `FFmpeg was not found`

说明 `ffmpeg.exe` 没有安装，或者没有加入可被 PowerShell 找到的位置。

推荐：让 Agent 检查并安装 FFmpeg，然后重新启动服务。

### 3. 第一次启动很慢

首次启动可能同时涉及模型下载与模型加载，属于正常现象。先使用：

```powershell
.\scripts\health-check.ps1 -WaitSeconds 120
```

如果网络较慢，模型第一次下载可能需要更久。

### 4. 模型会不会上传 GitHub

不会。

`models/` 已被 `.gitignore` 排除。模型只存在于用户自己的本地机器。

### 5. `.venv-cpu` 要不要提交

不要。

每个用户都应该在自己的机器运行 `install-cpu.ps1` 创建环境。

### 6. 可以自己手工安装所有依赖吗

可以，但**不推荐**。

项目已经提供自动安装脚本，手工安装只会增加 Python、PyTorch 和依赖版本不一致的概率。

### 7. 是否推荐 GPU

当前公开教程默认推荐 CPU。GPU 路径保留，但不是当前 Public Beta 的主要验证目标。

---

## 升级项目时

更新源码后，通常先重新执行：

```powershell
.\scripts\install-cpu.ps1
```

脚本会复用现有 `.venv-cpu` 并同步 requirements，而不会主动删除模型或本机配置。

然后重启服务：

```powershell
.\scripts\stop-server.ps1
.\scripts\start-server.ps1
.\scripts\health-check.ps1 -WaitSeconds 120
```

如果发布说明没有明确要求，不需要删除模型重新下载。

---

## 推荐原则

对于普通用户，推荐流程始终是：

```text
Clone 仓库
→ 把安装任务交给 Agent
→ Agent 检查 Python 3.11 / FFmpeg
→ 运行 install-cpu.ps1
→ start-server.ps1
→ health-check.ps1
→ 开始使用
```

用户应该使用这个项目，而不是学习如何手工拼装一套 FunASR 环境。
