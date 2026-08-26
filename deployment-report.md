# local-ASR-service 迁移与验证报告

更新日期：2026-08-26

## 当前状态

`local-ASR-service` 已从“FunASR Server 启动壳 + 客户端互斥锁”升级为拥有自身薄服务层的本机共享 ASR 服务。

默认生产链：

```text
本地媒体
→ FFmpeg 规范化（所有媒体统一为 16 kHz 单声道 WAV）
→ FSMN-VAD
→ SenseVoiceSmall
→ CT-Transformer 标点恢复
→ 稳定 JSON
```

## Phase 3 已完成

- 新增 `service/app.py` 与 `service/engine.py`，不修改 `.venv` 中的 FunASR 源码。
- SenseVoiceSmall 继续使用既有本地模型。
- FSMN-VAD 已确认从既有本地模型目录加载。
- 已下载并验证官方 CT-Transformer 标点模型；当前机器的 `config/local.json` 已固定到该本地模型路径。
- 默认 `text` 输出为恢复标点后的可读文本；新增 `raw_text` 保留 ASR 原始文字并去除 SenseVoice 特殊标签。
- `duration` 返回真实媒体时长。
- `segments` 不再使用按字符比例生成的伪时间轴；无法精确对齐标点时退回真实 VAD 语音段。
- 并发队列迁移到服务端；CLI 不再维护 Windows 命名互斥锁。
- `transcribe-file.ps1` 已收口为统一服务结果的 TXT/SRT 导出器，不再重复实现 FFmpeg + HTTP 转写链。
- `/health` 新增服务名、模型、VAD、标点、Queue 与 FFmpeg 状态。
- README、接入文档、Smoke Test 已同步新契约。
- 上传按 4 MiB 分块写入项目 `runtime/temp`，不再将完整媒体文件读入内存；默认单文件上限为 2 GiB。
- 新旧服务均可由停止脚本在健康响应和隔离 Python 启动器都匹配时安全停止。

## 本次真实验证

| 检查 | 结果 |
|---|---|
| Python 服务代码编译 | 通过 |
| SenseVoiceSmall 本地加载 | 通过 |
| FSMN-VAD 本地加载 | 通过 |
| CT-Transformer 本地加载 | 通过 |
| `test1.mp4` Pipeline 转写 | 通过 |
| `test2.mp4` TXT/SRT 导出 | 通过 |
| 标点恢复 | 通过 |
| `raw_text` 标签清理 | 通过 |
| 真实 duration | 通过，17.972 秒 |
| VAD segment | 通过，样本为 0.0–17.95 秒 |
| 新服务接管 `127.0.0.1:8001` | 通过 |
| `/health` 与 `/v1/models` | 通过 |
| `response_format=text` 纯文本响应 | 通过 |
| 双客户端服务端排队 | 通过，实测 `running=1, waiting=1` |

本次文件输出位于 `runtime/test/phase3-hardening-output/`，其中包括按命名约定生成的 `test2_sensevoice-small_CPU.txt` 与 `.srt`。该目录为 Git 忽略的本地验收产物。

## 时间轴行为

SenseVoiceSmall 不总能提供足够的词级时间信息，使 CT-Transformer 的标点句子精确映射回时间轴。FunASR 1.4.3 在这种情况下会退回真实 VAD 段。

本项目接受这一降级：宁可返回较粗但真实的语音时间段，也不再按字符数量人为估算更细时间轴。

## 尚未完成的验收

- 30 分钟真实长音频压力测试。
- 60 分钟真实长音频压力测试。
- 多个真实 VAD 段的 SRT 标点可读性复核。

本轮两个短样本均只产生一个 VAD 段，因此不能将其作为多段 SRT 标点效果或长媒体稳定性的证据。

## 当前运行态注意事项

原 `127.0.0.1:8001` FunASR 进程已通过项目停止脚本安全停止；当前端口由 `service.app:app` 的项目隔离 CPU 环境提供服务。重启流程为：

```powershell
.\scripts\start-server.ps1
.\scripts\health-check.ps1
.\scripts\smoke-test.ps1
```

## 仓库状态

仓库仍未创建首次 Git commit；本轮没有提交或推送。

本轮修改前备份：

`backups/phase3-pre-service-refactor-20260826-1725.zip`

服务加固前备份：

`backups/phase3-before-hardening-20260826-1735.zip`
