# Third-party components

`local-ASR-service` is a thin integration layer. This repository does **not** redistribute pretrained model weights.

## Bundled FFmpeg / ffprobe (Windows Release packages)

The source repository does **not** commit FFmpeg binaries. The Windows distribution
includes a separately built, pinned **LGPL** FFmpeg / ffprobe pair; the source-code
clone downloads the same archive as part of normal installation.

- Upstream project: https://ffmpeg.org/
- Binary builder: https://github.com/BtbN/FFmpeg-Builds
- Pinned upstream release: https://github.com/BtbN/FFmpeg-Builds/releases/tag/autobuild-2026-09-30-13-08
- Package: `ffmpeg-N-127032-g6ae491a26c-win64-lgpl.zip`
- SHA-256: `c73ad424c5f9d94dd48815b4d3531e57130cb9f5c3dc8f21f4aa4e1fdb0658e3`
- Build manifest: `config/ffmpeg-distribution.json`; binaries and original `LICENSE.txt`
  are packaged under `tools/ffmpeg/`
- Corresponding FFmpeg source revision:
  https://github.com/FFmpeg/FFmpeg/commit/6ae491a26c8320d1bbfdc3f137b1ea1e9989afaa
  (confirmed from the archived build's `N-127032-g6ae491a26c` version marker)
- Builder source/build recipe: https://github.com/BtbN/FFmpeg-Builds
- License details: https://ffmpeg.org/legal.html
- Pinned upstream license copies in this repository and in the Windows ZIP:
  `licenses/ffmpeg/FFMPEG-LICENSE.md`, `LGPL-2.1.txt`, `LGPL-3.0.txt`,
  and `GPL-3.0.txt`. Files correspond to the FFmpeg source revision above.
  The original BtbN `LICENSE.txt` is preserved under `tools/ffmpeg/licenses/`.
- The project invokes standalone `ffmpeg.exe`/`ffprobe.exe` processes; it does
  not link against FFmpeg libraries. Source and build instructions are available
  via the pinned URLs above; redistributed source must correspond to the binaries.

This FFmpeg binary runs as a separate process; it is not relicensed under the
repository's MIT license. Verify your chosen build's license and corresponding
source availability before redistributing modified or replaced binaries.

## FunASR

- Project: ModelScope/FunASR
- Role: ASR runtime and `AutoModel` pipeline
- Source-code license: MIT License
- Upstream: https://github.com/modelscope/FunASR

FunASR also publishes a separate model-license notice for some pretrained weights. Always check the current model card before redistributing or modifying model weights.

## Default pretrained models

The public example configuration references these official ModelScope models:

| Model | Role | License shown on the ModelScope model card (checked 2026-08-26) |
|---|---|---|
| `iic/SenseVoiceSmall` | ASR | Apache License 2.0 |
| `iic/speech_fsmn_vad_zh-cn-16k-common-pytorch` | VAD | Apache License 2.0 |
| `iic/punc_ct-transformer_cn-en-common-vocab471067-large` | punctuation restoration | Apache License 2.0 |

ModelScope pages:

- https://modelscope.cn/models/iic/SenseVoiceSmall
- https://modelscope.cn/models/iic/speech_fsmn_vad_zh-cn-16k-common-pytorch
- https://modelscope.cn/models/iic/punc_ct-transformer_cn-en-common-vocab471067-large

## Optional Qwen3 Forced Aligner

The subtitle-alignment feature can use the official Qwen runtime/model as an optional, separately installed component:

| Component | Role | License checked 2026-09-10 |
|---|---|---|
| `qwen-asr` | Qwen3 ASR / Forced Aligner Python runtime | Apache License 2.0 source headers |
| `Qwen/Qwen3-ForcedAligner-0.6B` | word/character-level forced alignment | Apache License 2.0 |

Upstream model page:

- https://huggingface.co/Qwen/Qwen3-ForcedAligner-0.6B

The repository does not redistribute this model. Users download the model into their own local `models/` directory when they explicitly enable subtitle alignment.

The model licenses belong to their respective upstream projects and may change independently of this repository. The MIT license in this repository covers only the code and documentation authored for `local-ASR-service`.
