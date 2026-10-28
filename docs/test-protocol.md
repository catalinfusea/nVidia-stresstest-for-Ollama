# Home burn-in protocol

Run the steps one at a time, never two GPU tests together. Evidence status: **[V]** verified from a source on the date shown, **[M]** maintainer experience or memory, not verified.

Record for every step: temperatures (GPU and hotspot if available), clocks, power, errors, crashes, driver resets.

## 0. Preparation

- Install the current NVIDIA driver, note its version.
- Close everything else that uses the GPU. The desktop alone can take a noticeable amount of VRAM. **[M]**
- Keep HWiNFO (or `nvidia-smi`) logging during every step.

## 1. Identify (GPU-Z)

Model, memory size, BIOS, PCIe link under load (see `buyer-checklist.md`).

## 2. OCCT, VRAM test, 1 hour

- Select the card explicitly (do not test the integrated GPU by mistake), memory around 80 to 90% of what OCCT offers.
- The free edition of OCCT limits a test to one hour and enforces a short cooldown between tests. It is licensed for personal, non-professional use. **[V, ocbase.com/personal-features, checked 2026-10-27]**
- OCCT treats any error as a definitive sign of instability, and lets you choose between stopping at the first error or continuing and counting. **[V, ocbase.com/occt, checked 2026-10-27]** In the OCCT build the maintainer used (version not recorded) the 3D Adaptive page showed no separate error-detection toggle and no "stop on first error" setting; errors are reported in the results panel.

## 3. OCCT, 3D Adaptive, 1 hour

- Mode Steady, load type Extreme, only the card under test.
- Watch for temperature that keeps rising after 10 to 15 minutes, clock that keeps falling, black screens or driver resets.
- If the card has modest cooling, drop to Heavy rather than hold it at the limit for an hour. **[M]**

## 4. memtest_vulkan, 2 hours (recommended for second-hand cards)

- An independent algorithm and code path from OCCT, so it can catch what OCCT misses. The author uses a 2-hour pass as his criterion that the memory chips are fine at high frequency. **[V, author's post on Guru3D, 2022]**
- Run from a terminal, not by double-click. **[V, README, 2026-10-27]**

## 5. Sustained inference with this tool, 60 minutes

```powershell
.\scripts\Invoke-GpuAiCheck.ps1 -Model <model that fits fully in VRAM> -DurationMinutes 60
```

- Pick a model that fits entirely in VRAM with its context, so the load stays on the GPU. The report records how much of the model Ollama placed in VRAM.
- This step exercises the CUDA compute path that DirectX/Vulkan tests do not. **[M]**

## 6. Repeat step 5 in the final configuration

If the card will run on a PCIe riser or in a different machine, repeat the inference run there. A bad riser shows up as errors, driver resets or crashes, not as a change in tokens/second. **[M]**

## 7. Coil whine (optional, a few minutes)

OCCT 3D Adaptive has a Coil whine mode. It only tells you how noisy the card is.

## Sources

- OCCT personal edition: https://www.ocbase.com/personal-features
- OCCT tests description: https://ocbase.com/occt
- memtest_vulkan: https://github.com/GpuZelenograd/memtest_vulkan
- Author's post: https://forums.guru3d.com/goto/post?id=6221541
