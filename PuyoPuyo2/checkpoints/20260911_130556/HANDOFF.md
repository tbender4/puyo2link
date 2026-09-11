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

**Latest: plugin 0.4.0, spec Update 6 (section 11).**
- ROM-verified fixes: distinct cabinet roles A=`$81` / B=`$82`, banked TX
  payload/control separation, exact mailbox capture without `$FF` trimming,
  255-byte RX capacity, interrupt-point RX injection, and nontruncating
  service/F3 resets. Watchdog masking is removed.
- **238 callback/ROM assertions pass** using the repository's existing
  Lua 5.3 GENie host (`re_notes\test_transport.lua`). This version has NOT
  been paired-MAME validated: this session's tools denied execution of
  `mame.exe`/`unidasm.exe`. No four-player gameplay success is claimed.
- The older prototype did exchange application packets in paired MAME
  sessions, but its masked watchdog, lossy capture and incorrect credit
  model made “stable established flag” insufficient evidence of health.

**Earlier live milestones (not yet revalidated with 0.4.0):**
- The actual in-game 4-player invite prompt (`もう一台に乱入するの？` —
  "butt in on the other cabinet?") has been triggered for real and
  confirmed visually on screen. This is genuine, working, software-only
  emulation of a feature that (per public record) almost nobody has ever
  gotten working, even with real hardware.
- A real manual recipe for triggering the link was found by the user:
  start cabinet A normally, THEN reset cabinet B (service button) — B then
  shows the invite. Simultaneous auto-start on both sides does *not*
  reliably trigger it.

**Currently debugging (the live edge of the work):**
- After linking, the "recruiting participants" screen (`参加者募集中`)
  sometimes shows the SAME `PLAYER N OF 4` number on both cabinets (a real
  identity/numbering question, not yet root-caused).
- The previous “comm task disappeared” conclusion is **retracted**:
  `$186e0` is called from an interrupt at `$005d4`; parser/builder TCBs
  live at `$ffa580/$ffa5c0`, outside the old scan. The new diagnostics
  report these and actual pump/packet-acceptance counts.
- **Next:** run a fresh paired-MAME validation with the watchdog enabled,
  then reproduce the asymmetric reset/invite and each cabinet's own
  1P/2P Start inputs. Check accepted packets and actual gameplay, not just
  the link flag. Distinct roles fix a verified prerequisite, but the
  displayed numbering and four-player gameplay still need demonstration.
- Raw-file transport still lacks shared reset epochs: peer/local resets
  can disagree about sequence generation even though files no longer
  truncate. See section 11.6 before adding any game-code patches.

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

Callback-only regression command (does not launch MAME):
```powershell
.\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
```

## Key files

- `PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md` — the full technical record.
  Read this fully; it has 11 numbered sections/updates, each documenting
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
