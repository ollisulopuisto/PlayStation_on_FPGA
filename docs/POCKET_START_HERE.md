# Session checkpoint — start here

Updated 2026-10-11. Workspace: `/Users/dst/Documents/koodi/PlayStation_on_FPGA-master`.

## User objective and current priority

Improve this PS1 FPGA core for Analogue Pocket: correct game speed and approximately **30 newly rendered frames/s** in selected simple original PS1 games, then add sound. Video first; preserve resources and service capacity for later audio. The user authorized implementation of the toughest work, then requested this checkpoint so other models can continue efficiently.

The user wants tasks sized for delegation, with the minimum useful model capability identified. Use the existing L1/L2/L3/H tiers; do not spend time researching model brand rankings.

## What actually exists

| Deliverable | Status |
|---|---|
| [Roadmap](POCKET_ROADMAP.md) | Written: evidence, dependencies, P00–P16, model tiers, acceptance |
| [Benchmarks](POCKET_BENCHMARKS.md) | Written: scenes, real-time/frame accounting, result schema |
| [Model handoff](POCKET_MODEL_HANDOFF.md) | Written: dispatch order, reusable implementation prompt |
| [Memory contract proposal](POCKET_MEMORY_CONTRACT.md) | Written at handoff; implementation proposal, not validated RTL |
| Icarus Verilog | **Installed**, version 13.0; `iverilog -V` and `vvp -V` executed successfully |
| New RTL | Three isolated SystemVerilog modules and a source list written; three Icarus elaboration configurations passed |
| Cache fixes | Both duplicated offset comparisons corrected; SFL compilation and behavioral validation outstanding |
| Simulation, synthesis, timing, hardware measurements | **Not performed in this session** |

After the first checkpoint, the user authorized using the remaining budget. The isolated memory frontend is now implemented and elaborates with Icarus. See [POCKET_IMPLEMENTATION.md](POCKET_IMPLEMENTATION.md) for exact files, commands and limitations. It has NOT been simulated, synthesized or integrated into the Pocket top.

This folder is an extracted source snapshot, not a Git checkout. Existing SFL sources contain CRLF and non-UTF-8 comments; preserve their bytes/encoding when editing. The adjacent MIRLO64 tree has been changing during this session; recheck its revision and local changes before reusing files. Do not overwrite that work.

## Installed tools and resource concern

- `/opt/homebrew/bin/iverilog` and `/opt/homebrew/bin/vvp`: Icarus 13.0, installed by `brew install icarus-verilog` after explicit user authorization. Homebrew reported 54 files, **6.8 MB** installed. Both version commands succeeded.
- `sflp`, `sfl2vl`, `verilator`, and `quartus_sh` were not found on the current PATH. Do not confuse having a Quartus installer with having a working Quartus installation.
- Icarus runs on the Mac, not on Pocket. It consumes resources while compiling/simulating; installation is not a background service. The estimate given to the user for a small block simulation was approximately one busy CPU core and tens to a few hundred MB of RAM. **No workload measurement supports that estimate yet.** Full-system simulations can be much larger.
- No tests were added or run. Follow the active session's testing instructions; if simulation is authorized, start with small bounded benches, no waveform dump by default, and measure with `/usr/bin/time -l`. Do not launch an unbounded whole-console run.
- Host memory/process queries were blocked by the sandbox; total Mac RAM and actual simulator peak RSS are unknown.

## P00 status (2026-10-11)

See [POCKET_P00_TOOLCHAIN.md](POCKET_P00_TOOLCHAIN.md): snapshot = upstream HEAD `e87165c42e` + P02 fix; `sflp` is unreleased, `sfl2vl` only via Overtone; APF platform files and `vjtag_uart` are recoverable from public repos. Blocked on contacting pgate1/Overtone (user decision).

## Next task: P04 integration (L3)

