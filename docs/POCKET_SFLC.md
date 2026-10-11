# Experimental SFL compiler — 2026-10-12

The replacement compiler now generates **the actual `Cache_IR.sflp` and
`Cache_Texture.sflp` sources** and runs them in a bounded behavioral regression.
This unblocks isolated cache validation without the proprietary toolchain.
It does **not** yet build the console, establish sequential equivalence to
sfl2vl, or qualify a Pocket bitstream.

## Implemented boundary

`tools/sflc/sflc.py` emits SystemVerilog (`iverilog -g2012`). It supports:

- Existing left-to-right combinational expressions and guarded AND/OR selection.
- Resettable, set-on-reset, explicitly initialized and resetless registers;
  synchronous assignments, increments/decrements and supported compound operators.
- Local instruction input/output/self terminals, explicit or combined argument
  declarations, invocation argument wiring and `instruct` guards.
- Statically sized memory with one selected physical write port, registered or
  combinational reads as specified by the source, and optional initialization.
- Lexically distinct local wires/registers, declaration after use, `switch`,
  `any`, `alt` with or without `else`, and implicit zero on inactive selectors.
- Single-task stages, captured register arguments, common actions, state guards,
  `goto` and `finish`.
- Constant width arithmetic, slicing expression results through sized temporary
  wires, bit reversal and sign extension including constants and expressions.

The language author's [SFL+ notes](https://pgate1.at-ninja.jp/memo/SFLP/)
provide the source semantics for register reset variants, parallel assignments,
local instruction arguments, lexical locals, memory initialization and stages.
The old [sfl2vl probe artifacts](POCKET_P00_TOOLCHAIN.md) remain the independent
oracle for the already-tested combinational subset. The implementation and
scoreboards here are newly written; licensed generated reference files are not
included in this repository.

Scopes are resolved before generating hardware. Registers preserve their values
when no assignment is enabled. A `reg` without an initializer has no synthesized
reset; memory initialization happens once, not on `p_reset`. Multiple guarded
writers select the address and data together, avoiding accidental multiport RAM
from separate procedural assignments. No synthesis evidence yet proves BRAM
inference or area savings.

`--assertions` adds simulation-only failures for simultaneous data/register
writers, multiple memory writers, and unverified stage regeneration while busy.
Control terminal invocations may OR their activation conditions. Assertions
check exercised traffic; they are not a static proof of mutually exclusive
writers. Use this option for block validation.

## Exact stage qualification limit

Each stage has a resettable active bit. A generation loads task arguments and
activates the stage on the next edge. States are initialized on reset, updated
by `goto`, and retained while inactive. The cache sources explicitly return to
their first state before `finish`; the regression tests that pattern and repeated
completed transactions. Stateful and stateless clear stages are both exercised.

**Retained-state restart without a return `goto`, generation while already
active, and simultaneous generation/finish remain unverified against sfl2vl.**
Do not use the compiler for live integration of a block relying on those cases.
Busy generation trips the optional assertion; without it, the emitted active
bit gives generation priority, which is an implementation choice awaiting
reference validation. Multiple tasks per stage and nested stages are unsupported.

The archived `p13_stage` produced **no reference Verilog**: its input-terminal
`instr_arg` was rejected. Earlier presence of the probe was not evidence for
stage semantics. New `p17_registers`, `p18_controls`, and `p19_stage` use native
syntax without that input-terminal declaration. They elaborate through our
compiler; they are inputs for the **next** archived-compiler run, not claimed
oracle results. Each is well below the evaluation limit. Do not compact or split
large modules to evade that limit.

## Reproduce local evidence

From the project root, with Python 3, Icarus and vvp on PATH:

```sh
python3 tools/sflc/tests/run_tests.py
```

Executed successfully with Python 3.12 and Icarus 13.0. Nine test groups pass:

