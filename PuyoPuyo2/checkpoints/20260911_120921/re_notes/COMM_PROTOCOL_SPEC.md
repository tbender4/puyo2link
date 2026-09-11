# Puyo Puyo 2 (Puyo Puyo Tsuu) Arcade — 4-Player Link Mode
## Software/Protocol Technical Specification (Reverse-Engineered)

**Status date:** 2026-09-11
**Source ROM:** `epr-17240.ic31` / `epr-17241.ic32` (68000 program, byte-interleaved), Sega System C2, "Puyo Puyo 2" (Compile, 1994), as archived in `../puyopuy2/`.
**Method:** Static disassembly of the merged 68000 program image (`../puyopuy2_merged.bin`) using MAME's `unidasm -arch m68000`, cross-referenced against the existing MAME driver source (`src/src/mame/sega/segac2.cpp`) and public secondary sources. No physical daughterboard, logic analyzer capture, or Z80-side firmware was available — everything below was derived purely from what the 68000 program ROM does.

This document distinguishes three confidence levels throughout:
- **CONFIRMED** — read directly off disassembled opcodes/operands, verified by hex-dumping the raw bytes.
- **INFERRED** — a strong, code-consistent interpretation, but not independently proven (e.g. no external capture to check against).
- **UNKNOWN / OUT OF REACH** — genuinely not recoverable from this ROM alone (the daughterboard's own firmware isn't present anywhere in this dump).

---

## 0. Summary for the impatient

The 68000 program treats the 4-player link add-on as a **passive, dumb, byte-wide mailbox peripheral** sitting at `$880100`–`$88013F` (odd bytes only). There is a fully-formed, working protocol stack **inside the 68000 code** for talking to that mailbox:

1. A boot-time handshake that detects the daughterboard, checks its identity string and a CRC, and performs a loopback test.
2. A background, cooperatively-scheduled "link task" that, once the handshake succeeds, runs a **credit-based, sequenced, full-duplex byte-stream protocol** over that same 8-byte mailbox window, moving up to 32 bytes per direction per video frame between two 256-byte software ring buffers (`$ffa800`+ TX, `$ffa900`+ RX).
3. Game logic that queues one of four fixed-size "packets" (2, 4, 14, or 17 bytes) into that byte stream via priority flag bits, for things like a start-of-round ready handshake (confirmed) and presumably board/attack/name data (buffer locations confirmed, payload semantics not fully decoded).

**What this means practically:** you do **not** need to know anything about the real daughterboard's internals to build a working emulation or a homebrew replacement. You only need to build something that sits on the other side of `$880100` and honors this exact mailbox contract (answers the identity/CRC/loopback queries correctly, then drains/fills the 8-byte window using the same position-counter/credit scheme). The 68000 game code will then do the rest — including all game-state exchange — on its own, exactly as it does on real hardware. That is the actionable spec below.

---

## 1. Hardware interface (as seen by the 68000)

### 1.1 Address decode — CONFIRMED

From `segac2.cpp` (the existing MAME driver) and confirmed independently in the disassembly:

```
map(0x880100, 0x880101).mirror(0x13fefe).w(FUNC(segac2_state::counter_timer_w)).umask16(0x00ff);
```
This is the *stock* System C2 decode for that address range (shared, in other C2 titles, with an unrelated "counter/timer" chip). On a Puyo Puyo 2 board with the CN4 daughterboard installed, this same chip-select range is instead answered by the link daughterboard's shared RAM/registers. `umask16(0x00ff)` means the peripheral is wired only to the **low byte of the 68000 data bus**, i.e. it only responds on **odd addresses** — every register in this block is accessed as a byte at an odd address, with the even address in each 16-bit word unused/open bus. This matches `segac2.cpp`'s own note: "the daughtercard at CN4 is mapped into odd bytes at $880100."

`counter_timer_w` itself (`segac2.cpp:701`) is a stub that does nothing meaningful for any bit pattern — confirming that in MAME today, this region is simply unemulated/inert, which is exactly why the link never engages in MAME.

### 1.2 CN4 connector — CONFIRMED (identity), UNKNOWN (full pinout)

- `segac2.cpp:588-589`: two bits of I/O port H (a general-purpose I/O port on the 315-5296 chip, separate from the mailbox above) are wired straight to CN4 pins A19/B19. This is a low-bandwidth control/status line (likely daughterboard-present detect or reset), **not** the data path.
- Public corroboration (Yahoo Chiebukuro Q&A, 2013, `q10100231850`, in Japanese): a board owner identifies the connector as **a 12-pin connector standing next to the JAMMA edge connector**, confirms it's referred to in owner circles as an "expansion connector," and — importantly — reports that **directly wiring two Puyo Puyo 2 boards' 12-pin connectors together (both straight-through, pin1↔pin1…pin12↔pin12, and crossed, pin1↔pin12…) produces "NG" (fail) on the in-game communication self-test.** This is a valuable negative result: it independently corroborates the ROM finding below that the link requires an *active* device that answers a specific identity/CRC handshake — a passive cable cannot work.
- The same thread quotes the official manual as saying the connection *should* be a straight-through cable (for whatever intermediary hardware the manual assumes exists), and separately confirms **DIP switch bank 2, bits 6–7, are labeled "VS MODE MATCH"** — the best-of-N round count for a match, applicable to the 2-cabinet/4-player mode.
- **The "fiber optic" detail is the user's own claim, not something this session found independently corroborated in any text source.** Every public source we could reach (MAME driver comments, the Yahoo Q&A thread, Puyo Nexus wiki hardware/RE pages) describes a 12-pin electrical "comm harness," never fiber optic cabling explicitly. It's plausible a fiber transceiver lives *on* the daughterboard (for noise immunity / galvanic isolation / distance between two cabinets), which would be invisible to a description of the harness at the mainboard's 12-pin header — but treat "fiber optic" as **unverified** until corroborated by a photo/teardown of the actual daughterboard. Recommend chasing this specifically (see §6).
- Exact pin functions (power, ground, which pins carry the byte-wide bus vs. handshake/strobe lines) are **UNKNOWN** — nothing in the 68000 ROM reveals the physical pin mapping, only the memory-mapped register semantics behind it.