Update 2026-10-11: behavioral validation of the isolated frontend is done (`Pocket/tb/tb_psx_mem.sv`, passes, no RTL bug found; see POCKET_IMPLEMENTATION.md). Remaining: controller/CDC/legacy-client integration.


Read [the memory contract](POCKET_MEMORY_CONTRACT.md) and [implementation record](POCKET_IMPLEMENTATION.md), then review the existing fabric and adapter before behavioral validation and integration. The proposal intentionally allows only one transaction in flight at the backend initially, while holding completed responses separately for each owner. It is a correctness starting point, not the intended final bandwidth claim.

Implemented files, **not wired into the legacy top**:

1. `Pocket/rtl/psx_mem_fabric.sv`: owned requests, per-owner responses, bounded urgent preference, reset behavior.
2. `Pocket/rtl/psx_mem_word_adapter.sv`: legacy-sized halfword bursts to aligned, masked 32-bit commands suitable for a MIRLO-style controller.
3. `Pocket/rtl/psx_mem_frontend.sv`: connects fabric and adapter.
4. `Pocket/rtl/psx_mem.f`: root-relative compiler source list.
5. `docs/POCKET_IMPLEMENTATION.md`: exact compilation evidence and remaining work.

Do not wire speculative modules directly into the live top and call P04 complete. The old controller's ack protocol is unresolved, the SFL toolchain is absent, and the top's CDC/loader behavior needs separate treatment. Preserve the current CPU/peripheral stalls until ownership exists inside `PlayStation_core.sflp` too.

In parallel *as a separately assigned work packet*, recover P00's toolchain and missing build inputs. That packet is a prerequisite for end-to-end integration. This statement is a future delegation suggestion, not an instruction to spawn agents automatically.

## Exact blockers and evidence

### Build recovery: P00

- Root Makefile needs `sflp` and `sfl2vl`; generated source is not the authoritative edit target.
- Missing referenced sources include `ram_320x240x15_dp.sflp`, `view_ram_ctrl_one.sflp`, and `pseudo_cdrom_data.sflp`.
- Missing platform inputs include `sdram128_burstn_ctrl_100`, `main_pll_0002`, APF framework/top/bridge files, synchronizer definitions and external SRAM/UART headers. Recover exact versions or document replacements.
- No complete Pocket QPF/QSF/SDC project is supplied.
- `Pocket/core_top.v:655–659` connects BRAM-related interfaces whose declarations are commented out in `Pocket/core.sflp:34,40`.
- The supplied bitstream and historical fit report cannot be assumed to match the current source.
- Prior search found the original developer's site at `https://pgate1.at-ninja.jp/`. Its SFL+ development pages may help recover the compiler. The compiler was not recovered or installed.

### Memory ownership: P04

- `Pocket/core_top.v:673–678` OR-combines loader and core requests, including address/data/mask/burst. Overlap can corrupt commands.
- `Pocket/core.sflp:260,297` broadcasts SDRAM ack to WRAM and BIOS; internal DMA wiring also shares acknowledgements.
- `Pocket/core.sflp:304` tests ack as availability; GPU waits use ack as completion. Do not assume the missing controller produces a one-cycle done pulse.
- The controller runs at 100 MHz, core at 50 MHz; ack gets one register at `Pocket/core.sflp:112`. Request/data crossings need actual clock/constraint analysis.
- `PlayStation_core.sflp:177–195` prevents CPU execution during entire peripheral operations. Removing these stalls prematurely can corrupt RAM or lose GP0 commands.

### VRAM migration: P06

- Historical fit: **17,060 / 18,480 ALMs**, **307 / 308 RAM blocks**, **58 / 66 DSPs**. This is an old report, not a new measurement.
- Two 320×240×15 internal buffers account for 2,304,000 nominal bits. Removing them is the major RAM opportunity.
- Rendering does not currently keep PS1 VRAM authoritative: `drawRect` writes the view buffer; `drawPoly`/`drawFillRect` use view-buffer paths for on-screen pixels, with different VRAM treatment off screen.
- Therefore, external scanout alone is insufficient. Implement a VRAM pixel sink, migrate each renderer, establish texture invalidation/readback ordering, then retire full internal display buffers.
- Keep unique rendered-frame count, PS1 guest time, output refresh and display flips separate. “30 fps” must not mean slow-motion gameplay or repeated output frames.

