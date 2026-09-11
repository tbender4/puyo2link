# Handoff: Puyo Puyo 2 Arcade 4-Player Link — Reverse Engineering & Emulation

**Read this first**, then read `re_notes/COMM_PROTOCOL_SPEC.md` in full for
the complete technical record (it's long but is the authoritative source —
this file is just a fast-orientation summary and pointer to what to do
next). If a memory/checkpoint tool is available, also check for prior
session memories tagged with this project.

## What this project is

Puyo Puyo 2 (Sega System C2 arcade board, 1994) has a real, undocumented
4-player link mode requiring a rare daughterboard almost nobody has. The
goal: reverse-engineer the protocol from the ROM alone (no real hardware
available) and build a working software emulation of it, so two MAME
instances on one PC can link and actually play 4-player, as a step toward
an eventual real hardware PCB. The user wants to keep pushing this forward
incrementally, testing live as we go.

## Where things stand (as of this handoff)

**Latest: plugin 0.6.0, spec Update 9 (section 14). MAME now runs.**
- **PURIST RX is implemented and paired-MAME/gameplay validated.** Separate
  hardware RX banks and credit feed the original ROM's `$18784-$1880e`
  copy loop. There are **no plugin game-memory writes**, ROM patches,
  protection bypasses, forced game flags or watchdog suppression.
- Preserves 0.5.0's distinct roles, exact TX capture, 255-byte capacity,
  reset-generation journals and FE barrier. RX ACKs handle arrivals
  during a credit read-modify-write without losing bytes.
- **298 callback/ROM assertions pass** with the existing GENie host.
  Removed the old repeated assertion that native RX must stay disabled;
  the lower count is not a reduced scope. The mock explicitly rejects
  any plugin memory write and now runs the complete RX copy model.
- `run_purist_exercise_20260911_03`: 120-second actual four-player pair,
  original ROM, input-only placement controller. **16 positive A→B and
  11 positive B→A attacks**, all positively counted at the native peer
  parser, with native accumulator writes and landed garbage in all four
  fields. Screenshots/RAM snapshots persist. No sequence errors.

**Missing-garbage investigation: do not misrepresent the root cause.**
- Latest manual run `run_live_20260911_142603`: user reports 1P garbage
  works but linked mode does not. The two captured four-player division
  inputs are 80/140 and 136/140, both zero quotients with protection zero.
  Later two-player inputs are 485/120 and 198/120, positive quotients.
  These inputs can include carried score remainder; do not sum them.
  Section 14 explains why these particular linked clears produce no
  attack before transport is involved. A larger linked chain is the
  next useful manual reproduction; do not change original thresholds.
- All four historical live streams parse cleanly. They contain **no
  positive attack quantities**, only `$8000` completion / `$ffff`
  no-update markers. The absence is upstream of transmitting positive
  attacks, not evidence that the bridge dropped/misrouted them.
- The old `accepted=0` logs were a **diagnostic PC-filter bug**:
  actual MAME write PC is `$1845e`, outside the old `$1845c` limit. Fixed.
- Original ROM hashes pass `mame.exe puyopuy2 -verifyroms`. The workspace
  patch changes only `$7850-$7853` (divisor consequence); it was NOT used.
  New gameplay traces show `$ffa026=0` and code checks passing naturally.
- **Control run `run_original05_exercise_20260911_04` uses the untouched
  backed-up 0.5.0 plugin and also produces positive attacks (9/16) and
  landed garbage.** Therefore the native-RX improvement is not a proven
  fix for the user's particular reported symptom. That historical cause
  remains unproven; do not invent an anti-piracy explanation.
- Ordinary score thresholds, splitting among other players, and
  countering can legitimately yield zero. A real exercise pop scored
  75 with divisor 120 and protection zero. Future manual failures need
  correlation with the new `[garbage-calculation]`, `[attack-state]`
  and accepted `attack=` records; never force flags.