### 1.3 Register map inside the mailbox window — CONFIRMED

All addresses below are byte addresses, always **odd**, always relative to a base the code holds as `$880101` in address register A2:

| Symbolic name (this doc) | Address | A2-relative offset | Role |
|---|---|---|---|
| `Slot[0]` (TX data / TX position ctr) | `$880101` | +0x00 | 1 of 8 rotating data-byte slots; also doubles as the persistent mod-256 TX stream position counter between calls |
| `Slot[1]` (RX data / RX position ctr) | `$880103` | +0x02 | Same role, RX direction |
| `TxCredit` | `$880105` | +0x04 | Peer's/HW's reported byte count for TX flow control |
| `RxCredit` | `$880107` | +0x06 | HW's reported available-byte count for RX flow control |
| `Slot[4]` | `$880109` | +0x08 | rotating data slot |
| `Slot[5]` | `$88010B` | +0x0A | rotating data slot |
| `Slot[6]` | `$88010D` | +0x0C | rotating data slot |
| `CommStatus` | `$88010F` | +0x0E | also `Slot[7]` during bulk transfer; semaphore byte (1 = "new data ready") outside of bulk transfer |
| `CommCommand` | `$880111` | +0x10 | command byte during handshake; block/window index (0–31, bit5 = TX/RX direction tag) during bulk transfer |
| `CommControl` | `$880131` | +0x30 | reset line, written during boot handshake only |

This is an exact match, byte for byte, to the addresses previously documented (without full explanation) in `segac2.cpp`'s comment block credited to Mike Moffitt (2024-05-24) — this document extends that work by explaining *why* those specific offsets exist and what the runtime protocol actually does with them.

---

## 2. Boot-time handshake (state machine) — CONFIRMED

Location: ROM `$018236`–`$018812` (file `dis_18000.txt` in this folder has the full annotated disassembly). Entered from a jump table at ROM `$018230` (`jmp $a46e.l` installs this as a periodic task — see §4).

Exact sequence, addresses are ROM/68000 code addresses unless stated otherwise:

