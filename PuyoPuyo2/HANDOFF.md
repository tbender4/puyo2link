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

**Current software objective: wired-LAN release 0.7.0.** The Python
standard-library launcher/bridge is implemented in
`plugins/puyo2link/lan.py`; each PC owns its bridge and one current
standalone MAME child, with two local controllers. A explicitly listens
on its LAN IPv4 and B connects. See the README's exact Linux/Windows
commands and **spec section 21** for framing, sessions, flow-control
boundaries, limits, shutdown and tests. Existing same-machine file IPC
remains supported without Python. Normal-speed Windows TCP loopback
reached four-player gameplay with positive attacks both ways, recovered
after a cabinet reset, and shut down both owned MAME children on normal
quit and intentional connection failure. A Windows status-file rename
race was reproduced and fixed with logged, bounded nonblocking retries.
See section 21.6 for evidence under `puyo2-lan-runs`. Two physical
PCs/Linux gameplay and LAN mid-match joining still need acceptance.

**Hardware research is paused at the user's request (2026-09-11).**
The deferred hardware objective is a real PCB linked to MAME on Windows, eventually two
real PCBs with replacement daughterboards. Read **spec section 20** for the
research, sources, uncertainties, and exact first steps. No hardware,
firmware, or USB bridge has been implemented or demonstrated.

Resume with the real PCB **powered off and disconnected**: photograph both
sides, board/revision markings, and CN4 from above, the mating side, and
underneath; measure contact count and spacing. Do not buy a mating connector,
solder, bridge pins, or connect MCU/USB power before orientation and nets
are established. Published CN4 notes enumerate **two rows of 20 contacts**;
the old 12-pin identification was a confusion with CN2. The source
contradicts itself on A19/B19, and physical bus timing remains unknown.
RP2040 is a candidate, not a proven complete bus responder. Windows can
remain the host. Await the user's new direction; do not resume hardware
work or launch experiments automatically.

**Last user-confirmed gameplay baseline: plugin 0.6.2 cleanup, spec Update 14 (section 19). Linked
gameplay, garbage and normal-speed mid-match joining are user-confirmed
working. Both reported gameplay issues are closed.**

- Built-in timed coin/start automation and `PUYO2_AUTO_INPUT` are removed.
  The communication plugin never accesses player controls. Optional
  input-only exercise scripts remain separate and explicitly launched.

- After `run_midjoin_manual_20260911_162947`, the user confirmed:
  "joining midgame is stable. pressing down was what had me confused."
  The reported invitation failure was selection of the default No,
  not a communication-board defect. No behavior change was needed.

- The invitation defaults to **いいえ (No)**. Move the initiating player's
  joystick **Down** to **はい (Yes)**, release, then press that player's
  **Button 1 or Button 2**. They both confirm the highlighted item; they
  are not separate No/Yes shortcuts. With unchanged defaults: P1 uses
  **Down arrow, then Left Ctrl or Left Alt**; P2 uses **F, then A or S**.
  Keyboard **1/2 are Start**, not those action buttons. The ROM checks
  confirmation before movement, so do not first press Down and confirm
  simultaneously. Timeout confirms the current selection.
- Both processes should already be connected, with one cabinet in real
  gameplay and the other at attract. **Do not reset/relaunch a peer as
  the mid-match joining procedure.** `run_latejoin_yes_isolated_12_20260911`
  demonstrates A's existing local round interrupted, native invitation
  acknowledgment, four-player recruitment, and active pieces on all four
  fields without any game-memory/ROM/board-behavior change.
- At 16:16 on 2026-09-11 the user visually corroborated: "both current
  pairs running are in the 4p mode i think youre getting there".
  This supports visible four-player mode, but does not identify the
  run directories or independently establish their entry sequence.
  The input logs and active-piece traces establish the mid-match case.
- The user's **15:46:50** observation that the latest run did not
  interrupt A correlates with `run_latejoin_start2_retry_10_20260911`,
  the **Start 2 / default-No negative control**, not a Yes test.
  Its logged choice was 0, no invitation handshake was transmitted,
  and screenshots around 15:46:44/54 show A continuing and B starting
  a separate local match. See section 17.6, including the caveat about
  that early control's unmasked physical inputs.