- Pre-change plugin, full notes/handoff and all original live logs are
  preserved at `checkpoints\20260911_garbage_purist\`.
- Live repeated-reset testing also exposed **old taps surviving until
  GC and duplicating CONTROL writes**. Prestart now explicitly removes
  all old taps before reinstalling. Final 105-second run
  `run_purist_reset_20260911_06` verified two resets, exactly generations
  1→2→3, native `watchdog=1200` recovery in ~19.91 seconds each, resumed
  acceptance, no stream sequence errors. See section 13.7.
- Verified plugin/notes and all new test evidence are checkpointed at
  `checkpoints\20260911_purist_0_6_verified\`. All test processes exited;
  no unrelated process was stopped.

**Earlier live milestones (not yet revalidated with 0.5.0):**
- The actual in-game 4-player invite prompt (`もう一台に乱入するの？` —
  "butt in on the other cabinet?") has been triggered for real and
  confirmed visually on screen. This is genuine, working, software-only
  emulation of a feature that (per public record) almost nobody has ever
  gotten working, even with real hardware.
- A real manual recipe for triggering the link was found by the user:
  start cabinet A normally, THEN reset cabinet B (service button) — B then
  shows the invite. Simultaneous auto-start on both sides does *not*
  reliably trigger it.

**Historical UI questions / next manual validation:**
- After linking, the "recruiting participants" screen (`参加者募集中`)
  sometimes shows the SAME `PLAYER N OF 4` number on both cabinets (a real
  identity/numbering question, not yet root-caused).
- The previous “comm task disappeared” conclusion is **retracted**:
  `$186e0` is called from an interrupt at `$005d4`; parser/builder TCBs
  live at `$ffa580/$ffa5c0`, outside the old scan. The new diagnostics
  report these and actual pump/packet-acceptance counts.
- **Next:** reproduce the user's own missing-garbage scenario manually
  in a fresh folder with 0.6.0, recording a specific visible pop/chain.
  Four-player gameplay and attacks are now demonstrated by input-driven
  tests, but the exact historical numbering/setup symptom is not
  retrospectively explained by them.
- Shared reset generations and roughly 20-second native watchdog
  recovery are now live-tested. A reset can still exit the current match
  through normal game error handling; do not force game RAM to hide it.
- `$ffa530=$f8` is a local game-code write at `$801a`, NOT a direct RX
  store. New accepted-packet logs include received command/argument
  bytes; see section 12.4 before interpreting ready/go transitions.

## How to run it

No compiler is available in this environment (no gcc/clang/MSVC) — this is
all done via a MAME Lua plugin, no source changes or rebuild needed.

Two terminals, one per "cabinet" (PowerShell):
```powershell
cd C:\Users\tbend\mame
$env:PUYO2_LINK_SIDE = "A"          # "B" in the other terminal
$env:PUYO2_LINK_DIR = "C:\Users\tbend\mame\PuyoPuyo2\run_manual_01" # SAME new folder in both terminals
$env:PUYO2_AUTO_INPUT = "0"         # disables auto coin/start for full manual control; omit to let it auto-play through the first coin+1P+2P start
.\mame.exe puyopuy2 -plugin puyo2link -window -skip_gameinfo
```
For quick automated/headless correctness checks (not for watching the
screen): add `-video none -sound none -nothrottle -seconds_to_run 30`.

Logs and raw streams land in `PUYO2_LINK_DIR`. Choose a fresh folder for
each process pair; **do not delete old logs**. A new process refuses an
existing nonempty outgoing stream. Service/F3 reset in the same process
preserves append offsets. The legacy default `PuyoPuyo2\link_ipc` contains
historical logs and should not be reused.
Both cabinets should use 0.6.0. Preserve `.bin.wire` journals too: those are
now the authoritative generation-tagged transport, while `.bin` files
retain the raw payload bytes for analysis. Missing peers leave FE waiting.

Callback-only regression command (does not launch MAME):
```powershell
.\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
```

## Key files

- `PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md` — the full technical record.
  Read this fully; it has 14 numbered sections/updates, each documenting
  what was found, what was wrong initially and corrected, and why. Keep
  appending new "Update N" sections here rather than starting fresh notes
  elsewhere — this is the project's memory across sessions.
- `plugins/puyo2link/init.lua` — the actual working plugin. Heavily
  commented; comments explain *why*, especially around bugs that were
  found and fixed (several nasty ones — read them before changing this
  file, so you don't reintroduce something already fixed).
- `PuyoPuyo2/re_notes/dis_*.txt` — raw 68000 disassembly dumps from
  `unidasm` used during static analysis (see spec for which address ranges
  each covers).
- `PuyoPuyo2/puyopuy2_merged.bin` — the two interleaved 68000 program ROMs
  merged into one big-endian binary, for reuse with `unidasm` or any other
  68k tool. Regenerate via PowerShell if missing (see spec appendix).
- `PuyoPuyo2/checkpoints/<timestamp>/` — periodic full backups of
  re_notes + the plugin + session logs. Make a new one before any risky
  change, and whenever asked.
- `PuyoPuyo2/checkpoints/20260911_123314/` — complete pre-0.4.0 plugin,
  notes, handoff and original `link_ipc` logs/streams.
- `PuyoPuyo2/checkpoints/20260911_130556/` — complete pre-0.5.0 checkpoint.
- `plugins\puyo2link\transport.lua` — generation-aware IPC state machine.
- `re_notes\analyze_link.py` — read-only journal/application packet audit:
  `py PuyoPuyo2\re_notes\analyze_link.py <run_directory>`.
- `re_notes\exercise_link.lua` — optional input-only MAME exercise,
  screenshots and RAM snapshots. Add `-autoboot_delay 0 -autoboot_script
  PuyoPuyo2\re_notes\exercise_link.lua` only for automated testing; omit
  it for normal manual play. Never writes game memory.
- Python is available via `py`; use that launcher for standard-library
  ROM inspection rather than the old `python` Windows Store alias.

## Hard-won lessons (don't rediscover these)

- **Lua GC bug**: every tap/notifier handle (`install_read_tap`,
  `add_machine_frame_notifier`, etc.) MUST be stored in a variable at file
  scope, not inside a function's own local scope — otherwise MAME's Lua
  GC silently reclaims it within a few frames and everything just stops
  working with no error. Already fixed in the current plugin; keep new
  taps assigned to file-scope locals.
- **Lua 1-indexed table literals**: `{0,0,0,0,0,0,0,0}` gives you keys
  1-8, not 0-7. If code expects 0-based indices (this plugin does, to
  match hardware byte offsets), always build tables through the
  `fresh_slots()` helper, never a bare literal.
- Several address/bit-gating mistakes were made and fixed by testing live
  against the real ROM rather than trusting static analysis alone — see
  spec Updates 2-4 for the exact list. The general lesson: this ROM's
  behavior has enough undocumented subtlety that live testing catches real
  bugs static reading alone won't.
- `unidasm -basepc X -skip X` can start mid-instruction and produce a
  garbage first "instruction" before resyncing — don't trust the very
  first decoded line of a disassembly window if it looks like `dc.w
  $XXXX; ILLEGAL`.
