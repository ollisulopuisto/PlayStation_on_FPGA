# P00 build recovery — dependency status and plan

Checked 2026-10-11. Evidence is from GitHub API queries and web search; pgate1.at-ninja.jp could not be fetched from this session.

## Snapshot identity

This folder equals upstream `github.com/pgate1/PlayStation_on_FPGA` HEAD **`e87165c42e`** (2026-10-06, "run parallel even during GTE/MUL/DIV processing"), compared by git blob hash after CRLF→LF normalization. The only differences are local edits:

- `Cache_IR.sflp:103`, `Cache_Texture.sflp:153` — the P02 `offset==0` → `offset==1` fix (upstream still has the bug).
- Upstream line 58/82 comments in those two files are double-encoded mojibake; the local copy has the original Shift-JIS bytes. Local is the better copy.

Upstream is active (4 commits on 2026-10-06). Rebase our work on upstream before integration; do not assume this snapshot stays current.

## Toolchain

| Tool | Status | Source |
|---|---|---|
| `sflp` (SFL+ → SFL + `.h` preprocessor) | **Not public.** pgate1 states it was never released | pgate1 NES_on_FPGA event page, "はじめてのSFL+" memo |
| `sfl2vl -O2` (SFL → Verilog) | **Not freely downloadable.** Bundled with Overtone's NSL Core; obtained by request. Evaluation build reportedly capped at 2,000 lines | pgate1 SNES page; pgate1 "論理回路考古学のススメ" PDF; ip-arch.jp has no download |
| Verilator | Used only for lint (`--lint-only PlayStation_core.v -y demo`) | Makefile |
| Quartus | Device 5CEBA4F23C8. Installer + Cyclone V package exist in MIRLO64 tree (Linux), not installed | — |

Largest single source: `GeometryTransformationEngine.sflp` 1,902 lines; total 13,671 lines across all `.sflp`. A 2,000-line per-file cap might fit pre-expansion, but this is unverified (cap semantics and post-`sflp` sizes unknown).

SFL+ features visible in sources (for scoping a replacement): `%i "x.h"` includes of generated interface headers, C-style `#ifdef/#define`, `circuit`, `sel`, `instrin name(args)` combined argument syntax, `instrout`, `instrself`, `reg_wr/reg_ws`, `mem`, `stage/stage_name/state/first_state/goto/generate/finish`, `par/any/alt/if/else`, `switch/case` (MDEC), `declare ... interface` for Verilog leaf modules.

## Missing build inputs

| Item | Used by | Status | Recovery |
|---|---|---|---|
| `apf_top`, `core_bridge_cmd`, `synch_3` (`common.v`), `io_*`, `mf_datatable`, `mf_ddio_bidir_12`, `pin_ddio_clk`, `apf_constraints.sdc`, `ap_core.qpf/.qsf` | `Pocket/core_top.v` | **Recoverable** | `github.com/open-fpga/core-template` `src/fpga/apf/*`, `src/fpga/core/*`. Pin revision; check Analogue license terms |
| `main_pll_0002` | `core_top.v:775` (74.25 MHz in → clk_50, dram_ctrl_clk, dram_clk, clk_25, clk_25_90deg) | Regenerable | Quartus PLL IP; exact frequencies/phases are not in the source except names. `dram_clk` is also tied `'h0` at line 292 (driven twice — check) |
| `vjtag_uart.h` + `.v` | `Pocket/core.sflp` (`../../../hdl/USB-JTAG/DE0-CV/`) | **Recoverable** | `github.com/pgate1/USB-Blaster_UART` `DE0-CV/vjtag_uart.{h,v}`. Debug only; can likely be removed for Pocket |
| `sram_ctrl.h` + impl | `Pocket/core.sflp` (`../../../Pocket/`) | Missing, pgate1 private | Write a small async-SRAM controller (Pocket 256 KiB) to the interface implied by `core.sflp` |
| `sdram128_burstn_ctrl_100` | `core_top.v:680` | Missing, pgate1 private | Planned replacement anyway: MIRLO64 `sdr_ctrl/sdr_phy` behind `Pocket/rtl/psx_mem_frontend.sv` (P04) |
| `ram_320x240x15_dp.sflp/.h` | `view_ram_ctrl.sflp:4` | Missing, pgate1 private | Dual-port BRAM; easy to write in Verilog, but P06 plans to remove these buffers |
| `view_ram_ctrl_one.sflp`, `pseudo_cdrom_data.sflp` | Root Makefile only | Missing; no `.sflp` references them | Probably not needed for Pocket; drop from manifest |

Directory layout implied by include paths: `<root>/hdl/USB-JTAG/DE0-CV/`, `<root>/Pocket/sram_ctrl.h`, project at `<root>/<a>/<b>/Pocket/core.sflp`.

## Routes to a working build

1. **Ask pgate1** (best payoff, needs the user): request `sflp` or, failing that, the generated `.v` for the current HEAD plus `sram_ctrl`, `sdram128_burstn_ctrl_100`, `ram_320x240x15_dp`. Offer the P02 cache fix in return. The author is active.
2. **Request NSL Core/sfl2vl from Overtone** (non-profit license). Solves only the second stage; `sflp` still missing.
3. **Write our own SFL+ → Verilog compiler.** No third-party dependency, but large (a full SFL semantics implementation: stages/tasks, control-terminal activation, `any/alt` priority, `mem` inference) and impossible to validate against a reference compiler without route 1 or 2. Validate against the DE2-115 `.sof`/Pocket bitstream behavior only indirectly.
4. **Abandon SFL for new work:** keep SFL modules frozen as generated Verilog (needs 1 or 2 once) and write all new blocks in SystemVerilog. Already the roadmap's direction.

Recommendation: route 1 now; start route 3 only as a parser feasibility spike (parse all 13.7k lines, enumerate constructs) if route 1 gets no answer.