- This is **not a claim that every failure was wrong input**. Accelerated
  paired tests also reproduced a separate post-accept recruitment race:
  peer command `$83` can replace `$73` before ROM `$18bd4` examines its
  participant bits, causing local fallback. The exact read is recorded
  in `run_latejoin_yes_timeout_07_20260911`. No physical-board timing
  specification or justified hardware fix is established. Normal-speed
  acceptance is now user-confirmed. Keep the accelerated race as a
  separate investigation note, not an unresolved version of the user's
  closed invitation report; see sections 17 and 18.

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
  edge case, or physical daughterboard timing. The user's real PCB has
  not yet been characterized for this project; see section 20.

The old reset-B invitation recipe is historical, not current advice.
The user confirms starting both cabinets from attract works, including
garbage. Preserve that known-good workflow. For late joining, use the
already-connected, no-reset procedure above.

## How to run it

This is a MAME Lua plugin; no source changes or rebuild are needed.

**User requirement after the overlapping investigation runs:** run
**exactly one test pair at a time**. State the scenario (e.g. explicit
Yes acceptance versus default-No/Start control) and fresh run directory
before launching. Wait for **both** processes to fully exit before
starting another pair; do not independently batch scenarios in the A
and B shells. Do not infer which scenario the user saw from an
unlabelled window. All investigator-owned runs recorded in section 17
finished normally; none remained to stop when this request was received.

Two terminals, one per "cabinet" (PowerShell):
```powershell
cd C:\Users\tbend\mame
$env:PUYO2_LINK_SIDE = "A"          # "B" in the other terminal
$env:PUYO2_LINK_DIR = "C:\Users\tbend\mame\PuyoPuyo2\run_manual_01" # SAME new folder in both terminals
.\mame.exe puyopuy2 -plugin puyo2link -window -skip_gameinfo
```
For quick automated/headless correctness checks (not for watching the
screen): add `-video none -sound none -nothrottle -seconds_to_run 30`.

Logs and raw streams land in `PUYO2_LINK_DIR`. Choose a fresh folder for
each process pair; **do not delete old logs**. A new process refuses an
existing nonempty outgoing stream. Service/F3 reset in the same process
preserves append offsets. The legacy default `PuyoPuyo2\link_ipc` contains
historical logs and should not be reused.
Both cabinets should use 0.7.0. Preserve `.bin.wire` journals too: those are
now the authoritative generation-tagged transport, while `.bin` files
retain the raw payload bytes for analysis. Missing peers leave FE waiting.

For investigations, set `$env:PUYO2_LINK_DEBUG = "1"` before launching
each cabinet. Without it, detailed protection/menu/attack taps and TCB
dumps are disabled; raw streams and the real packet-acceptance counter
are still retained. No debug switch changes protocol or gameplay.

For manual A versus random inputs on B, set `PUYO2_EXERCISE_RANDOM_ONLY=1`
on **B only**, and add
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
  Read this fully; it has sections through 21, each documenting
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
- `plugins\puyo2link\lan.py` — stdlib TCP bridge and owned-child launcher.
  Run `py plugins\puyo2link\lan.py --help`; run
  `py PuyoPuyo2\re_notes\test_lan.py` for socket/stub-child regression tests.
  LAN sessions use fresh local journals, bounded unread backlogs and
  explicit progress/status snapshots. Failure ends both cabinets, not
  transparent reconnect. The same-process ROM reset-generation behavior
  is preserved; hardware/serial work in section 20 remains paused.
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
- `re_notes\exercise_latejoin.lua` — separate bounded-test input helper;
  waits for A's actual local active pieces before B's coins/start.
  Records actual input mappings, invitation selection/confirmation,
  native recruitment reads, screenshots and RAM snapshots. It overrides
  physical inputs during the test; do not use it for manual play.
  See section 17 for environment variables and the remaining timing race.
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
