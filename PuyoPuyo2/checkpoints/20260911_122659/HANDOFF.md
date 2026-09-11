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

**Solid and confirmed:**
- The full low-level comm protocol is reverse-engineered and working: boot
  handshake, mailbox register layout, TX/RX ring buffers, byte-level relay
  between two MAME processes. Two independent `mame.exe` instances can
  link, hold a stable connection for extended periods, and exchange real
  application-layer packets.
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
- Sometimes one cabinet correctly starts its own independent match (with a
  `乱入可能` "still joinable" banner) while the other cabinet freezes —
  confirmed via new instrumentation that its comm-pump task genuinely
  disappears from the 68000's task scheduler and never resumes.
- **The immediate next thing to try, queued but not yet done:** get one
  cabinet stuck on `PLAYER N OF 4`, click directly into THAT window, and
  press ITS OWN 1P Start then 2P Start. This may just be a screen waiting
  for a real button press we never provided (not a bug at all) — or it may
  confirm a genuine deeper issue. See spec section 10 for full detail.

## How to run it

No compiler is available in this environment (no gcc/clang/MSVC) — this is
all done via a MAME Lua plugin, no source changes or rebuild needed.

Two terminals, one per "cabinet" (PowerShell):
```powershell
cd C:\Users\tbend\mame
$env:PUYO2_LINK_SIDE = "A"          # "B" in the other terminal
$env:PUYO2_AUTO_INPUT = "0"         # disables auto coin/start for full manual control; omit to let it auto-play through the first coin+1P+2P start
.\mame.exe puyopuy2 -plugin puyo2link -window -skip_gameinfo
```
For quick automated/headless correctness checks (not for watching the
screen): add `-video none -sound none -nothrottle -seconds_to_run 30`.

Logs land in `PuyoPuyo2/link_ipc/proto_A.log` / `proto_B.log` (also
`A_to_B.bin` / `B_to_A.bin`, the raw relayed byte streams). Delete
`PuyoPuyo2/link_ipc/*` before each fresh test run to avoid confusion with
stale data.

## Key files

- `PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md` — the full technical record.
  Read this fully; it has 10 numbered sections/updates, each documenting
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