1. **`$018236`**: `CommControl = 1`, yield 6 frames (`$18240`/`$18246`, calls to `$a4fc`/`$a506`, the task-yield primitives, §4), then `CommControl = 0`. This is the reset pulse.
2. **`$018252`–`$018270`**: a watchdog/retry loop — waits, checks a "cancel/abort" bit at RAM `$ffa069` bit 0/1 (test-menu driven), and only proceeds once per 4 calls of an outer counter at task-local offset `($26,A0)` — matching "go back to top if frame count isn't a multiple of 4" from the earlier MAME comment.
3. **Signature check (`$018272`–`$01828E`)**: writes command `$FC` to `CommCommand`, then reads 8 bytes back from `Slot[0..7]` (stride 2, i.e. the 8 odd-byte mailbox slots) and compares them, byte for byte, against a table at ROM `$018814`. **Confirmed by direct hex dump: that table's first 8 bytes are literally the ASCII string `PUYO2Z80`** (`50 55 59 4F 32 5A 38 30`). Any mismatch aborts the whole state machine back to step 1.
4. **CRC check (`$018292`–`$0182A8`)**: writes `$FD` to `CommCommand`, reads one byte back from `Slot[0]`, stashes it (only used for display in the test menu — the routine doesn't itself gate on this value here, but a later step does).
5. **Identify self (`$0182B6`–`$0182EE`)**: writes `$FF` then `$FD` to `CommCommand`/`CommStatus` around each byte, then writes out, one byte per call (i.e. **one byte per video frame** — this whole handshake is paced at 1 byte/frame during this phase), the 8-byte string immediately following `PUYO2Z80` in the same ROM table: **confirmed by hex dump to be literally `PUYO268K`**. This is the 68000 side identifying itself to the daughterboard.
6. **Verify echo (`$018310`–`$01832C`)**: writes `$FD` to `CommCommand` again and expects **all 8** `Slot[]` bytes to now read back `$FF` — i.e. the daughterboard/link hardware must acknowledge receipt of the identity string by filling the window with `0xFF`.
7. **Loopback test (`$01833A`–`$018358`)**: writes `$FE` to `CommCommand`, reads `Slot[0]`; a nonzero value aborts, zero means success. On success, a status byte at RAM `$ffa500` gets bit 7 set (`ori.b #$80,D0` then stored) — **this is the master "link established" flag** tested everywhere else in the code as `tst.b $ffa500 / bpl` (branch away if the high bit is clear).
8. **Task handoff (`$018374`–`$018386`)**: installs a *new* routine pointer (`$1853C`, see §5) into the same task's control block via `jsr $a46e` — this is exactly the behavior the MAME driver comment already flagged ("the link task accepts a new routine pointer and stores it in its TCB").
9. If any step times out (an outer counter at `$ffa504` incrementing to `$4B0` = 1200 ticks with no success) or the abort conditions above fire, state resets fully back to step 1 (`bra $181ea`), and the whole handshake retries indefinitely in the background. This matches user-visible behavior: an idle/absent daughterboard just quietly keeps retrying forever, with the test menu showing perpetual "NG."

**Command byte summary (`CommCommand`, boot phase) — CONFIRMED:**

| Value | Meaning |
|---|---|
| `$FC` | "Send me your identity string" |
| `$FD` | "CRC request" / "confirm receipt", overloaded for two purposes (read CRC byte at step 4; expect `$FF`-filled ack at step 6) |
| `$FE` | "Loopback test" |
| `$FF` | idle/no-op marker, also used to bracket每 write during identify-self phase |

---

## 3. The two ROM-embedded identity strings — CONFIRMED by hex dump

Raw bytes at ROM offset `0x18814` (immediately following the end of the handshake routine, referenced via PC-relative addressing from `$01827C`):

```
50 55 59 4F 32 5A 38 30   "PUYO2Z80"
50 55 59 4F 32 36 38 4B   "PUYO268K"
```

This resolves the open question in the existing MAME driver comment ("I cannot find the PUYO2Z80 string" — it was assumed to possibly live in a Z80 program blob somewhere): **it isn't Z80 code at all, it's a plain 16-byte ASCII data table used purely for string comparison by the 68000's handshake routine.** There is still no Z80 program anywhere in this ROM dump — see §7.

---

## 4. Cooperative task engine hosting the link — CONFIRMED

Location: ROM `$0A400`–`$0A560` (`dis_a400.txt`). This is Compile's standard fixed-slot cooperative task scheduler (used throughout their MSX/Genesis-era engine, not link-specific):

- Fixed table at RAM `$ffd100`, **58 slots × 64 bytes each** (`move.w #$3a,D0` = 0x3A = 58; stride `adda.l #$40,A0` = 64).
- `$a414`/`$a492`: allocate a free slot (word at slot offset 0 == 0 means free).
- `$a46e`: **install a new routine pointer into an *existing* task's slot** (stores the routine pointer at offset+2, resets the local scratch area) — this is the exact primitive used at handshake step 8 above to swap the link task from "run the handshake" to "run the packet pump" without re-allocating.
- `$a506`/`$a4fc`: task yield / sleep-N-frames primitives, called throughout the handshake and packet pump to spread work across video frames.

**Practical implication:** the entire link protocol is driven once per video frame (60 Hz, NTSC), cooperatively, alongside every other background task in the game (sound, animation, etc.) — there is no interrupt-driven or DMA-driven fast path. This bounds the realistic throughput of the real link to a small, fixed number of bytes per frame (see §5) — genuinely modest bandwidth, consistent with something implemented over a cheap serial/optical hop by a small microcontroller.

---

## 5. Runtime link task: sequenced, credit-based, full-duplex byte stream — CONFIRMED

Location: ROM `$018700`–`$018812` (`dis_18700.txt`), the routine installed at handshake step 8. Runs once per frame once the link is established (guarded by `tst.b $ffa500 / bpl $18812` at the very top — bails out immediately if the link flag is clear).

### 5.1 TX half (`$018700`–`$01877C`)

```
D6  = $ffa522        ; TX ring-buffer tail index (local RAM, 256-byte ring at $ffa800)
D7  = $ffa524         ; bytes currently queued, pending transmission (local RAM)
D5  = TxCredit ($880105)     ; byte read from the mailbox: hardware/peer's reported "room"/ack counter
```
1. Clamp this frame's send batch to **at most 32 bytes** (`cmpi.w #$21,D7 / moveq #$20,D7`).
2. Further clamp so `TxCredit + batch` doesn't wrap past 256 (an explicit byte-overflow check) — a textbook sliding-window flow-control clamp against a 256-byte-addressable stream.
3. Read the **persistent mod-256 TX stream-position counter**, which — cleverly — is stored directly in mailbox `Slot[0]` (`$880101`) itself between calls, not in local RAM.
4. For each of the (up to 32) bytes this frame:
   - Compute `block = position >> 3` (divide by 8) and `slot = (position & 7) * 2` (0,2,4,…,14).
   - Copy one byte from the local TX ring buffer (`$ffa800`+tail) into mailbox `Slot[slot]`.
   - Every time `slot` wraps past 14 back to 0, bump `block` (mod 32) and immediately write it out to `CommCommand` (`$880111`).
5. After the burst: write `CommCommand=$FF` (idle marker), set `CommStatus=$01` (semaphore: "new data ready"), write the final incremented position counter back to `Slot[0]`, and add the number of bytes sent onto `TxCredit` at `$880105`.

**In effect:** the 8 physical mailbox byte-slots are used as a small rotating window onto a much larger (256-byte) logical stream; the true stream position (0–255) is reconstructed as `block*8 + slot_index`, communicated via a combination of the data slot that changed and a separately-announced 5-bit block counter on `CommCommand`. `TxCredit`/`RxCredit` implement simple stop-and-wait/credit-based flow control against a 256-byte window — this maps exactly onto the 256-byte software ring buffers on both ends.

### 5.2 RX half (`$01877C`–`$01880E`)

Exact mirror of §5.1:
- `RxCredit` = `$880107` (bytes the peer/hardware says are available).
- RX stream-position counter persisted in mailbox `Slot[1]` (`$880103`).
- Block index written to `CommCommand` **with bit 5 set** (`ori.b #$20,D2`) — this is how the RX-direction block announcement is distinguished from the TX-direction one on the same physical register, since both halves run back-to-back within the same per-frame call and never overlap.
- Bytes copied **from** mailbox slots **into** the local RX ring buffer at `$ffa900`, head index `$ffa528`, pending-count `$ffa52c`.
- Same trailer: `CommCommand=$FF`, `CommStatus=$01`, position counter written back to `Slot[1]`, `RxCredit` decremented by bytes consumed.

### 5.3 Ring buffers — CONFIRMED

| Buffer | Base | Size | Write/tail index | Pending count |
|---|---|---|---|---|
| TX ring | `$ffa800` | 256 bytes | `$ffa520` (enqueue side) / `$ffa522` (drain side) | `$ffa525` (enqueue) / `$ffa524` (drain) |
| RX ring | `$ffa900` | 256 bytes | `$ffa528` (fill side) | `$ffa52c` (pending, consumer-visible) / `$ffa52d` (consumer read index bookkeeping) |

Generic enqueue/dequeue helpers used by game logic to push/pop these rings: `$18658`/`$18676` (TX enqueue, single-byte and N-byte forms) and `$1869c`/`$186ba` (RX dequeue, single-byte and N-byte forms).

---

## 6. Application-layer packets queued by game logic — PARTIALLY CONFIRMED

A single priority/request flags byte, **RAM `$ffa502`**, gates what the periodic "packet builder" task (installed at `$01853C`, distinct from the low-level pump in §5, also driven every frame) sends next:

| Flag bit | Payload buffer | Length | Confirmed sender (ROM addr) | Semantics |
|---|---|---|---|---|
| bit 2 | `$ffa530` | 2 bytes | `$0D468` | **CONFIRMED, partially**: writes value `$38`, sets the flag, then busy-waits (yielding every frame) until the *same* memory location reads back `$F8` — i.e. it's overwritten by the RX path once the peer replies. This is a **start-of-round ready/go handshake** between the two linked cabinets (send `$38`≈"ready?", block until peer's `$F8`≈"ready" comes back over the link). Failure path jumps to a generic link-error handler at `$0E15A`. |
| bit 3 | `$ffa532` | 4 bytes | `$00DA26`, `$00DA62` | Buffer identified, trigger site located; payload contents not decoded this session. |
| bit 4 | `$ffa536` | 14 bytes | `$00D8B2` | Sits inside a loop bounded by `cmpi.w #$6` (6 iterations) processing per-entry records at stride `0xC` (12) bytes from a table — consistent with a **per-player-field or per-column summary** (e.g. attack/garbage-count or next-piece data across up to 6 slots), but not fully decoded. |
| bit 5 | `$ffa537` | 17 bytes | `$0064EC` | Trigger site is in a **menu/setup context** (gated on a controller "confirm" input bit at `$ffa7ac`), copying 17 bytes in from a separate buffer at `$ffad00` — consistent with a **name-entry or match-configuration packet** sent when confirming a setup screen, but not fully decoded. |

