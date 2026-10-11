# P04 proposed memory contract

Status: **isolated RTL implemented and elaborated; behavioral and hardware validation outstanding**. See [implementation record](POCKET_IMPLEMENTATION.md). The legacy top is not connected.
Read [the checkpoint](POCKET_START_HERE.md) for repository/tool status.

## Why this interface comes first

The current top combines loader/core signals with OR gates and returns shared acknowledgements. CPU/GPU overlap requires an accepted request to retain its identity until its own result is delivered. A generic arbitration block alone does not fix broadcast acknowledgements within `PlayStation_core.sflp`.

The initial implementation should favor explicit ownership over speculative throughput: one transaction active at the backend, with a separate completed-response slot per client. A client that stops consuming its response must not block other clients once its backend work is complete.

## Client-side signals

All signals below use one fabric clock. Clock-domain adapters are outside this contract.

| Signal | Width | Meaning |
|---|---:|---|
| `req_valid`, `req_ready` | 1 each/client | Request accepted exactly at the rising edge where both are high |
| `req_write` | 1/client | Read = 0, write = 1 |
| `req_addr` | 25/client | Physical **16-bit halfword** address in the 64 MiB SDRAM aperture |
| `req_len` | 4/client | Literal halfword count, **1 through 8**; zero is invalid |
| `req_wdata` | 128/client | First requested halfword in bits 15:0; subsequent halfwords ascending |
| `req_mask` | 16/client | One enable per byte of `req_wdata`; relevant only for writes |
| `req_urgent` | 1/client | Scheduling hint, never unlimited priority |
| `rsp_valid`, `rsp_ready` | 1 each/client | One response per accepted request; held until consumed |
| `rsp_rdata` | 128/client | Read data packed from the requested address in ascending byte order |
| `rsp_error` | 1/client | Invalid request or reported backend failure |

Client index is the owner ID; do not derive ownership from the address. Start with named IDs for CPU/BIOS, DMA, GPU, scanout, loader and reserved SPU, but review actual master boundaries during integration. CPU and BIOS may share an adapter only while it guarantees that their requests cannot overlap.

Rules:

1. A stalled requester holds valid and all payload fields stable until acceptance. After acceptance it removes/replaces the request; holding it through completion must not cause duplicate acceptance. Legacy adapters own this translation.
2. Initially each client has at most one accepted request whose response has not been consumed. A response slot can be reused on the edge its old response is consumed if RTL handles that case explicitly.
3. Every read and write receives exactly one response, except transactions cancelled by the common reset. Request acceptance is not write completion.
4. Invalid lengths and accesses beyond the 64 MiB aperture return an error without issuing memory commands. Validate the end address at sufficient width so arithmetic cannot wrap.
5. For writes, ignore mask bits outside `2 * req_len` bytes. A zero effective mask is a successful no-op. Read response bytes outside the requested length are zero.
6. Within a client's accepted sequence, requests execute in order. Initially there is only one backend transaction at a time, so transactions cannot interleave at halfword boundaries.
7. This arbitration order does not itself implement PS1 DMA priority, cache coherency, GP0 ordering or CPU exceptions. Those remain responsibilities of the master adapters and system scheduler.

## Backend-side signals and ownership

Use the same transaction payload with a single ready/valid request and a single ready/valid response. Retain the selected owner and the complete request in registers before issuing to the backend.

Suggested states:

- **IDLE:** choose an eligible client and latch its request/owner on acceptance.
- **ISSUE:** hold the backend request stable until accepted.
- **WAIT:** wait for backend completion, then deposit the result into that owner's reserved response slot.
- Return to IDLE after completion has been stored; do not wait for that client to consume the stored response.

Support a backend response coincident with its request acceptance, or explicitly forbid it in both blocks and document the minimum response latency. Do not accidentally drop that edge case by only looking for results in WAIT. Responses without an accepted request are a protocol error, never an acknowledgement to another owner.

Initially keep address/data/control registered even if that costs bubbles. Measure the result before adding pipelining. Later multiple outstanding requests require tags/credits and response capacity reservation at request acceptance; increasing queue depth alone is insufficient.

## Bounded urgency without starvation

One implementable starting policy:

- Maintain a round-robin pointer for **fair** selections across all eligible clients.
- Maintain a separate pointer for expedited urgent selections.
- Permit at most `URGENT_MAX` consecutive expedited transactions. Then force one fair selection when any client is eligible, regardless of urgency flags, and reset the expedited counter.
- Expedited selections must **not advance the fair pointer**. Otherwise a repeatedly urgent client can make every fair turn select the same neighbor and starve later clients.
- Do not concatenate unlimited requests under one grant. Each initial transaction is bounded to eight halfwords.

