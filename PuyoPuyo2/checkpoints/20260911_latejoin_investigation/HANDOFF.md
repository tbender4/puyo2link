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

**Latest: plugin 0.6.1, spec Update 11 (section 16). Linked gameplay and
garbage are user-confirmed working with the original ROM.**

- On 2026-09-11 the user confirmed: "garbage did indeed work i just
  didn't play it enough." The missing-garbage report is closed, not an
  outstanding protection or transport bug.
- Preserve `run_randomB_20260911_152913`: A was manual; B used random
  movement/rotation. A sent positive quantities 1 and 10. Earlier
  controlled runs demonstrate attacks both ways and garbage in all four
  fields, including the user's original 140-point parameter preset.
- The implementation uses distinct cabinet roles, banked TX/RX storage,
  255-byte credit limits, reset-generation journals and a mutual FE
  readiness barrier. The original CPU performs all game-memory writes.
  **No ROM patches, protection bypasses, forced game flags, scoring
  changes or watchdog suppression.**
- 0.6.1 is logging/documentation cleanup, not a garbage fix. Normal
  sessions retain transport/error/reset logs and a brief five-second
  summary. Set `PUYO2_LINK_DEBUG=1` for full read-only investigation
  traces and one-second game/task summaries.
- For the detailed investigation, see sections 13-15 rather than
  restarting it: score remainders, configurable divisors, four-player
  distribution and countering can legitimately produce zero attacks.
  The workspace's patched ROM was only a read-only comparison clue.

**Known limitations and corrected assumptions:**
- Peer-reset recovery uses the native watchdog and can take about
  20 seconds. Resetting a cabinet can terminate the current match
  through original error handling; do not hide it with game-RAM writes.
- The old "comm task disappeared" diagnosis was incorrect: the pump
  runs in an interrupt, and parser/builder TCBs are at `$ffa580/$ffa5c0`.
  The old `accepted=0` logs also had a PC-filter bug, now corrected.
- Historical duplicate player-number reports are not independently
  explained by the garbage confirmation. Investigate only if reproduced.
- Working gameplay does not prove every match progression, disconnect
  edge case, or physical daughterboard timing. No real board is available.

The user's working invitation recipe is to start A, then reset B and
accept B's invitation. Simultaneous timed auto-start is not reliable.

## How to run it

This is a MAME Lua plugin; no source changes or rebuild are needed.

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
Both cabinets should use 0.6.1. Preserve `.bin.wire` journals too: those are
now the authoritative generation-tagged transport, while `.bin` files
retain the raw payload bytes for analysis. Missing peers leave FE waiting.

For investigations, set `$env:PUYO2_LINK_DEBUG = "1"` before launching
each cabinet. Without it, detailed protection/menu/attack taps and TCB
dumps are disabled; raw streams and the real packet-acceptance counter
are still retained. No debug switch changes protocol or gameplay.

For manual A versus random inputs on B, set `PUYO2_EXERCISE_RANDOM_ONLY=1`
on **B only**, keep `PUYO2_AUTO_INPUT=0`, and add
`-autoboot_delay 0 -autoboot_script PuyoPuyo2\re_notes\exercise_link.lua`
to B's launch. Both B players get random Left/Right/Button 1 during
active piece control; coin/start, menus and Down stay manual. A must
omit the script. Inputs are recorded in `exercise_B.log`. The helper
does not play strategically or guarantee that random play clears puyos.

Callback-only regression command (does not launch MAME):
```powershell
.\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
```

## Key files

- `PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md` — the full technical record.
  Read this fully; it has 16 numbered sections/updates, each documenting
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
- `PuyoPuyo2\checkpoints\20260911_cleanup_0_6_1\` — pre-cleanup plugin,
  notes, handoff and the user-confirmed random-B run.
- `plugins\puyo2link\transport.lua` — generation-aware IPC state machine.
- `re_notes\analyze_link.py` — read-only journal/application packet audit:
  `py PuyoPuyo2\re_notes\analyze_link.py <run_directory>`.
- `re_notes\exercise_link.lua` — optional input-only MAME exercise,
  screenshots and RAM snapshots. Add `-autoboot_delay 0 -autoboot_script
  PuyoPuyo2\re_notes\exercise_link.lua` only for automated testing; omit
  it for normal manual play. Never writes game memory.
  `PUYO2_EXERCISE_DIFFICULTY=2` optionally selects the recorded manual
  menu item through Left/Button 1 and native peer confirmation; no
  variable directly sets a divisor or game flag. Absent this variable,
  the existing default exercise remains unchanged.
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
