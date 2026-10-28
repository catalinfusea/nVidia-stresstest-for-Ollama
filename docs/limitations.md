# Limitations

- **A clean report is not a health guarantee.** The tool measures one workload for a limited time. Faults that appear later, under other workloads, or intermittently can be missed.
- **It does not test VRAM integrity.** Inference only reveals gross memory or compute instability. Use a dedicated memory test (see `test-protocol.md`).
- **NVIDIA and Ollama only.** AMD, Intel, llama.cpp servers and other runtimes are out of scope.
- **Heuristic flags are not verdicts.** Their thresholds are arbitrary; a flag means "look closer".
- **Multi-GPU machines.** The tool logs the GPU selected with `-GpuIndex` (nvidia-smi ordering). It cannot check that Ollama used the same GPU. If it did not, telemetry and inference results describe different cards.
- **Single prompt.** One fixed prompt gives comparable runs but is not representative of every workload (long contexts, batching, other quantizations).
- **Timing.** The request in flight at the deadline is allowed to finish, so a run can overshoot the requested duration by up to one iteration.
- **Windows PowerShell 5.1 and real hardware** are not yet confirmed by the maintainer; see "Testing status" in the README.
- **Throttle bitmask** is shown raw and not decoded.
- **Riser and slot problems** show up as errors or resets, not as numbers this tool computes. Repeat the run in the final configuration.
- **No pass/fail.** Deciding whether a card is acceptable is left to the reader, with the context of price, return policy and use case.
