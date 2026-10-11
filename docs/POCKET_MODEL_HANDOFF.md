# Assigning the roadmap to other models

**Resume work from [POCKET_START_HERE.md](POCKET_START_HERE.md).** It records what was actually completed, installed tools, unresolved blockers and the next implementation packet. The [memory contract](POCKET_MEMORY_CONTRACT.md) now has isolated RTL; see [implementation evidence](POCKET_IMPLEMENTATION.md). Simulation and live integration remain outstanding.

Read [POCKET_ROADMAP.md](POCKET_ROADMAP.md) for the evidence, task contracts and dependency table, and [POCKET_BENCHMARKS.md](POCKET_BENCHMARKS.md) for acceptance. The goal is sound plus approximately 30 fps in selected original PS1 games at correct game speed.

## Spend model capacity where it matters

| Work packet | Model level | Suggested delegation |
|---|---|---|
| Dependency inventory, build manifest, artifact hashes, report tables and packaging metadata | L1 economical | Give exact file lists and schemas; strong model reviews outputs |
| Focused cache fix, counter tooling, trace conversion and individual GPU fixtures | L2 strong coder | Small patch plus failing-before/passing-after test evidence |
| Isolated I2S/PCM block, simple GPU primitive, controls or persistence tooling | L2 strong coder | Explicit interface contract; L3 reviews CDC, ordering and timing |
| Build/platform reconstruction, shared memory, loader CDC, authoritative VRAM migration | L3 strongest reasoning + RTL experience | Design first, staged implementation, synthesis/timing evidence |
| Shared SPU, CPU/GPU overlap, guest timing, GTE arithmetic refactoring, CD audio | L3 strongest reasoning + RTL experience | One subsystem at a time; independent verification plan before edits |
| Final integration, resource allocation and conflicting hardware behavior | L3 plus FPGA expert | One architecture owner; hardware qualification is mandatory |

Long context alone is insufficient. Prefer a model that can reason about nonblocking assignments, finite-width signed arithmetic, clock crossings, external RAM timing, FIFOs and synthesis resource inference. A cheaper model with proven HDL skills can outperform a larger model unfamiliar with those topics. The tiers are minimum supervision recommendations, not guarantees.

## Efficient dispatch order

1. Assign **P00** to the strongest model. Use a cheap assistant for its dependency/manifest work. Its first deliverable is a concrete missing-file/toolchain plan, not speculative RTL optimization.
2. Assign **P02** as the first small coding exercise and **P01** tooling as an independent packet. Without the recovered build, these can prepare patches/fixtures but cannot claim validation.
3. Have the architecture owner specify **P04** interfaces before assigning dependent blocks. Freeze request ownership, byte lanes, reset and completion semantics in a shared document.
4. Implement **P06** VRAM rendering/scanout and reclaim internal RAM. Reserve resources and bounded memory service for later audio; defer **P05/P07** implementation until the video gate passes.
5. Assign **P08/P09** to one owner or tightly coordinated sequential tasks; scheduling and game time are coupled. Assign **P10/P13** only with the pixel sink/cache contract in hand.
6. Implement required rendering/boot compatibility and run the **M4 video gate** through P16: approximately 30 fps, correct game speed, silent output permitted. Pull forward only the data-streaming part of **P11** if needed. Run **P12** earlier only if fresh fit data shows an area problem.
7. After M4, implement **P05/P07** and required CD audio from **P11**, then repeat **P16** for the combined M6 gate with sound enabled.

Use separate branches/checkouts for implementation packets. Two models should not independently change `PlayStation_core.sflp`, `GraphicProcessingUnit.sflp` or `Pocket/core_top.v` without an integrator. Commit interface changes before dependent branches start integrating.

## Copyable implementation prompt

```text
Implement task Pxx from docs/POCKET_ROADMAP.md.
Read docs/POCKET_BENCHMARKS.md and the task's cited source files.
The target is Analogue Pocket 5CEBA4F23C8, sound and approximately
30 presented game frames/s at correct game speed in the selected scenes.
Current priority: video/30 fps first (M4), audio afterwards (M5/M6).
Respect that order and preserve measured resource headroom for audio.

First report:
- Which prerequisites are satisfied, with artifact paths.
- The interface/behavior changes and invariants you will preserve.
- Expected resource costs and how you will measure them.
- A focused validation plan and the files you will edit.

Then implement only this task in reviewable steps. Preserve source
encoding and do not hand-edit generated RTL as the authoritative source.
Use original PS1 binaries for acceptance; desktop ports are references.
Add/run the focused tests needed by the task contract when tools exist.
If a tool/dependency is missing, record exactly what prevents validation.
Do not invent successful builds, hardware results, throughput or FPS.

Return a handoff containing changed files, interface contracts, commands,
test outcomes, fit/timing deltas, unresolved failures, and the next task
whose prerequisites are now satisfied. Archive raw reports/traces.
```

## Reviewer checklist

- Does every claimed improvement have a before/after measurement of the same workload?
- Does the change fit in physical RAM blocks, DSPs and ALMs, with timing closed?
- Are request acceptance and completion distinct, with no broadcast ack ambiguity?
- Do resets/clock crossings handle the actual clock relationship rather than hiding paths with false-path constraints?
- Do resource savings preserve required numeric width, rounding, IRQ and cache semantics?
- Does audio remain correct under the maximum simultaneous rendering/streaming load?
- Are native game speed and true presentation cadence separate from output refresh and flip proxies?
- Are MIRLO64-derived blocks pinned and attributed, and their N64-specific assumptions removed?

A strong model should review architecture-sensitive work even when a small task was implemented by an economical model. A human must supply or operate the physical hardware and assess external timing evidence before the final result is called validated.