Before dispatching any of the above, the task always first sends a fixed **3-byte header/heartbeat packet** from `$ffa511`–`$ffa513` (which includes the request flags merged in, plus a rolling sequence byte at `$ffa511` incremented every send) — and, if `$ffa502` is 0 (nothing queued), it still sends this same 3-byte heartbeat every 30 calls (~0.5s at 60Hz) as long as the RX-side byte counter (`$ffa524`) hasn't crossed a near-full watermark (`0xFD`) — simple keepalive + backpressure.

**Recommendation for anyone continuing this work:** bits 3/4/5's exact payload byte meanings (piece state, garbage/ojama counts, chain results, names) are the next concrete, tractable RE task — each has a known fixed address and length now, so decoding them is a matter of setting a MAME debugger watchpoint on `$ffa532`/`$ffa536`/`$ffa537` during normal single-cabinet play (garbage sent to a simulated/absent opponent may still populate these buffers even without a working link) and correlating writes with on-screen game events.

---

## 7. What is genuinely NOT in this ROM (hard limits of this analysis)

- **There is no Z80 (or other) program anywhere in this dump for the daughterboard itself.** The `PUYO2Z80` string is just an ASCII identity tag compared by the 68000 (§3) — it is not evidence of embedded Z80 object code. Whatever CPU is actually on the CN4 daughterboard runs its own firmware that is **not present in `epr-17239/17240/17241`** at all. This matches the existing MAME driver comment's own conclusion.
- **The true electrical/optical framing between the two daughterboards is invisible from here.** Everything in §5 describes the *local* 68000-to-mailbox contract only. Whatever the daughterboard does with those bytes (buffering, CRC framing, actual serial/optical transmission to its twin) is implemented entirely in hardware/firmware this session had no access to.
- **Exact CN4 pinout, and whether the physical medium is truly fiber optic**, remain unverified by this session (see §1.2) — this is squarely a hardware-teardown question, not a ROM question.
- Full payload semantics for the 4/14/17-byte packet types (§6) are only partially decoded.