### Cheap isolated defect: P02 (L2)

- `Cache_IR.sflp:103` and `Cache_Texture.sflp:153`: the second duplicated `offset==0` was changed to `offset==1`, using an exact byte replacement that preserved all other bytes.
- The fixes are written but not compiled or behaviorally validated; P02 is not complete.
- A complete fix needs offset 0–3 validity/alignment, replacement and reset coverage, not just a text edit.

## MIRLO64 findings

Read-only reference tree: `/Users/dst/Documents/koodi/MIRLO64`.

- Its game CPU is **MIPS VR4300-class**, not RISC-V. “RISC” is the broader architecture category; MIPS and RISC-V are different instruction sets.
- New downloaded files identified: `qinst-lite-linux-25.1std-1129.run` (126,095,050 bytes) and `cyclonev-25.1std.0.1129.qdz` (1,443,834,466 bytes). These are the Quartus Linux installer and Cyclone V device package. No RISC-V-named download was found in that tree.
- `rtl/soc/sdr_ctrl.sv`: tagged 32-bit word requests, byte masks, open rows, refresh and lookahead. Defaults are documented for about 62.832 MHz; do not copy them into a 50/100 MHz design unchanged.
- `rtl/soc/sdr_phy.sv`: useful physical interface, but preserve its license and retime/reconstrain its clock assumptions.
- `rtl/soc/sdr_arb.sv`: useful reference, but repeatedly selecting urgent clients can starve ordinary clients. A per-grant burst cap alone does not guarantee fairness.
- `rtl/soc/n64_video.sv`: external-memory scanout reference. Its 16,384×37 FIFO is not a small two-line buffer; budget it before reuse.
- `rtl/soc/psram.sv`: prototype, not evidence of a proven drop-in PSRAM replacement.
- Pocket audio code can inform later P05, but review FIFO empty/full handling and reset. Audio implementation remains deferred.
- Reuse needs original license notices and a pinned source revision; no MIRLO source has been imported into this PS1 project.

User's actual Pocket observations: Tony Hawk first level near 30 fps with small dips; Mario Kart fairly steady; “wave rider” runs (exact title unconfirmed); Star Fox runs, dips in heavy polygon scenes; Mario 64 runs. These are user reports, not reproduced tests, and are more informative about their installed core than README statements limited to simulated boot screens. They do not establish PS1 throughput.

The user also asked whether PSP would be easier. Answer: **PS1 is the more realistic target**. PSP adds substantially more CPU/vector/graphics work. Do not pivot to PSP or a RISC-V CPU replacement without a new user instruction.

## Copyable next-session prompt

```text
Continue the Analogue Pocket PS1 project in this workspace.
Read docs/POCKET_START_HERE.md and docs/POCKET_MEMORY_CONTRACT.md first.
Goal: correct-speed video at approximately 30 new frames/s in selected
simple original PS1 games, then audio. Do not claim a measured result.

Icarus 13.0 is installed. The isolated P04 fabric, word adapter and
frontend are written and elaborate in three configurations; no simulations
have run. Both cache offset typos are fixed but unvalidated. Read
docs/POCKET_IMPLEMENTATION.md, review the existing RTL and validate it
under current testing instructions before integrating the live top. Preserve the old source encoding. Track every unvalidated
assumption and follow current instructions concerning running tests.

The missing SFL compiler, SDRAM controller, platform files and complete
Quartus project still block end-to-end integration. Keep CPU/GPU stalls
until completion ownership and GP0 backpressure are actually integrated.
Update the checkpoint with changed files and exact validation evidence.
```
