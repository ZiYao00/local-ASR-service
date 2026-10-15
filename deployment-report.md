# local-ASR-service 发布前验证报告

更新日期：2026-10-15（包含 2026-09-10 发布前验证记录）

## 发布候选状态

当前代码可作为 `v0.4.0` public-beta candidate。

`local-ASR-service` 的定位不是另一个 ASR 模型或通用 FunASR Server，而是面向 Windows 本机 Agent、Skill、自动化脚本和其它工具的共享本地语音处理 Gateway：默认统一处理 FFmpeg、VAD、SenseVoice、标点恢复、服务端 Queue 和稳定 API；当调用方已经有准确口播稿时，可选启用 Qwen3 Forced Aligner 生成剪辑字幕。

```text
普通转写：
媒体 → Server Queue → FFmpeg → FSMN-VAD → SenseVoiceSmall → CT-Transformer
     → text / raw_text / real VAD segments / TXT / SRT

已有口播稿字幕：
媒体 + 正确文稿 → Server Queue → SenseVoice 文稿一致性 QA
               → Qwen3 Forced Aligner → 字/词级时间戳
               → 智能字幕分段 → SRT / JSON
```

## 119 秒已有文稿字幕对齐验证

2026-09-10 使用 119.302 秒真实中文口播 + 对应最终口播稿完成端到端 CPU 测试。样本包含 `bili-learning-automation`、`Obsidian`、`ComfyUI`、`AIGC`、`Markdown` 等中英混合术语。

| 检查 | 结果 |
|---|---|
| 文稿一致性 QA | 0.9478 / pass |
| Qwen3 Forced Aligner | 580 个字/词级单元 |
| 时间轴 QA | 0 个逆序、0 个非法区间 |
| Forced Alignment | 19.742 秒（正式 API 路径） |
| 完整 API + QA + SRT/JSON | 53.588 秒 |
| 最终 voiceover 字幕 | 49 条 |
| 单条字幕时长 | 0.88–2.96 秒，平均 1.964 秒 |
| 中英混合术语 | 原稿显示形式保留；`bili-learning-automation` 连字符可恢复 |
| 错误文稿保护 | 0.0454 / fail，HTTP 422，在 Forced Aligner 前终止 |

字幕分段器经过真实样本迭代后采用：原稿标点 / 真实停顿优先，长度上限兜底，中文词内部不可切，并保护 `Obsidian库` 等无停顿混合词组。最终字幕文字始终以用户原稿为准，ASR 只用于一致性 QA。

V1 对齐模式明确限制为 **≤5 分钟、单人口播、有准确原稿**。普通长视频转写继续使用 SenseVoice/VAD 路线。

## 52 分钟真实媒体验证

2026-08-26 已完成一次 52 分 02 秒、354 MiB 视频测试：

| 检查 | 结果 |
|---|---|
| CPU 转写耗时 | 4 分 55 秒 |
| 处理速度 | 约 10.6× 实时 |
| TXT | 18,072 字符，UTF-8，带标点 |
| SRT 时间轴 | 890 段，编号连续、时间戳合法且单调 |
| 分块上传 | 通过 |
| 临时上传文件 | 完成后清理 |
| 规范化 WAV | 完成后清理 |
| 服务状态 | 完成后正常 |
| Queue | 完成后恢复空闲 |

该测试确认了长媒体上传、CPU 稳定性、VAD 时间轴和临时文件生命周期。

原测试同时暴露：顶层 TXT 有标点，但 890 个 VAD SRT 段标点覆盖率为 0%。

## SRT 标点映射修复

当前版本新增安全映射层：

- 保持每个 VAD segment 的 `start` / `end` 完全不变；
- 不根据标点重新切割或估算时间轴；
- 仅在顶层 `text` 与所有 VAD 段主体文字能够完整一一对齐时，把标点投影回 segment；拉丁字母大小写差异不单独阻断对齐；
- 成功时返回 `segments_punctuated: true`；
- 无法可靠对齐时保留原 VAD 文本并返回 `false`，不猜测。

已完成两层验证：

