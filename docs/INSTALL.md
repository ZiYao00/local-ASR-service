# local-ASR-service 安装教程（Windows x64 / Agent 优先）

这份文档是安装与恢复操作的权威入口。项目依赖 Windows 10/11、Python 3.11、可访问 Python/PyTorch/模型来源的网络、足够的磁盘空间。**FFmpeg/ffprobe 由项目准备，用户不需要另行安装 FFmpeg 或修改系统 PATH。**

## 0. 在开始前

- 安装、下载、首次启动属于可能持续较久的操作。Agent 应确认用户已授权安装与网络下载；若 Python 3.11 尚未安装，应明确告知并获得系统级安装授权。
- 优先在 Windows PowerShell 5.1 或更新版本执行。项目使用独立 `.venv-cpu`，不改变其他 Agent 的 Python 环境。
- 机器已有服务时先检查 `service.bat status`；不要因为 API 暂时没有响应就重复安装、强制停止其他监听进程。
- 不运行 GPU 安装，除非用户明确要求。模型缓存及运行数据绝不进入 Git。

## 1. 最简安装（基础 ASR）

仓库根目录：

```powershell
.\scripts\install-cpu.ps1
.\service.bat start
.\scripts\health-check.ps1 -WaitSeconds 120
.\scripts\smoke-test.ps1
```

`install-cpu.ps1` 按顺序：检查 Python 3.11 → 创建/复用 `.venv-cpu` → 安装已验证的 CPU PyTorch 和项目依赖 → 准备本地 FFmpeg/ffprobe → 下载或复用 SenseVoiceSmall / FSMN-VAD / CT-Transformer → `pip check`。

**三个独立成功标准：** 安装依赖成功、健康检查就绪、提交真实音频转写成功。仅执行完 `pip install` 不能宣称 ASR 部署完成。

首个模型下载可能超过 120 秒；安装流程负责完成下载，随后服务启动的等待时间才以 120 秒为默认值。失败时检查准确的下载错误，不要重复启动或清空缓存。

新仓库不包含私有 `input/test1.mp4`。`smoke-test.ps1` 默认尝试用 Windows 自带的语音合成生成小型英文语音样本进行真实识别；如果系统缺少语音合成组件，请使用：

```powershell
.\scripts\smoke-test.ps1 -InputPath "C:\media\short-voice.wav"
```

### 无副作用的安装检查（推荐 Agent 日常使用）

如果机器已经安装过本项目，只检查现有环境而不重新运行 pip：

```powershell
.\scripts\install-cpu.ps1 -VerifyOnly
.\scripts\install-aligner-cpu.ps1 -VerifyOnly
```

第二条只适用于已经显式安装了 Forced Aligner 的机器，普通转写用户无需运行。该模式只校验现有 Python、依赖、模型与项目内 FFmpeg，不会联网下载或修改运行环境。

## 2. FFmpeg 内置与恢复

正常安装不需要系统 FFmpeg。实际执行文件由固定 manifest `config/ffmpeg-distribution.json` 管理：

```text
tools/ffmpeg/bin/ffmpeg.exe
tools/ffmpeg/bin/ffprobe.exe
tools/ffmpeg/distribution.json
tools/ffmpeg/licenses/LICENSE.txt
```

源码库不提交 EXE。首次安装从固定 BtbN Windows x64 LGPL 构建下载 ZIP，经 SHA-256 校验后提取必要文件。项目内完整性检查：

```powershell
.\scripts\prepare-ffmpeg.ps1 -Mode verify
```

下载失败可再次执行 `prepare-ffmpeg.ps1 -Mode prepare`；下载的归档缓存位于被 Git 忽略的 `runtime/downloads/`。校验失败时不会使用不可信的二进制。若下载中断留下 `.partial`，先检查该文件，再由 Agent 在授权范围内处理恢复；不要擅自以系统 PATH 中的未知 EXE 替代。

正式 Windows Release ZIP 已附带 FFmpeg/ffprobe，因此无需联网下载此组件。源码 ZIP 和普通 clone 需要先运行准备脚本。发行版本、许可证及构建来源见 [THIRD_PARTY.md](../THIRD_PARTY.md)。

## 3. 模型如何下载

**仓库与 ZIP 都不包含任何模型权重。** 基础模型在首次执行 `install-cpu.ps1` 时自动下载至本地 ModelScope 缓存 `models/modelscope/`，以后重用。三个模型为：

| 用途 | 模型 ID |
|---|---|
| 识别 | `iic/SenseVoiceSmall` |
| VAD | `iic/speech_fsmn_vad_zh-cn-16k-common-pytorch` |
| 标点 | `iic/punc_ct-transformer_cn-en-common-vocab471067-large` |

需要重新准备或验证缓存时：

```powershell
.\scripts\prepare-models.ps1 -Mode base
.\scripts\prepare-models.ps1 -Mode base -Offline
```

第二条只读取已有快照，不联网。自动模式尽量复用现有缓存；安装中断保留缓存，修复网络后再次执行准备脚本。

### 手动下载三个基础模型

下载模型的官方页面：

- https://modelscope.cn/models/iic/SenseVoiceSmall
- https://modelscope.cn/models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch
- https://modelscope.cn/models/iic/punc_ct-transformer_cn-en-common-vocab471067-large

建议在项目已有 `.venv-cpu` 中运行 SDK，而不是逐个下载不完整的权重：