An always-eligible client is selected within at most `N * (URGENT_MAX + 1)` selections under this policy. This is a transaction bound, not a clock-cycle deadline. To translate it into scanout buffering, establish a backend maximum latency including refresh, row changes, turnarounds and adapter overhead. A client waiting for its old response to be consumed is not eligible.

Start with `URGENT_MAX = 4` as a tunable proposal, not a proven video bandwidth allocation. Scanout/SPU deadlines need measured worst cases. A backend that never completes requires a system recovery policy; silently timing out and reassigning ownership permits late responses to corrupt a later transaction.

## Width adapter to a MIRLO-style 32-bit controller

The neighbor's `sdr_ctrl.sv` consumes **24-bit 32-bit word addresses**, 32-bit write data and four byte enables. It returns tagged read words. Its handshake semantics and physical timing must be reviewed before reuse.

Proposed conservative adapter, one burst at a time:

1. Latch and validate the halfword transaction. Compute `first_word = req_addr >> 1` and `halfword_offset = req_addr[0]`.
2. Compute `word_count = (halfword_offset + req_len + 1) >> 1`. An odd-start eight-halfword burst touches **five**, not four, aligned words.
3. For writes, zero-extend the 128-bit payload to 160 bits and shift it left by 16 bits for an odd starting halfword. Zero-extend the bounded 16-bit byte mask to 20 bits and shift it left by two mask bits for that same offset. Issue each aligned word using its four mask bits; skip words with zero enables.
4. For reads, request those aligned words and gather them into a 160-bit buffer. A first implementation may wait for each word's result before issuing the next. Shift the gathered result right by 16 bits for an odd start, then retain only the requested bytes.
5. Keep all controller request fields stable under backpressure. Handle same-cycle read acceptance/result if the backend permits it. If only one controller read is outstanding, a constant tag is sufficient; confirm returned tag ownership before accepting data.
6. Report write completion only once all effective words have crossed the controller's ordered write-commit boundary. Confirm that `req_ready` means a write command was actually scheduled and later accepted reads observe it; merely entering another queue is not sufficient evidence without an ordering guarantee.
7. Reads/writes crossing a physical row are split into aligned word commands. Row/bank/refresh legality belongs to the SDRAM controller, not an assumed flat latency in this adapter.

The full burst read buffer and shifting mux are candidate area costs. Inspect synthesis before using variable shifters throughout; fixed halfword shifts plus indexed word lanes may map better. No fit or throughput claim exists for this proposal.

## Legacy integration hazards

- Old wrapper address units are already halfwords: WRAM at byte `0x00000000`, VRAM at byte `0x00200000`, BIOS at byte `0x01000000`. Preserve these until a separately reviewed map change.
- Existing byte/halfword loads apply lane shifting using saved `psx.Word`/`psx.A`. Audit their interaction with normalized packed responses; an extra shift can return the wrong byte.
- Some old clients hold requests until ack; others issue a pulse. A held-request adapter needs a busy/rearm policy. A pulse adapter needs a capture register/FIFO and an explicit overflow/backpressure contract.
- Do not directly treat `sdram_ack` as `rsp_valid`. Its idle/accept/complete semantics are unknown because the original controller source is absent.
- Loader APF traffic and the memory fabric are in different clock domains. A synchronizer on a strobe does not make its address/data coherent. Queue or bundled-data handshake design is P03 and must match APF's actual ability to pause traffic.
- Reset the fabric, adapter, controller and producer-side transaction tracking together. Clear pending valid bits. Require backend quiescence before new work, or use an explicit epoch mechanism to reject stale responses. A fabric-only reset is not safe.
- Do not remove CPU stalls until internal WRAM/DMA completion demultiplexing, GP0 command buffering and guest timing have also been handled.

## Evidence required before calling P04 complete

These are future acceptance requirements, not executed tests:

- A scoreboard of accepted requests, memory effects and exactly one correctly owned completion per request.
- All lengths 1–8, even/odd halfword starts, every byte mask lane, row boundaries, invalid length/address and zero-mask writes.
- Simultaneous masters; request stalls; response stalls on one client while others progress; concurrent consume/refill edges; zero/minimum/variable backend latency.
- Continuous urgent traffic while every ordinary client remains active; show the actual maximum transaction wait against the policy bound.
- Common reset during request issue, backend wait and held responses; verify that no stale response is attributed to new work.
- Controller-specific refresh, read/write turnaround and write/read visibility.
- Synthesis area/timing plus mixed-load sustained bandwidth and maximum scanout service gaps.

Only after those results and live integration exist should the roadmap mark P04 complete. Follow the active user's testing authorization before adding or running benches.