1. `tests/test_segment_punctuation.py` 单元测试通过，覆盖中文标点、英文标点和带连字符文本；
2. 将 `test1 + 4 秒静音 + test2` 合成 51.415 秒真实多 VAD 音频，实际转写得到 2 个 VAD 段，`SegmentsPunctuated=True`，导出的 SRT 两段均带标点，时间边界保持为真实 VAD 结果。
3. 5 分 04.785 秒真实媒体实际得到 54 个 VAD 段；修复后 `segments_punctuated=True`，其中 46 段带有完整文本中的自然标点。其余 8 段跨越自然句子边界，服务不会伪造句末标点。

原 52 分钟媒体是在修复前转写的，因此如需把“890 段全部标点回写”作为正式 Release 证据，仍建议对同一媒体再跑一次最终回归。

## Queue 验证

`scripts/queue-smoke-test.ps1` 已实际并发提交两个客户端请求，并观察到：

```text
running = 1
waiting >= 1
```

两个请求完成后：

```text
running = 0
waiting = 0
```

因此 CLI 与直接服务调用共用服务端单任务 Queue 的契约已验证。

## Windows / PowerShell 兼容修复

发布整理过程中发现并修复两个旧问题：

- `compare-asr.ps1` 在 Windows PowerShell 5.1 下受 UTF-8 无 BOM 中文 here-string 影响而解析失败，同时仍引用旧版已删除的性能字段；现已改为兼容当前结果结构的 ASCII-only 实验对比脚本；
- `smoke-test.ps1` 与 Queue 测试不再在参数默认值阶段使用 `$PSScriptRoot`，兼容 Windows PowerShell 5.1。

全量 `scripts/*.ps1` 解析检查已通过。

## 稳定 JSON 契约

Windows PowerShell 5.1 会在 `ConvertFrom-Json` 时解包单元素数组。为避免 CLI 将单段 `segments` 错误输出成对象，`transcribe` 现在验证服务响应后直接透传 Python Server 的原始 JSON，不再由 PowerShell 二次组装。

已验证：单段响应中的 `segments` 保持 JSON array，`segments_punctuated=True`。

## FFmpeg 后台进程兼容

发布测试发现：宿主 PowerShell 能找到 FFmpeg，但后台 Uvicorn 子进程可能无法通过 `PATH` 再次解析它。

现在启动脚本会先由 PowerShell 解析 `ffmpeg.exe`，再通过进程环境把绝对路径传给服务；路径不会写入公开配置或 Git。

重启后 `/health` 已验证 `ffmpeg=True`。

## 可重建安装

新增 / 保留：

- `requirements-cpu.txt`：主服务依赖版本，现显式包含字幕分段使用的 `jieba`；
- `scripts/install-cpu.ps1`：Windows / Python 3.11 主 CPU 安装入口；
- `requirements-aligner.txt`：可选 Qwen3 Forced Aligner 依赖；
- `scripts/install-aligner-cpu.ps1`：独立 `.venv-qwen3-asr` CPU 安装入口，不自动下载模型权重；
- `config/local.example.json`：默认 ASR 配置 + 可选 alignment 路径、时长、超时和 QA 阈值。

当前开发环境：Python 3.11.15、PyTorch CPU、FunASR 1.4.3、FastAPI 0.141.1、Uvicorn 0.52.4。`pip check` 已通过。

安装脚本不会删除或覆盖已经存在的 `.venv-cpu` / `config/local.json`。完全干净的新 Windows 机器安装仍建议在正式 `v1.0` 前独立做一次外部复现验证。

## 教程化文档

公开说明已调整为“先会用，再理解原理”的教程结构：

- `README.md`：项目首页、快速上手、日常使用、Agent / Skill 接入入口；
- `docs/INSTALL.md`：完整安装教程，明确推荐使用具备本地终端权限的 Agent 执行安装与验收；
- `docs/integration.md`：其它 Agent、Skill、脚本复用共享 ASR 服务的接入教程。

文档明确说明：开发机已经存在的 `.venv`、模型、缓存、日志、测试媒体和本机配置不会上传 GitHub；用户在自己的机器运行 `install-cpu.ps1` 自动建立 Python 环境和项目依赖。手工逐项安装 Python 依赖不是推荐路径。

