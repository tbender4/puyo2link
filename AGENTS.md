# Working on puyo2link

## Scope and references
- Runtime: `mame-bin/plugins/puyo2link/` (`init.lua`: mailbox, `transport.lua`: journals, `lan.py`: TCP bridge/launcher). Make plugin edits here only; do not recreate root `plugins/` or edit bundled/source/checkpoint copies.
- Launch MAME and `plugins/puyo2link/lan.py` from `mame-bin/`; run repository regression commands below from the repository root.
- Read `PuyoPuyo2/HANDOFF.md` for current status; consult relevant sections of `re_notes/COMM_PROTOCOL_SPEC.md`. Later updates supersede early conclusions. Do not load the entire historical record unnecessarily.
- `README.md` contains user-facing setup. Keep documented commands and both Lua/JSON version fields consistent with changes.
- Hardware work is paused unless explicitly resumed. TCP loopback evidence is not physical LAN/Linux acceptance.

## Non-negotiable behavior
- Emulate the communication peripheral, not game logic: no ROM patches, game-RAM writes, forced game flags, protection bypasses, or watchdog suppression.
- Preserve both same-PC file IPC (no Python required) and opt-in LAN mode in the same plugin.
- Keep controls out of the production plugin. Input automation belongs in explicitly launched exercise scripts.
- Retain memory taps/notifier handles at module scope; explicitly remove old taps before reinstalling on reset.
- Mailbox slots are zero-indexed. Preserve the 255-byte occupancy limit and reset-generation/readiness barriers.
- `send()` must accept an entire batch or return zero: its caller clears the whole TX queue on positive acceptance. Socket writes may be partial. Journal acceptance is not remote game consumption.
- Never block MAME callbacks on network I/O, silently drop bytes, or replay stale data after reconnect.

## Validation and live runs
Use existing checks from the repository root:
```powershell
py PuyoPuyo2\re_notes\test_lan.py
.\mame-src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
.\mame-src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_random_inputs.lua
```
- Run relevant checks; use `python3` for the Python check on Linux. Lua checks need the local GENie host and original merged ROM; report missing prerequisites rather than downloading ROMs.
- Live experiments: announce scenario/directory, run **one pair at a time**, and wait for both processes to exit before another. Use normal speed unless specifically investigating accelerated behavior.
- Use fresh run directories and preserve evidence. Exercise scripts drive inputs; they are not passive observers.

## Repository hygiene
- This checkout also contains untracked MAME, ROMs, and historical artifacts. Never use blanket staging; inspect and stage explicit project files only.
- Do not add ROM archives, merged/patched images, emulator binaries, or incidental third-party downloads, including copies inside checkpoints.
- Local MAME source is under `mame-src/src/`; `FBNeo/` is also reference material, not part of this plugin's distribution. Avoid MAME C++ changes for plugin features.
- Preserve user edits to docs and existing logs. Record durable findings in the handoff/spec, not duplicated agent-instruction files.