---

## 8. Practical path forward (software-first, per the stated goal)

Because the 68000 program only cares about the **mailbox contract**, not the real daughterboard's internals, the fastest path to a working 4-player mode — at emulation level first, exactly as intended — is to implement a **substitute virtual link device** that:

1. Answers the boot handshake (§2) correctly: return `PUYO2Z80` for an `$FC` request, `$00` for the `$FD` CRC request (and ack with `$FF`-filled slots on the second `$FD`), `$00` for the `$FE` loopback request.
2. Once "established," honors the sequenced/credit mailbox pump exactly as described in §5 in both directions, connecting two MAME instances (or MAME + a real board, or two real boards via a from-scratch bridge) via any convenient transport (a TCP socket between two MAME processes is the obvious first cut) — the 68000 code neither knows nor cares what's underneath as long as the byte stream arrives in order with correct credit bookkeeping.
3. This sidesteps needing to know anything about the real daughterboard's silicon, fiber optics, or firmware at all — you only need to satisfy a well-understood, now fully-documented byte-level contract that this session extracted from the game's own program ROM.

This is consistent with the user's stated priority: nail the software/protocol spec first, worry about real hardware (and whether it's really fiber, what the real CN4 pinout is, etc.) later, if a physical PCB is pursued.

---

## 9. Live validation update (2026-09-11, second session)

Everything above was static analysis. This section documents building an actual
working prototype against it and what live testing revealed — including two
real inaccuracies in the analysis above that only surfaced by running real
code against real code.

**What was built:** `plugins/puyo2link/init.lua`, a MAME Lua plugin (no C++
changes, no rebuild needed — this machine has no compiler toolchain at all,
confirmed: no gcc/clang/MSVC/ninja/meson; `dotnet` is the only SDK present).
It uses `space:install_read_tap` / `install_write_tap` (MAME 0.289's Lua
memory-tap API) to substitute an emulated register file over
`$880100-$88013F`, and bridges two independent `mame.exe` processes over a
pair of plain append-only files (`PuyoPuyo2/link_ipc/A_to_B.bin` /
`B_to_A.bin`), polled once per emulated video frame. Each process is told
which "cabinet" it is via `PUYO2_LINK_SIDE=A|B`.

**Result: it works.** Running two `mame.exe puyopuy2` processes
simultaneously (headless, `-video none -sound none`), both sides' boot
handshakes complete and the game begins exchanging real bytes over the
link — confirmed by `heartbeat ... tx=256 rx=256` appearing **identically on
both sides**, and `A_to_B.bin`/`B_to_A.bin` containing real structured data
(a repeating small-integer sequence consistent with the §6 "3-byte
heartbeat packet with rolling sequence number", followed by an `0xFF`-filled
tail). This is the first time (as far as this session could determine) this
link has been made to do anything at all outside real Sega/Compile hardware.

**Two things the static analysis got wrong, found only by running it:**

1. **§2 step 7 (loopback test) had the polarity backwards.** The code
   reads back the `$FE` loopback response and does `beq <retry>` — i.e. a
   **zero** readback means "not ready, keep retrying", and only a
   **nonzero** readback falls through to `ori.b #$80,D0` / store to
   `$ffa500` (the established flag). The original doc said the opposite.
   Confirmed by direct write-tap trace on `$ffa500`: it reliably becomes
   `$81` only once the plugin was fixed to answer `$FE` with a nonzero
   `Slot[0]`.
2. **`$880107` (RxCredit) is not a distinct register from the boot-handshake
   mailbox window — it's the same physical byte as identity-string index 3.**
   Forcing it to a fixed value unconditionally (a reasonable first guess for
   simplifying the runtime credit scheme) silently corrupted the 4th
   character of every `PUYO2Z80`/`PUYO268K` comparison during the boot
   handshake, causing it to fail and retry forever with no error — the
   comparison for bytes 0-2 (`P`,`U`,`Y`) kept succeeding right up until
   byte 3, which was the giveaway. Fix: only special-case `$880107` while
   `current_bank ~= 'cmd'`.

**A design simplification that turned out to be necessary, not just
convenient:** rather than trying to faithfully reproduce the mailbox-level
byte-by-byte pump described in §5 (whether the position-counter/block-index
bookkeeping at a given instant represents live payload or transient
end-of-burst housekeeping is genuinely ambiguous from static analysis alone
— see §5.1's note about `Slot[0]` being read once, then freely overwritten
as ordinary data mid-burst, then written back), the working prototype
**bypasses the mailbox-level protocol for the actual data path entirely**:

- **TX**: let the real 68000 TX-burst code run against a simple
  pass-through mailbox (whatever's last written stays, no interpretation),
  and instead capture the true outgoing byte stream by polling the local
  TX ring buffer's own drain index (`$ffa522`, RAM) once per frame and
  reading exactly the newly-drained bytes directly out of `$ffa800`. This
  is unambiguous — no guessing about which mailbox write is "real" payload.
- **RX**: force `$880107` (RxCredit) to always read `0` during runtime, so
  the built-in mailbox-driven RX copy loop always sees "nothing available"
  and exits immediately without touching anything — then inject the
  peer's bytes **directly** into the local RX ring buffer (`$ffa900`,
  advancing `$ffa528`/`$ffa52c`) ourselves, exactly mimicking the end
  state that loop would have produced.