```powershell
.\.venv-cpu\Scripts\python.exe -c "from modelscope import snapshot_download; snapshot_download('iic/SenseVoiceSmall', local_dir=r'models\sensevoice-small')"
.\.venv-cpu\Scripts\python.exe -c "from modelscope import snapshot_download; snapshot_download('iic/speech_fsmn_vad_zh-cn-16k-common-pytorch', local_dir=r'models\fsmn-vad')"
.\.venv-cpu\Scripts\python.exe -c "from modelscope import snapshot_download; snapshot_download('iic/punc_ct-transformer_cn-en-common-vocab471067-large', local_dir=r'models\ct-punctuation')"
```

三份本地完整快照需要配套更新 `config/local.json` 中的：

```json
{
  "modelPath": "models\\sensevoice-small",
  "vadModel": "models\\fsmn-vad",
  "puncModel": "models\\ct-punctuation"
}
```

*这里只展示字段，不要用该片段覆盖整个配置文件。* 验证每个目录包含 `model.pt`，并运行 `prepare-models.ps1 -Mode base -Offline` 及实际转写确认可加载。

若从另一台机器迁移完整缓存，应保持相同缓存路径；**不要同时建立第二套重复模型**。

## 4. 可选：准确口播稿字幕对齐

只在需要此功能时运行：

```powershell
.\scripts\install-aligner-cpu.ps1
.\scripts\prepare-models.ps1 -Mode aligner -Offline
```

首次执行安装脚本会创建/复用 `.venv-qwen3-asr`、安装 `qwen-asr` 并下载 **Qwen/Qwen3-ForcedAligner-0.6B** 至 `models/qwen3-forced-aligner-0.6b/`。与普通 ASR 环境隔离；不在每次字幕对齐时联网。

手动下载安装（或联网受限时在其他机器准备并复制完整目录）：

模型页面：https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B

```powershell
.\.venv-qwen3-asr\Scripts\python.exe -c "from huggingface_hub import snapshot_download; snapshot_download('Qwen/Qwen3-ForcedAligner-0.6B', local_dir=r'models\qwen3-forced-aligner-0.6b')"
```

应包含 `model.safetensors`、`config.json`、`tokenizer_config.json`、`vocab.json`、`merges.txt`、`preprocessor_config.json` 等同一版本的配套文件，不能只复制一个权重文件。项目在复用 Qwen 缓存时检查必要文件、配置 JSON 与 SafeTensors 头部及文件长度；这是**截断/结构检查，不等同于整份模型的 SHA-256 校验**。若下载后仍不完整，脚本会保留已有数据并报告错误，不会擅自清空模型目录。完成后再检查 `forced_alignment.ready`，使用准确原稿和音频验证字幕对齐。

实验模型 `Qwen/Qwen3-ASR-0.6B` 不参与普通转写与 Forced Aligner；仅显式使用 `scripts/test-qwen3-asr.ps1` 时才准备，不属于默认安装。

## 5. 日常启动和 Agent 调度

```powershell
.\service.bat status
.\service.bat start
.\service.bat stop
.\service.bat restart
```

对 Agent 的统一规则：先检查状态；已运行则复用，已安装但未启动则启动并等待，完全没安装才运行安装脚本。若 8001 被其他进程占用，不要结束它。确认 Queue `running=0, waiting=0` 后再执行正常停止。活跃请求取消可能仍继续在后台推理直至结束。

转写与字幕：

```powershell
.\bin\asr.cmd transcribe "C:\media\demo.mp4"
.\scripts\transcribe-file.ps1 "C:\media\demo.mp4"
.\scripts\align-subtitles.ps1 "C:\media\voice.mp3" "C:\media\script.txt" -Preset voiceover
```

输出默认位于源媒体相邻的 `ASR_Output/`。使用自定义输出目录和 JSON / HTTP API 的详细信息见 [integration.md](integration.md)。

## 6. 常见失败与恢复

| 故障 | 优先检查 | 恢复 |
|---|---|---|
| Python 3.11 找不到 | `py -3.11 --version` | 补齐 Python 3.11 的系统前置条件，禁止覆盖其他项目 Python |
| FFmpeg 准备失败 | manifest、下载 ZIP 的 SHA-256、`tools/ffmpeg/bin` | 修复网络并重试，保留已有完整文件 |
| ModelScope 下载失败 | 网络、磁盘空间、缓存目录 | 重新执行准备脚本，或使用官方 SDK 手动下载 |
| 对齐模型未就绪 | Qwen 环境及模型完整性 | 执行可选安装脚本或完整导入模型 |
| 服务 120 秒内不就绪 | 是否仍在下载、服务日志、端口 | 区分下载与加载，不重复启动 |
| Queue 忙碌 | `/health.queue` | 等待任务完成，不强制结束 |
| 文件输出已存在 | 原业务目录的 `ASR_Output/` | 由调用方明确指定新目录，不覆盖成果 |

升级源码后可以重新运行安装脚本校验依赖和模型，但不要删除 `.venv`、模型、配置或工作数据作为第一种修复手段。

## 7. 对外发布和隐私边界

Git / Source ZIP 不包含：`.venv*/`、`models/`、`tools/ffmpeg/`、`runtime/`、`input/`、`output/`、`logs/`、`backups/`、`config/local.json`。正式 Windows Release ZIP 的唯一例外是包含经过验证的 **FFmpeg 运行文件与第三方许可资料**，仍不包含模型与用户数据。

```powershell
.\scripts\release-audit.ps1 -IncludeHistory
.\scripts\package-windows-release.ps1 -Version v0.5.0-beta -BuildSuffix 20261016
```

打包结果保存在本机 `runtime/release/`。公开仓库、Git push、GitHub Release 必须另外明确授权。
