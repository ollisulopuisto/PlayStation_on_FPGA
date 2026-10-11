# Assigning the roadmap to other models

**Resume work from [POCKET_START_HERE.md](POCKET_START_HERE.md).** It records what was actually completed, installed tools, unresolved blockers and the next implementation packet. The [memory contract](POCKET_MEMORY_CONTRACT.md) now has isolated RTL; see [implementation evidence](POCKET_IMPLEMENTATION.md). The isolated memory frontend has passed behavioral simulation. Full-system simulation and live integration remain outstanding.

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

## Independent low-cost task packets

These packets are intentionally separable from the compiler's sequential/control implementation and from one another. Keep each change within its owned files; report blockers with evidence instead of filling gaps by assumption. Acceptance commands below are run from the project root. They define the expected evidence; do not claim a command passed unless it was actually run.

### L1 — P00 dependency and build-input manifest

**Goal:** turn the known P00 build gaps into a machine-readable, auditable inventory while the compiler work proceeds.

**Inputs:** `Makefile`, `Pocket/core.sflp`, `Pocket/core_top.v`, `docs/POCKET_P00_TOOLCHAIN.md`, `tools/apf/fetch_apf.sh`, `hdl/SDRAM/MIRLO64/README.md`.

**Owned files:** add `tools/pocket/build_inputs.json` and `tools/pocket/check_build_inputs.py`; do not edit source RTL, SFL, compiler files, fetch scripts, or licenses. Record for each required input: logical name, consuming source/target, current status (`present`, `generated`, `fetch-at-build`, `missing`, or `decision-needed`), expected path, pinned revision/hash where available, license/provenance note, and next action. Distinguish a downloadable installer from an installed tool and distinguish syntax/elaboration from a complete project build.

**Acceptance:** `python3 tools/pocket/check_build_inputs.py` exits 0 on a valid manifest, rejects missing required keys and duplicate logical names, and emits a deterministic summary. Cross-check manifest paths against the Makefile and direct includes in the named Pocket sources. The summary must preserve the documented open Overtone/APF distribution decisions and must not imply the recovered evaluation compiler can process large modules.

### L1 — portable regression runner and evidence index

**Goal:** make the existing bounded HDL regressions easy to rerun and their results easy to archive, without changing testbench behavior.

**Inputs:** `docs/POCKET_IMPLEMENTATION.md`, `Pocket/rtl/psx_mem.f`, `Pocket/tb/tb_psx_mem.sv`, `Pocket/rtl/ram_320x240x15_dp.sv`, `Pocket/tb/tb_ram_320x240x15_dp.sv`, `Pocket/rtl/sram_ctrl.sv`, `Pocket/tb/tb_sram_ctrl.sv`.

**Owned files:** add `tools/pocket/run_regressions.sh` and `docs/POCKET_REGRESSION_EVIDENCE.md`. Runner should check for `iverilog` and `vvp`, build in a temporary directory, use bounded seeds/cycle counts, preserve per-test logs and return nonzero on compile or simulation failure. Evidence index records date, tool version, exact command/configuration, pass/fail, and report/log path; leave performance/resource fields explicitly unmeasured unless measured.

**Acceptance:** `tools/pocket/run_regressions.sh` runs the memory frontend bench at documented parameter sets, the RAM fixture at seed 3, and SRAM controller bench at seed 3 with 4000 operations, then writes a concise evidence record. Also verify missing-tool handling by invoking with an empty PATH while retaining shell utilities needed to start the script, or provide a deterministic self-check mode that exercises that error path. No waveform dumps by default and no unbounded full-console run.

### L2 — extend P02 cache fixtures at untested boundaries

**Goal:** extend the actual-source cache regression now available in `tools/sflc/tests/tb_caches.sv`. Basic suffix fills, tag replacement, reset and reverted-comparison detection are already done; do not duplicate them.

**Inputs:** `Cache_IR.sflp`, `Cache_Texture.sflp`, `tools/sflc/tests/tb_caches.sv`, `tools/sflc/tests/run_tests.py`, and [POCKET_SFLC.md](POCKET_SFLC.md). Compilation uses the experimental local compiler; independent sequential equivalence remains an L3 job.

**Owned files:** add `tools/sflc/tests/tb_cache_boundaries.sv`; coordinate a small runner hook with the compiler owner. Do not edit either cache SFL source or compiler semantics. Cover IR single-word writes and targeted clear, repeated whole-cache clears without reset, texture index 255, long request stalls, and reset at request/state boundaries. State expected timing from the source before writing each case. Keep texture bypass and concurrent clear/read outside the initial packet unless an L3 reviewer supplies their contract.

**Acceptance:** `python3 tools/sflc/tests/run_tests.py` plus the added bench pass with `--assertions` generated RTL. A deliberately wrong expected word or omitted clear must produce a nonzero failure. Record exactly which new cases ran. Compiler-based results are evidence for the source behavior, not proof of original-toolchain equivalence, BRAM inference, timing or hardware performance.

### L1 — stalled P00 build reproduction packet

**Goal:** isolate which build stages can run today and produce a reproducible blocker report for the active compiler owner.

**Inputs:** `Makefile`, `tools/sflc/ci_sfl2vl.sh`, `tools/sflc/probe/`, `docs/POCKET_P00_TOOLCHAIN.md`, and current `python3`, `iverilog`, `vvp`, `sflc.py` availability.

**Owned files:** add `tools/pocket/p00_probe_matrix.json` and `tools/pocket/check_p00_probes.py`; do not change `tools/sflc/sflc.py`, `sflp_parse.py`, probes, or compiler semantics. Matrix rows identify each probe/real source, required preprocessing, available compiler path, expected capability category, and observed status. The checker parses existing probe names and validates that every result includes the exact command, exit status, and first diagnostic or explicit PASS evidence. Never download proprietary tools, request licenses, or contact maintainers in this packet.

**Acceptance:** `python3 tools/pocket/check_p00_probes.py` exits 0 for a complete matrix and nonzero for an omitted probe or evidence field. Run the currently documented supported probes through `python3 tools/sflc/sflc.py` and Icarus only where the probe is in the documented supported subset; classify accepted local compiler output separately from independent oracle output; list unsupported constructs and missing oracle results with concrete prerequisites. Read POCKET_SFLC.md because many sequential probes now compile locally. The report must clearly separate successful parser/frontend checks from an end-to-end Pocket build, which remains blocked until all required stages and platform inputs are available.

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
