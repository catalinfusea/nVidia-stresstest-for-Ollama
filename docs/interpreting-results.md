# Interpreting the report

Evidence status: **[V]** verified from a source on the date shown, **[M]** from memory or experience, not verified, **[D]** deduction.

## Where the numbers come from

- **Tokens/second** is computed as `eval_count / eval_duration * 10^9` from the final response of Ollama's `/api/generate`; durations are in nanoseconds. **[V, Ollama API documentation mirror and docs.ollama.com, checked 2026-10-28]** The formula comes from a mirror of the project's `docs/api.md`, which may lag the current docs.
- **GPU offload** is `size_vram / size` from `/api/ps`. **[V]** The documentation does not state the units, so only the ratio is used.
- **Telemetry** is `nvidia-smi --query-gpu=... --format=csv -l N`, parsed by column name.
- **Under load** means samples with GPU utilization at or above the threshold (default 90%). Idle samples are excluded from temperature, power and clock statistics; they are included in the VRAM maximum.

## Reading each section

### Temperature

Compare the maximum with the documented limit for your exact GPU. NVIDIA's reference specification lists 93 C as the maximum GPU temperature for the RTX 3060 family; this was seen only through secondary sources quoting NVIDIA's page, and partner cards can use different targets. **[V as quoted, 2026-10-28; not checked on NVIDIA's own page]** Typical sustained loads on that family are reported in the 60 to 80 C range depending on cooler and ambient temperature (forum and retailer articles). **[V as reported]** A stable temperature that levels off within 10 to 15 minutes is a better sign than a high one that keeps rising. **[M]**

### Power and clocks

- A card pinned at its power limit with a clock that wobbles by a few percent is normal boost behaviour. **[M]**
- The throttle-reason bitmask is shown raw. Decode it with NVIDIA's documentation or `nvidia-smi -q -d PERFORMANCE`; the tool does not decode it. The field name differs between driver generations, so the tool probes `clocks_throttle_reasons.active` and `clocks_event_reasons.active`. **[D, from the probing design; the names were not verified against NVIDIA docs in this session]**

### VRAM

Used VRAM close to the total leaves little headroom. A larger context or another app on the GPU can push the model partly to the CPU or make loading fail.

### Tokens/second

- Token generation is usually limited by memory bandwidth rather than compute, so a rough ceiling is memory bandwidth divided by the bytes read per token (roughly the model size for a dense model). **[M, rule of thumb; do not treat it as a benchmark]**
- A steady value is the good case. A falling value can mean thermal or power throttling, but also background load or run-to-run variation. The first-third vs last-third comparison and its 5% threshold are heuristics. **[D]**
- A PCIe riser normally has little effect on generation speed when the model sits fully in VRAM; it mostly affects model loading. **[M, unverified on your hardware]**

### Determinism check

At temperature 0 with a fixed seed, the same prompt should normally give the same output. Identical hashes are a weak consistency signal. Differing hashes are worth a repeat run, not a verdict: bit-exact determinism is not guaranteed on GPUs. **[M]**

A model that falls into a repetition loop at temperature 0 is a decoding behaviour, not a hardware symptom: the text is coherent, only repeated. Corrupted tokens, runaway garbage, NaN-like output, a crashed runner or CUDA errors are more worrying. **[M, experience-based, not a guarantee]**

### Observations

Heuristic flags only. Thresholds (5% speed drop, 85 C, 95% VRAM, 99% offload, 80% of expected samples) are arbitrary defaults. An empty list does not mean the card is healthy.

## Sources

- Ollama API usage: https://docs.ollama.com/api/usage
- Ollama API reference mirror: https://fossies.org/linux/ollama/docs/api.md
- RTX 3060 temperature figures (secondary): https://tecnoblog.net/comunidade/t/pode-jogar-com-a-rtx-3060-acima-de-80-graus/69624?tl=en and https://evezone.evetech.co.za/build-lab/rtx-3060-temperatures-safe-ranges-and-limits