## License / 第三方边界

- 项目自有代码与文档：MIT；
- 仓库不分发模型权重；
- FunASR、默认 ModelScope 模型、可选 `qwen-asr` 与 `Qwen3-ForcedAligner-0.6B` 的许可证边界记录在 `THIRD_PARTY.md`；
- 模型许可证应以实际使用时的上游模型卡为准。

## 隐私与仓库边界

新增 `scripts/release-audit.ps1`，当前最终审计结果：

```text
FilesScanned = 38
PrivacyFindings = 0
RequiredIgnoreRules = 8
```

公开仓库忽略：

- `.venv*`；
- `models/`；
- `runtime/`；
- `logs/`；
- `input/`；
- `output/`；
- `backups/`；
- `config/local.json`；
- IDE / OS 临时文件。

早期未使用的 `config/service.json` 已移除，避免与 `local.json / local.example.json` 形成双配置入口。

## 最终自动检查

- Python compile：通过；
- PowerShell 5.1 全脚本 parse：通过；
- segment punctuation unit test：通过；
- subtitle segmentation unit test：通过；
- alignment QA helper test：通过；
- 旧 `/v1/audio/transcriptions` 真实短媒体回归：通过；
- 新 `/v1/audio/alignments` 119 秒真实端到端测试：通过；
- 错误文稿 HTTP 422 提前拦截：通过；
- 主 `.venv-cpu` `pip check`：通过；
- 可选 `.venv-qwen3-asr` `pip check`：通过；
- release privacy / ignore audit：38 files / 0 findings，通过。

## 2026-10-15 轻量资源维护与请求生命周期修复

此次维护保留现有 SenseVoice / VAD / 标点与 Qwen3 Forced Aligner 架构，不引入 Worker、不更换模型、不修改依赖与本机配置。修复请求取消后的 Queue 与临时文件所有权、上传中途取消后的清理，增加带 `Content-Length` 的明显超限请求前置拒绝；正常停止命令遇到忙碌队列时拒绝停止。未声明大小的 multipart 请求仍由框架先解析，尚不具备完整的入口级流式总大小限制。

- 新增 `tests/test_request_lifecycle.py`：10 项全部通过，包括等待／运行中取消、字幕对齐取消、超时、上传清理与 HTTP 返回契约；
- 原有 3 个 Python 测试脚本分别通过；PowerShell 全脚本解析检查通过；
- 正式 8001 服务重启后，17.972 秒真实媒体普通转写 Smoke Test 通过，122 字符，标点回写正常；
- 正式对齐接口的错误文稿拦截返回 HTTP 422，未启动 Forced Aligner，符合原有 QA 行为；
- 用正确文稿进行的一次真实 Forced Aligner 验证超过 80 秒命令时限，**没有取得可确认的成功响应，不能记为通过**；之后主服务健康、Queue 为 0/0、无残留对齐子进程，临时目录仅保留既有 `jieba.cache`；
- 隐私审计：40 文件 / 0 findings / 8 ignore rules，通过；
- 原有未提交的 `README.md`、`scripts/service.ps1`、`service.bat` 保留并纳入后续授权的本地提交；维护验收时未自行提交或推送，也未删除模型、日志、备份或目录。

后续如要发布此修复版本，应先做一次可观测的真实成功字幕对齐回归，并评估当前环境的 CPU 对齐耗时。暂不建议因此引入独立 Worker 或反复尝试高负载生成。

## 发布建议

当前适合发布为 `v0.4.0` / public beta，而不是直接声明 `v1.0`。

正式 `v1.0` 前建议保留这些外部验证：

1. 在一台干净 Windows 环境从 clone 开始执行 `install-cpu.ps1`；
2. 在另一台干净环境执行可选 `install-aligner-cpu.ps1`，手动放入官方 Qwen3 Forced Aligner 模型后完成一次字幕对齐；
3. 用修复后的版本重新跑同一条 52 分钟视频，记录 890 段 SRT 的最终 `segments_punctuated` / 标点覆盖结果。

本轮修改开始前 Git 工作区为 clean；本轮未创建新的备份包，也未执行 commit / push。
