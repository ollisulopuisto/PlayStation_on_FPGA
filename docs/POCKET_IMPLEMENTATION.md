# Implementation checkpoint — 2026-10-11

## Saved changes

- `Pocket/rtl/psx_mem_fabric.sv`: one backend transaction at a time; one response slot per owner; separate urgent/fair round-robin pointers and bounded urgent preference; invalid-range/length rejection; zero-mask write completion; stable registered backend request; same-cycle backend acceptance/completion support; sticky unexpected-response flag.
- `Pocket/rtl/psx_mem_word_adapter.sv`: 1–8 halfwords to 1–5 aligned 32-bit commands, masks and odd-address alignment; one controller read outstanding; response buffering; tag checking; synchronous common reset. Writes complete after the controller accepts every effective word.
- `Pocket/rtl/psx_mem_frontend.sv`: connects those two modules, exposing a MIRLO-style word-controller interface. Does not instantiate a controller, PHY or CDC.
- `Pocket/rtl/psx_mem.f`: source list, paths relative to project root.
- `Cache_IR.sflp:103` and `Cache_Texture.sflp:153`: changed the second duplicated `offset==0` to `offset==1` in word-2 suffix-fill validity. Exact byte replacements preserved all other bytes, including CRLF and original comment encoding.

All files are saved in the workspace. No Git commit exists: this project folder is not a Git checkout. No MIRLO source was copied or changed.

## Compilation evidence

Icarus 13.0, executed from the project root. Each command below exited **0 with no diagnostics**:

```sh
iverilog -g2012 -Wall -s psx_mem_frontend -t null -c Pocket/rtl/psx_mem.f
iverilog -g2012 -Wall -s psx_mem_frontend -Ppsx_mem_frontend.N=1 -Ppsx_mem_frontend.URGENT_MAX=0 -Ppsx_mem_frontend.TAGW=1 -t null -c Pocket/rtl/psx_mem.f
iverilog -g2012 -Wall -s psx_mem_frontend -Ppsx_mem_frontend.N=7 -Ppsx_mem_frontend.URGENT_MAX=1 -Ppsx_mem_frontend.TAGW=5 -t null -c Pocket/rtl/psx_mem.f
```

These establish syntax/elaboration only. **No testbench was added or run; no behavioral simulation, synthesis, timing closure or Pocket measurement was performed.** The SFL fixes cannot be compiled with the currently available toolchain.

Earlier `/usr/bin/time -l` wrappers failed with `sysctl kern.clockrate: Operation not permitted`; no peak-memory figure was obtained. Plain compiler invocations above succeeded. Do not report the failed wrapper's exit status as an HDL failure or its output as reliable resource measurement.

## Controller review and assumptions

The inspected neighbor revision was `d5c714cca0c128d36295ef770cf0d891086d4889`. Its `rtl/soc/sdr_ctrl.sv:138–142` asserts `req_ready` when it schedules READ/WRITE; `dfi_wrdata_en` follows the write command. This supports the adapter's ordered write-acceptance interpretation by source inspection only. Physical visibility still depends on correct controller/PHY timing.

The controller returns reads through an `RL` pipeline, rather than directly using `dfi_rddata_valid`. Its clock/PHY alignment must be reproduced and constrained; changing frequency or RL speculatively can return the wrong data. Tie lookahead inactive initially if reusing the controller. Preserve source licenses and pin imported revisions.

## Next model: do this first

1. Read the actual RTL and `POCKET_MEMORY_CONTRACT.md`. Review ownership, packed byte ordering, odd-address five-word bursts, per-owner response stalls, non-power-of-two client counts and simultaneous accept/complete edges.
2. Under the active session's testing authorization, add a behavioral scoreboard and execute the contract's cases. Compilation is not proof of these behaviors.
3. Recover P00's SFL/compiler/platform dependencies. Keep P04 open until controller, legacy client adapters, CDC and internal DMA ownership are integrated.
4. Keep existing CPU/GPU stalls. The frontend is deliberately not wired into `Pocket/core_top.v`, and removing stalls now remains unsafe.
5. Validate the cache patches with all suffix offsets, replacement and reset once generated RTL can be built.

## Known limitations

- This conservative implementation serializes backend bursts and individual read words. It is a correctness foundation, not a demonstrated throughput optimization.
- A stuck backend stalls further requests. Wrong-tag reads set a sticky fault and are ignored. There is no timeout/recovery mechanism; safe recovery requires quiescing/resetting the entire transaction path.
- Constant read tag zero is valid only while this adapter exclusively owns its controller response stream. Do not merge a second direct controller requester behind it.
- All blocks share one clock and common reset. Independent producer/controller reset, stale responses across reset, loader CDC and APF traffic buffering are unresolved integration work.
- `N >= 1`, `URGENT_MAX >= 0`, `TAGW >= 1` are required parameter constraints. No synthesis resource budget has been measured.
- No error/timeout input exists at the word-controller interface; `rsp_error` reports invalid requests, not physical SDRAM failures. Sticky protocol flags need system-level handling.
- No rendered-frame or FPS improvement has been measured. P02 and P04 are **not complete**.

## Behavioral validation of the frontend — 2026-10-11 (Icarus 13.0)

Bench: `Pocket/tb/tb_psx_mem.sv` (self-checking, no waveform dump). Run from the project root:

```sh
iverilog -g2012 -s tb_psx_mem [-Ptb_psx_mem.N=.. -Ptb_psx_mem.URGENT_MAX=.. -Ptb_psx_mem.TAGW=..] -o tb.vvp -c Pocket/rtl/psx_mem.f Pocket/tb/tb_psx_mem.sv
vvp tb.vvp +seed=<n> +cycles=<per-phase cycles, default 6000>
```

Covered: N clients with random requests (len 0–15, even/odd addresses, random/full/zero/out-of-length byte masks, reads, writes) checked against a halfword reference model; low region and the exact top of the 64 MiB aperture; invalid length/address; zero-effective-mask writes; backend ready 20–100 %, read latency 0–7 incl. same-cycle result; response stalls (including one client consuming at 2 % while others progress); consume and accept on the same edge; urgent saturation with the starvation bound checked per client; random resets under load (reference resynced, no stale response accepted); controller request held stable under backpressure; no zero-enable write commands; sticky fault on an unexpected read result, cleared by reset.

Results: **PASS** for N/URGENT_MAX/TAGW = 1/0/1, 2/1/2, 6/4/3, 7/1/5, 3/8/4, each with seeds 1–4 at +cycles=3000; default config also passed at 6000 cycles. Max observed wait equalled the proposed bound N·(URGENT_MAX+1)−1 in every config (the bound is tight, not violated). Five hand-made mutants (adapter odd-shift removed, zero-mask word not skipped, address limit off by one, urgent counter not reset, fair pointer not advanced) were each caught.

**No RTL bug was found.** Not covered: fabric `b_rsp_valid` without a request (not reachable via the frontend), controller-specific timing (refresh, turnaround), reads with latency overlapping a following command (adapter issues one read at a time), CDC, synthesis, timing, bandwidth. Fairness bound is in selections, not cycles. Wall time was not measured (`/usr/bin/time -l` is blocked here).
