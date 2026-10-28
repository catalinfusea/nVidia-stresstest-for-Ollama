# gpu-ai-check

A practical protocol and a small PowerShell tool for checking an NVIDIA GPU you intend to use for local AI inference (Ollama), especially a second-hand card: a checklist for the seller's table, a burn-in procedure for home, and a script that runs a sustained inference load, logs GPU telemetry and writes a report.

It reports measurements and heuristic flags. It does **not** declare a card good or bad.

## Why

A second-hand GPU that passes a quick look can still fail under sustained load, or throttle badly. Inference workloads stress memory bandwidth and power differently from games. This repository collects a repeatable procedure and one tool for the "sustained real workload" step, with the limits of each check stated plainly.

## What is in here

| Path | What |
|---|---|
| `docs/buyer-checklist.md` | What to check at the seller's, in about 20 minutes |
| `docs/test-protocol.md` | Burn-in procedure at home, in order |
| `docs/interpreting-results.md` | How to read the report; what is verified and what is a rule of thumb |
| `docs/limitations.md` | What this does not prove |
| `scripts/Invoke-GpuAiCheck.ps1` | The tool |
| `scripts/GpuAiCheck.psm1` | Parsing, statistics and report functions used by the tool |
| `tests/` | Unit tests and an end-to-end smoke test (see "Testing status") |
| `examples/` | A synthetic sample report and a real case study |

## What the tool does

1. Preflight: finds `nvidia-smi`, reads GPU name, driver and VRAM, checks the Ollama API, warms the model up and asks `/api/ps` how much of the model sits in VRAM.
2. Starts `nvidia-smi` logging in the background (temperature, power, clocks, VRAM, utilization, and the throttle-reason bitmask when the driver exposes it).
3. Repeats one generation request through the Ollama HTTP API until the requested duration has passed (the request in flight at the deadline is allowed to finish).
4. Writes `report.md`, `summary.json`, `run-meta.json`, `gpu-log.csv` and `iterations.csv` to an output directory.

The report contains: telemetry statistics under load, tokens/second per iteration with a first-third vs last-third comparison, a determinism check (hashes of outputs at temperature 0), and a short list of heuristic observations.

## What it does not do

- It does not test VRAM integrity pattern by pattern. Use a dedicated memory test (see `docs/test-protocol.md`).
- It does not support AMD or Intel GPUs, and it only drives Ollama.
- A clean report is not a health guarantee. See `docs/limitations.md`.

## Requirements

- NVIDIA driver with `nvidia-smi` on `PATH`.
- Ollama running locally, with the model already pulled.
- PowerShell 5.1 (Windows) or PowerShell 7+. No modules to install.

## Quick start

```powershell
# Make sure Ollama is running and the model is pulled ("ollama list" shows the exact name).
.\scripts\Invoke-GpuAiCheck.ps1 -Model <model name> -DurationMinutes 60
```

Output goes to `gpu-ai-check-<timestamp>\`. If the run is interrupted (Ctrl+C), rebuild the report from the files already written:

```powershell
.\scripts\Invoke-GpuAiCheck.ps1 -ReportFrom .\gpu-ai-check-<timestamp>
```

If Windows blocks the script, see `about_Execution_Policies`.

## Parameters

| Parameter | Default | Notes |
|---|---|---|
| `-Model` | required | Name exactly as in `ollama list` |
| `-DurationMinutes` | 60 | 0.1 to 720 |
| `-SampleSeconds` | 5 | Telemetry interval, 1 to 60 |
| `-GpuIndex` | 0 | `nvidia-smi` index. On multi-GPU machines make sure Ollama really uses this GPU (how to pin Ollama to a GPU is in Ollama's GPU documentation; not verified here) |
| `-NumPredict` | 1024 | Tokens generated per iteration |
| `-Seed`, `-Temperature` | 42, 0 | Fixed so outputs can be compared across iterations |
| `-Prompt` | built-in long technical prompt | Custom prompts are recorded only as length and SHA-256 |
| `-RequestTimeoutSec` | 900 | Per request |
| `-OllamaUri` | `http://127.0.0.1:11434` | Non-loopback is refused unless `-AllowRemoteOllama` is set |
| `-LoadThresholdPct` | 90 | Samples at or above this GPU utilization count as "under load" |
| `-TempWarnC` | 85 | Only drives a heuristic flag; compare with your GPU's documented limit |
| `-OutputDir` | `gpu-ai-check-<timestamp>` | Must not exist or must be empty |
| `-ReportFrom` | | Rebuild the report from an existing output directory |

## Privacy and safety

- Only the local Ollama HTTP API is called. Nothing is downloaded or uploaded.
- A non-loopback Ollama address is refused by default, because the GPU telemetry would then describe a different machine than the one doing the work.
- The report contains no host name, user name, local paths, GPU serial number or UUID. It does contain the GPU model, driver version, OS version string and PowerShell version. Review it before sharing.
- The tool needs no administrator rights and writes only to the output directory.

## Testing status

| What | Result |
|---|---|
| Unit tests on synthetic data (`tests/Run-Tests.ps1`), PowerShell 7.6.8 on Linux | 17 passed |
| End-to-end smoke test against a fake Ollama and a fake `nvidia-smi` (`tests/e2e/Run-E2E.ps1`), PowerShell 7.6.8 on Linux | 8 passed |
| Real NVIDIA GPU + real Ollama on Windows | **Not yet confirmed by the maintainer** |
| Windows PowerShell 5.1 | **Not tested**; the code avoids PowerShell 7-only syntax but this is unverified |

The smoke test proves that orchestration, file formats and error handling work. It says nothing about real hardware. The CSV parser was shaped by real `nvidia-smi` output from a Windows 11 host (headers such as `power.draw [W]`, values such as `169.95 W`).

## Development

```powershell
pwsh -NoProfile -File tests/Run-Tests.ps1          # unit tests, no dependencies
pwsh -NoProfile -File tests/e2e/Run-E2E.ps1        # Linux/macOS only, needs python3
```

Pester is deliberately not used, to keep the tool dependency-free. The scripts are ASCII-only so Windows PowerShell 5.1 reads them correctly without a BOM.

## License

MIT, see `LICENSE`.