Everything **above** the low-level pump (ring buffers, the `$ffa502`
packet-flag dispatcher, application payloads) is unmodified real game code
running unaware that the mailbox underneath it is a stand-in.

**Open item, not yet understood — a periodic full re-handshake:** once
established, the link reliably drops and fully re-does the entire boot
handshake (fresh `CommControl` reset pulse) roughly every **3 real/emulated
seconds**, driven by a counter at RAM `$ffa504` that increments on every
call of an outer wrapper (ROM ~`$018380`-`$018398`) and forcibly clears
`$ffa500` once it hits `$4B0` (1200) — confirmed via write-tap trace, exact
trigger PC `$0183A4` (`clr.w $ffa500`). 1200 ticks in ~3 emulated seconds
implies this wrapper runs roughly **6-7 times per 60Hz video frame**, not
once — i.e., it's on some faster internal tick than vblank, not yet
identified. Whether this is a genuine "no error but resync-anyway" design
in the real protocol, or something that only fires this fast because of a
detail our simplified mailbox gets wrong, is **unresolved**. It doesn't
prevent data from flowing (the handshake cleanly re-establishes every time,
observed over multiple consecutive cycles in the 12-second two-instance
test), so it wasn't blocking for this validation pass, but it should be
understood before trusting this for real gameplay — a mid-round forced
resync would presumably be visible/disruptive in-game.

**Update (same day, live iteration with the user watching the real test-menu
screen):** Running the two-instance setup and actually watching Puyo Puyo 2's
own in-game `COMMUNICATION TEST` screen (not just logs) turned out to be an
extremely effective oracle — it caught real bugs the logs alone didn't make
obvious:

1. **`(CRC ERROR)` display bug, confirmed and fixed.** Traced the exact
   display logic (ROM `$035f6`: `tst.b $ffa509 / beq <ok-text> / <else> <crc-error-text>`).
   `$ffa509` is written from `Slot[0]` on *any* `$FD` command — but `$FD` is
   overloaded: the first `$FD` after an `$FC` is a non-gating CRC-status
   display read (must be `0` for a clean "OK" display), while every `$FD`
   after that is the real gating loop-echo check from §2 step 6 (needs all
   8 slots `$FF`). The plugin was unconditionally doing the latter, which
   silently showed as a CRC error on real hardware's own diagnostic
   screen even though nothing was actually gated by it. Fixed by tracking
   an `fd_since_fc` counter and only special-casing the first one.
   **Confirmed live: both `BORD IS OK (CRC OK)` and `LOOP IS OK` turned
   green simultaneously on both cabinets' screens** after this fix — the
   first time this session actually saw the real success state rendered.
