# Buyer checklist (about 20 minutes at the seller's)

Goal: catch obvious faults quickly. This cannot prove a card is healthy; it can only rule out some failures. Evidence status is marked: **[V]** verified from a source on the date shown, **[M]** from the maintainer's memory or experience, not verified.

Bring on a USB stick: GPU-Z, HWiNFO (portable), memtest_vulkan, FurMark 2. Get each from its official site or repository.

## 1. Identify the card (about 1 minute)

- In GPU-Z, confirm model, memory size, BIOS version and PCIe link.
- Run GPU-Z's Render Test and check that the link trains to the width and generation you expect under load. A narrower link than expected can point to a dirty or damaged slot or connector. **[M]**
- Some variants of the same model name have different memory sizes or buses. Check the numbers, not the name. **[M]**

## 2. VRAM test with memtest_vulkan (about 6 minutes)

- Run it from a terminal, not by double-clicking: the project README says double-clicking starts the test in the background with no way to stop it. **[V, GitHub README, checked 2026-10-27]**
- The latest release listed on the project's releases page was v0.5.0 when checked. **[V, 2026-10-27]**
- A review of the tool describes a standard 5-minute test that ends with a PASSed message and writes a log file next to the executable. **[V, Gigazine, June 2026]**
- Any reported error means: do not buy at that price, and probably not at all. The author's own repair statistics for cards that error at default clocks and factory BIOS are roughly 60% memory chips, 30% the GPU chip, 10% other causes such as the memory voltage controller. **[V, author's post on Guru3D, 2022; his figures, not an independent study]**

## 3. Thermal and power behaviour with FurMark 2 and HWiNFO (5 to 10 minutes)

- Watch whether temperature levels off or keeps climbing, fan speed, and whether the card hits its power limit and throttles.
- FurMark is a very heavy synthetic load; a card that throttles there may behave better in real use, but a card that crashes there has a problem. **[M]**
- Rule of thumb: a large gap between GPU and hotspot temperature suggests dried paste or poor mounting. Roughly 15 to 20 C is a threshold some people use. **[M, unverified]**
- FurMark 2.8.0 was the newest FurMark listing seen on Geeks3D's download page when checked; a newer one may exist. **[V, 2026-10-27]**

## 4. Physical inspection (about 2 minutes)

- Fans: bearing noise, wobble, uneven spin-up.
- Smell of burnt electronics; discoloured or melted power connector.
- Stripped or mismatched screws and broken warranty seals suggest the cooler was removed (not necessarily bad, but ask why).
- Coil whine: audible under load. Annoying rather than dangerous. **[M]**

## What this does not cover

Instability that only appears after an hour or under a compute workload (CUDA/inference), and riser or slot problems in your own machine. Ask for a 24 to 48 hour return window if the seller allows it, then run `docs/test-protocol.md` at home.

## About leaked vendor diagnostics

Leaked internal NVIDIA diagnostic tools (referred to online as MODS/MATS) exist and are used by repair shops after a fault is found. There is no official distribution, the binaries circulate on unofficial sites, and running unknown binaries from such sites with elevated rights is a real risk. This project neither uses nor links them. They are not a buying-time test. **[M]**

## Sources

- memtest_vulkan: https://github.com/GpuZelenograd/memtest_vulkan and https://github.com/GpuZelenograd/memtest_vulkan/releases/
- Author's announcement and repair statistics: https://forums.guru3d.com/goto/post?id=6221541
- Gigazine review (June 2026): https://gigazine.net/news/20260621-gpu-vram-check-memtest-vulkan
- Geeks3D FurMark: https://www.geeks3d.com/dl/show/717
