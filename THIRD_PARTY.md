# Third-party components

`local-ASR-service` is a thin integration layer. This repository does **not** redistribute pretrained model weights.

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

The model licenses belong to their respective upstream projects and may change independently of this repository. The MIT license in this repository covers only the code and documentation authored for `local-ASR-service`.
