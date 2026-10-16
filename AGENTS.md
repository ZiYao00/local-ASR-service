# Agent operating instructions

Use `README.md` for entry points, `docs/INSTALL.md` for installing/upgrading, and
`docs/integration.md` for existing services used by other Agents.

## Platform and install
- Windows 10/11 x64, Python 3.11, CPU-first. Work within this repository.
- On first install, execute `scripts/install-cpu.ps1` only after the user authorizes
  installation/downloads. It prepares the local Python environment, pinned
  project FFmpeg/ffprobe, and default ModelScope models.
- Optional accurate-script subtitle alignment uses `scripts/install-aligner-cpu.ps1`;
  do not install this optional runtime unless the task requires it.
- Model weights, FFmpeg binaries, `.venv*`, `config/local.json`, caches, logs
  and user media are never part of Git. Do not delete or overwrite them.
- Do not install system-wide FFmpeg or change global PATH; the project owns its copy.

## Operate and verify
- Preferred management interface: `service.bat status|start|stop|restart`.
- Reuse a running instance; do not kill an unknown listener on port 8001.
- Allow model loading to finish. A running port without `/health.status=ok`
  is not proof of readiness.
- Always run a real audio transcription before reporting successful first install;
  use `scripts/smoke-test.ps1 -InputPath <local file>` when a sample exists.
- For existing integrations prefer `bin/asr.cmd` or the documented HTTP API.
- The service must not overwrite existing outputs. Preserve business assets with
  the consuming project, not inside this repository.
- A client timeout does not necessarily cancel an active inference. Inspect
  `/health.queue` before retry or stop.

## Work boundaries
- Diagnose failures before modifying implementation; do not replace working
  ASR pipelines or add a second service.
- Do not change CPU/GPU mode automatically.
- Do not commit, push, publish, change repository visibility or delete files
  without the user's specific authorization.
- Report which installation steps and runtime tests passed versus not run.
