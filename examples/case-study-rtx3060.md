# Case study: a second-hand RTX 3060, one real burn-in

This is a real run, summarised and anonymised. It was done **before** this tool existed, with OCCT, `nvidia-smi` logging and a hand-written PowerShell loop calling `ollama run --verbose`. It is included to show what the procedure looks like in practice and which problems shaped the tool. It is one card on one machine, not a benchmark.

## Setup

- Card: GeForce RTX 3060, 12 GB class (VRAM in use reached about 11.5 GB; capacity was not yet confirmed in GPU-Z at the time).
- Host: Windows 11, card installed temporarily in place of a faster one.
- Workload: a locally customised model of about 9.5 GB, 100% on GPU according to `ollama ps`, context 4096, `num_predict` 4096.

## Steps and results

| Step | Configuration | Duration | Result |
|---|---|---|---|
| OCCT VRAM | only the 3060 selected, 80% of memory | 1 h | No errors detected |
| OCCT 3D Adaptive | Steady, Extreme, only the 3060 | 1 h | No errors detected, maximum 78 C |
| Inference loop | `ollama run --verbose` in a loop | about 1 h | see below |

### Inference loop, from the `nvidia-smi` log (767 samples at 5 s)

- Temperature: maximum 77 C, average 75.8 C (the average includes idle samples before and after the loop).
- Power: maximum 170.2 W, average 167.4 W (includes idle samples); the card sat at its power limit.
- Graphics clock, only samples with utilization above 90% (848 samples at the time of that query): minimum 1702, average 1798, maximum 1890 MHz.
- Memory clock: 7301 MHz, constant.
- VRAM used: about 11.4 to 11.5 GB.
- Tokens/second, first four values only: 33.37, 32.71, 30.72, 30.58. The full list was never analysed, so the roughly 8% decline across those four values has no established cause; it is not claimed to be throttling.
- The number of iterations actually completed was not verified.

## What went wrong along the way (and what the tool does about it)

- **`NativeCommandError` noise in the log.** Ollama's `--verbose` statistics go to stderr, and redirecting stderr with `2>&1` in Windows PowerShell 5.1 wraps them as error records. The tool uses the HTTP API and reads `eval_count` and `eval_duration` instead.
- **Positional CSV parsing.** The one-liners used column positions, which silently breaks if the query order changes. The tool matches columns by header name.
- **Idle samples skewing averages.** The log started before and ended after the load. The tool computes statistics only over samples above a utilization threshold.
- **Repetition loop at temperature 0.** The model fell into a repeated sentence. The text was coherent, only repeated, so it was a decoding artefact rather than a hardware symptom, and the GPU load stayed valid. The tool keeps `num_predict` bounded and does not read the generated text for health signals.
- **Garbled accented characters in the console** came from console encoding (UTF-8 bytes shown as an OEM code page), not from the card.

## Conclusion of the run

No errors in about three hours of combined testing, stable temperature near 76 to 77 C, clock within about 10% of its range under a power-limited load. Stability on a PCIe riser and a full analysis of the speed decline were left as open items. No claim is made that the card is healthy beyond what was tested.