| Evidence | Result and scope |
|---|---|
| Parser | Existing source corpus still parses; no SFL source bytes changed by this work |
| Sequential scoreboard | 4,000 cycles: reset variants, holds, parallel register updates, memory initialization/read-before-write, local register independence, task arguments, stalls, completion, repeated starts and reset interruption |
| Numeric scoreboard | 65,536 input pairs: carry, truncation, reversal, sign extension, negation, shifts, priority selection and inactive zero |
| Actual generated caches | 242 checks: all suffix offsets/words, data alignment, multiple indices including IR index 255, tag replacement, explicit IR clear, texture startup clear, response waits, hits/misses and reset during an outstanding texture miss |
| Cache mutations | Reverting the word-2 offset comparison in each temporary source copy causes the expected behavioral failure |
| Error handling | Invalid assignments, undeclared signals, invalid widths/slices/cases/tasks, unsupported constructs and exercised conflicting writers are rejected |
| Lexical scope | Sibling locals with identical spelling are independent; forward local declarations resolve |
| Elaboration only | 19 real leaf modules and 18 supported `p*` probes; two unsupported probes fail explicitly |

The texture bench supplies responses only after the request has crossed an
accepting clock edge. It does not establish compatibility with a same-cycle ack
or with the missing legacy SDRAM controller. Cache bypass mode, concurrent
read/clear/refill, every address, and full-system memory ordering are not covered.
The test runner uses temporary directories, bounded subprocess timeouts, and
nonzero exit codes on failure. Mutations never edit the original cache files.

For optional comparison against the archived reference output directory:

```sh
python3 tools/sflc/cosim.py --reference-dir /path/to/sfl2vl-probe-out
```

Executed with seed 1 and 4,000 vectors each: **all nine pass** (`p01`, `p03`,
`p04`, `p09`, `p11`, `p12`, `p14`, `p16`, and real `bsr_s16`). `p11` has no data
inputs, so it is a repeated constant-output check. The runner generates vectors
in Python, checks output widths, supports arbitrary input widths, and fails on
missing references, simulator failures, mismatches or missing PASS markers.
References were recovered from the earlier local `ci2/sfl2vl-probe-out` scratch
artifacts. This is combinational equivalence only.

Both caches also passed **Verilator 5.052 lint without warnings**:

```sh
python3 tools/sflc/sflc.py --assertions Cache_IR.sflp > /tmp/Cache_IR.sv
python3 tools/sflc/sflc.py --assertions Cache_Texture.sflp > /tmp/Cache_Texture.sv
verilator --lint-only --top-module Cache_IR /tmp/Cache_IR.sv
verilator --lint-only --top-module Cache_Texture /tmp/Cache_Texture.sv
```

`.github/workflows/sflc.yml` adds the local regression to CI without downloading
the proprietary compiler. The workflow was written but **has not run remotely**.

## Next hard work, in order

1. **L3: sequential oracle closure.** Run p17–p19 through the archived compiler,
   fix only native syntax if required, then compare bounded cycle traces. Expand
   the probes to stage idle restart, finish/generate overlap and argument capture.
   Keep unknown cases rejected/asserted until evidence determines their behavior.
2. **L3: typed expression audit.** Extend reference probes for decimal sizing,
   mixed-width arithmetic, overflow before slicing and sign-extension contexts.
   The numerical fixture is strong regression evidence, not a complete language
   specification. Do this before trusting GTE/CPU arithmetic.
3. **L3: hierarchy linking.** Resolve `%i` interfaces, `declare interface` leaf
   ports, instances, `instruct sub.ack` and expressions containing invocations.
   Share one interface representation with argument wiring. Prove handshake and
   data behavior on a tiny two-module fixture before enabling the real CPU/GPU.
4. **L3: constant generators and remaining constructs.** Implement compile-time
   `par/any/alt` expansion and separately establish `join` ordering. Preserve
   lexical instance/local names. String literals and `bus`/bidirectional
   semantics also remain unsupported. Unsupported input must keep failing.
5. **L3: platform/controller integration.** Return to P03/P04 once P00 can build
   the hierarchy. Do not infer safety from these isolated tests or remove stalls.

`DMA_CDR.sflp` currently fails on undeclared `dbg32` and `DMA_SPU.sflp` on
undeclared `size_mul` under default defines. Determine intended build defines
and original source intent before changing them; do not create implicit wires.

Smaller independent packets live in [POCKET_MODEL_HANDOFF.md](POCKET_MODEL_HANDOFF.md).
P00 remains open. P02 has actual-source behavioral and mutation evidence under
this experimental compiler, but original-toolchain equivalence, synthesis and
hardware acceptance remain open. No bandwidth, game speed or FPS claim follows
from any result here.