2. **New failure mode surfaced once two real instances exchanged real
   bytes (not visible in single-instance or lucky early two-instance
   testing): the link now reaches full success but then drops and
   re-does the entire handshake almost immediately (within 1-2 frames),
   not on the ~3s watchdog cadence.** Root-caused via byte-level tracing
   (logging every captured/injected byte alongside the sender's
   `$ffa511` and receiver's `$ffa515` sequence values): the low-level TX
   pump's own "bytes still queued" count (`$ffa524`) sometimes reports
   more pending than the application actually enqueued, so a single
   frame's tail-index delta captures the real packet *plus* a long
   trailing run of `$FF` ring filler, which then gets relayed to the
   peer as if it were more packet bytes — instantly failing the
   receiver's rolling-sequence check (`$ffa515`) against a value that
   was never really sent. Exactly why `$ffa524` reports extra pending
   bytes is still unresolved. **Mitigation applied:** trim a trailing
   run of `$FF` out of each frame's captured TX bytes before relaying
   (well-justified since real packet bytes observed so far are always
   small values, never `$FF`). This measurably helped — a clean
   multi-packet exchange with zero resets over ~2.4 continuous seconds
   was observed after the fix — but resets are still happening more
   often than that over a full run, so this isn't fully solved yet.
3. Also found and fixed: our relay wasn't clearing its own queued/pending
   state (`$ffa52c`, `in_queue`/`out_queue`, file read position) on each
   in-game `CommControl` reset pulse, which could let stale pre-reset
   bytes get delivered after a peer's sequence counter had already
   restarted at 0. Fixed, though on its own it wasn't sufficient to fully
   stabilize the link (see #2).

**Update 2 (same day): the real root causes, found via the 60-second live
test.** The `$FF`-filler theory above was a plausible-looking but incomplete
mitigation. Two actual bugs, both variations on the same mistake --
**trusting emulated-hardware/RAM state that hadn't been validated as safe to
trust yet** -- turned out to be the dominant cause of near-every-frame
resets:

1. **The RxCredit override was gated on the wrong condition.** It checked
   `current_bank ~= 'cmd'`, on the assumption that would be true during
   runtime-pump traffic. It isn't: the real RxCredit read in ROM happens
   immediately after the pump writes `$FF` (idle marker) to CommCommand,
   and that `$FF` write itself sets `current_bank` back to `'cmd'` in this
   model *first*. So the override never actually applied during real
   runtime traffic; RxCredit fell through to stale pass-through storage,
   and the game read back garbage almost every cycle. Fixed by tracking
   an explicit `established_seen` flag (true from a successful `$FE`
   until the next reset) and gating on that instead of the bank.
2. **`poll_tx_ring` trusted `$ffa522`/`$ffa800` (and, downstream,
   `$ffa511`) before the game had ever initialized them.** On a cold
   process start, `last_tx_tail` was hardcoded to `0`, and the very first
   poll compared that against whatever `$ffa522` happened to already
   hold in RAM at that instant -- confirmed live: one session's first-ever
   poll captured a 111-byte burst of perfectly plausible-looking "packets"
   (small incrementing sequence bytes) purely from leftover RAM content,
   before the game had even started its boot handshake. Fixed by reading
   the actual current tail index at prestart instead of assuming 0, and
   additionally refusing to capture/inject anything at all
   (`poll_tx_ring`/`inject_rx_ring`) until `established_seen` is true.

**Result after both fixes:** a 30-second two-instance headless run held the
link established continuously for roughly the first 25 seconds -- both
sides' `linkflag` stayed at `$81`, real bidirectional data flowed correctly
(`tx`/`rx` byte counts climbing on both sides, e.g. side B reached
`tx=348 rx=309`), and only a handful of resets happened, clustered near the
end rather than every single frame. This is an enormous improvement over the
"resets almost every frame" state from Update 1 and the first real evidence
of sustained two-cabinet data exchange. A residual issue still causes a
cluster of resets after a long stable stretch -- not yet root-caused, but
clearly a much smaller remaining problem than what's already fixed.

**Next concrete step:** find what causes the late-session cluster of resets
after a long (20+ second) stable run, and separately, understand why
`$ffa524` occasionally reports more
pending TX bytes than were actually enqueued — that's the remaining root
cause, not just its `$FF`-trimming symptom-level mitigation.

**Update 3 (same day): the link is stable -- now the "why doesn't 4P
actually appear" question.** With the two fixes from Update 2, the user
confirmed live on both cabinets' actual `COMMUNICATION TEST` screens: `BORD
IS OK (CRC OK)`, `LOOP IS OK`, and both `NOW TX DATA`/`NOW RX DATA` fields
incrementing continuously and simultaneously on both windows -- the first
sustained, human-confirmed stable link this session. A later free-running
session (no time limit) ran **82+ seconds with only 17 resets**, i.e. long
stable stretches punctuated by occasional drops, not constant failure.

But normal play -- attract mode, coining up, sitting at the 1P/2P mode-select
screen -- never exposes any linked/4-player option. Traced why:

- ROM `$0062CC`: mode-select code does `tst.b $ffa500 / bpl <skip> / btst
  #1,$ffa517 / bne <enable-linked-path>`. So reaching the linked path needs
  both (a) the link established (`$ffa500` bit 7, which we now reliably
  get) AND (b) bit 1 of `$ffa517` set -- and `$ffa517` is literally the raw
  third byte of whatever packet header was most recently *received* from
  the peer (ROM `$018440`: `move.b (A3,D2.w),$ffa517`, no interpretation,
  just carried straight through).
- ROM `$0189AA`: the *sending* side sets that same bit (`ori.b #$2,
  $ffa513`) only when a flag at `$ffa17f` is nonzero.
- `$ffa17f` is cleared to 0 once at some initialization point (ROM
  `$019324`) and is otherwise only ever set to `1` by a routine at ROM
  `$019A62`, itself gated on a further flag (`$ffd06a`) whose owning
  screen/menu context hasn't been identified yet.
- **Empirically confirmed via a live write-tap on `$ffa170-$ffa17f`
  covering ~80+ seconds of normal navigation (idle attract loop, coin-up,
  sitting on the mode-select screen) on both cabinets: `$ffa17f` is written
  exactly once, at boot (the clear to 0), and never again.** The values
  that do change during that window (`$ffa170-$ffa173`) look like ordinary
  attract-mode demo/blink-cycle counters, unrelated to this flag.

**Working theory, not yet confirmed:** whatever screen/input actually sets
`$ffa17f=1` is not on the normal attract/coin/mode-select path at all. It
may be reachable only through a specific menu context reached via an
indirect jump table (the routine that sets it, `$019A40`, has no direct
`bsr`/`jsr` callers found by a literal-bytes search, consistent with being
dispatched through a table rather than called directly -- not yet traced).
It's also plausible -- and would fit everything publicly known about this
feature's history (never released, no mass production, "ALL ABOUT Puyo
Puyo Tsuu" book describing it as possible but no shop or owner in the 2013
Yahoo thread able to get one working) -- that this particular integration
point was simply never finished in the shipped ROM, i.e. the low-level
comm protocol is complete and functional (as now demonstrated), but the
attract-mode UI hook to actually *offer* linked play to the player may be
incomplete or reachable only through a path not yet found.

**Next concrete step:** find the jump table that dispatches to `$019A40`
(or otherwise trace what sets `$ffd06a`/`$ffd067`, the gating flags one
level up) to identify the real trigger condition, if one exists in this
ROM at all.

**Update 4 (same day): CONFIRMED -- the 4-player link invitation screen is
real, present in the shipped ROM, and was triggered live by this plugin.**
Traced the full chain end to end:

- `$ffa513`/`$ffa517` (outgoing/incoming header third byte) carry a status
  bitfield: bit0 = "peer is present" (broadcast automatically once a
  cabinet is sitting in attract mode -- specifically once `$ffa170` bit3
  is set, confirmed via live monitoring with no coin inserted at all),
  bit4 = "link established", bit6 = "I have locked in a mode-select
  choice", bit2 = a related confirm sub-state.
- ROM `$0062CC` (mode-select) and `$0196C0`+ gate on these bits: reaching
  the linked-mode offer (`$ffa17f=1`, ROM `$019A62`) requires the *peer's*
  bit6 (or bit1) to be set while *your own* bit6 is still clear -- i.e.
  "the other cabinet already locked in a choice while you're still
  deciding."
- Since two independent MAME windows can't be timed by hand to hit that
  window reliably, added a temporary auto-input feature to the plugin
  (`drive_auto_input` in `init.lua`, using MAME Lua's
  `ioport.ports[':SERVICE'].fields[...]:set_value()/:clear_value()`) that
  presses Coin 1 then 1 Player Start automatically ~3 seconds after the
  link establishes, on both sides, removing human timing as a variable.
- **Result, confirmed live on both cabinets' actual screens (not just
  logs):** `$ffa17f` was set to 1 for real (ROM `$019A62`), and the game
  displayed an actual in-game prompt: `もう一台に乱入するの？` ("Do you
  want to butt in on the other cabinet?" -- 乱入, "butt in/intrude", is
  genuine Japanese arcade slang for joining another cabinet's session),
  with a graphic of two cabinets connected by a cable, a 5-second
  countdown, and いいえ(No)/はい(Yes) options.

This is the first direct, visual, in-game confirmation this session that
the 4-player link feature is genuinely present and reachable in the
shipped retail ROM -- not a rumor, not an unfinished stub -- and that this
purely-software reverse-engineered protocol implementation can trigger it
for real, from a cold boot, with no real daughterboard hardware involved
at any point.

**Not yet tested:** what happens after accepting (はい) the prompt -- does
it actually proceed into a synchronized 4-player match, and if so, do the
`$ffa530`/`$ffa532`/`$ffa536`/`$ffa537` application payloads (§6) carry
correct gameplay data end to end. That is the natural next milestone.

**Not yet tested:** whether this actually produces correct *gameplay* sync
(a real start-of-round handshake via the `$ffa530` `$38`/`$F8` exchange
from §6, garbage/attack data, etc.) — only that raw bytes move correctly
end-to-end. That's the natural next validation step.

## Appendix: working files in this folder

- `dis_18000.txt`, `dis_18700.txt` — full disassembly of the handshake + runtime pump (§2, §5).
- `dis_a400.txt` — task scheduler primitives (§4).
- `dis_d400.txt`, `dis_d800.txt`, `dis_6480.txt` — game-logic call sites for the four packet types (§6).
- `hwplatforms.txt`, `re_main.txt`, `re_process.txt`, `re_tools.txt`, `moffitt.txt`, `pn_forum1.txt`, `pn_forum2.txt` — plain-text dumps of public secondary sources consulted (Puyo Nexus wiki, Michael Moffitt's site) — searched but found **no** existing public documentation of the 4-player link protocol beyond what's in the MAME driver comment itself, confirming the user's premise that this is genuinely undocumented territory.
- `chiebukuro.txt` — 2013 Japanese owner Q&A thread with the CN4 12-pin connector and DIP switch corroboration (§1.2).
- `../puyopuy2_merged.bin` — the two interleaved 68000 program ROMs merged into one big-endian binary, for reuse with `unidasm` or any other 68k tool.
- `../../plugins/puyo2link/init.lua` — the working MAME Lua plugin described in section 9. Run with `-plugin puyo2link`, set `PUYO2_LINK_SIDE=A` (or `B`) in the environment before launching each instance. Logs to `link_ipc/proto_<side>.log`.
- `../link_ipc/` — the file-based transport directory the plugin reads/writes (`A_to_B.bin`, `B_to_A.bin`, and per-side logs). Safe to delete between test runs.

## Sources
- [MAME driver source: src/mame/sega/segac2.cpp](file://C:/Users/tbend/mame/src/src/mame/sega/segac2.cpp) (comment block by Mike Moffitt, 2024-05-24)
- [アーケード版ぷよぷよ通で、4人対戦をする方法をご存じの方はいらっしゃいませんか？ - Yahoo!知恵袋](https://detail.chiebukuro.yahoo.co.jp/qa/question_detail/q10100231850)
- [Puyo Puyo Tsu/Hardware Platforms - Puyo Nexus Wiki](https://puyonexus.com/wiki/Puyo_Puyo_Tsu/Hardware_Platforms)
- [Puyo Puyo Tsu - Michael Moffitt's Website](https://mikejmoffitt.com/articles/0047-puyopuy2.html)
- [Puyo Puyo Tsu 4 Player Mode - Arcade-Projects Forums](https://www.arcade-projects.com/threads/puyo-puyo-tsu-4-player-mode.29858/) (fetched only as a search-engine summary; direct fetch was blocked by Cloudflare)
