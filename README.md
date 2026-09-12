# Puyo Puyo 2 link plugin for MAME

A Lua plugin that emulates the Puyo Puyo 2 arcade communication board,
connecting two MAME instances for four-player play on **one computer or
two PCs over wired Ethernet**. Plugin **0.7.0** adds the optional LAN
bridge, with one MAME instance and two local players per PC.

This runs on an unmodified `puyopuy2.zip` ROM set in standalone MAME.

![side-by-side](./PuyoPuyo2/images/Screenshot%202026-09-11%20131908.png)

## Disclaimer

**This was AI-generated.** Not even AI-assisted; AI drove the whole development.
I am not a MAME developer. I'm not even experienced in LUA so please temper your
expectations. I encourage anyone to review and rewrite this by hand if you are
so inclined to. This was spurred out of my own curiosity of an obsure feature in
the original arcade release of this wonderul game.

## Files

The plugin is in `plugins\puyo2link`. Investigation notes, disassembly,
logs and development artifacts are in `PuyoPuyo2` for reference.
MAME and game ROM files are **not included**; supply your own installation
and legally obtained ROM set.

## Choose your setup

| Setup | Requirements | Instructions |
|-------|--------------|--------------|
| Two cabinets on one PC | MAME and the plugin; no Python | [Same-PC launch](#launch-two-cabinets-on-one-pc) |
| One cabinet on each of two PCs | MAME, the plugin and Python 3.8+ on both; wired LAN | [LAN launch for Windows and Linux](#wired-ethernet-lan-plugin-070) |

## Install

Use current standalone MAME. The Windows setup was exercised with MAME
0.289; the LAN section also includes Linux commands.

1. Copy the entire `plugins\puyo2link` folder into your MAME installation's
   `plugins` folder.
2. Put your original `puyopuy2.zip` ROM set in MAME's `roms` folder.
3. For same-PC play, open two PowerShell terminals in the **same MAME
   installation folder**. For LAN play, install on both PCs and use the
   [LAN launcher](#wired-ethernet-lan-plugin-070) instead.

The resulting layout should include:

```text
mame\
  mame.exe
  plugins\
    puyo2link\
      init.lua
      transport.lua
      lan.py
      plugin.json
  roms\
    puyopuy2.zip
```

## Launch two cabinets on one PC

Both instances must use the **same shared folder** for their link files,
with one named side A and the other side B. The plugin creates the
folder below inside your MAME directory. Change `puyo2-session-001` to a new
name in **both commands** each time you launch a new pair; do not reuse a
previous session's files.

**Terminal 1 - cabinet A:**

```powershell
$env:PUYO2_LINK_SIDE = "A"
$env:PUYO2_LINK_DIR = "$PWD\puyo2-session-001"
.\mame.exe puyopuy2 -plugin puyo2link -window -skip_gameinfo -speed 1
```

**Terminal 2 - cabinet B:**

```powershell
$env:PUYO2_LINK_SIDE = "B"
$env:PUYO2_LINK_DIR = "$PWD\puyo2-session-001"
.\mame.exe puyopuy2 -plugin puyo2link -window -skip_gameinfo -speed 1
```

## Starting a 4-player game

Pressing start on one machine will cause both machines to respond:
![wait-screen](<./PuyoPuyo2/images/Screenshot 2026-09-11 104558.png>)

Press start on all four players. It will begin the 4-player mode. If only two
players join, they will play on their respective machine. If a machine did not
have a joined player, it will return to the attract demo. Starting a game on
this machine mid-match will offer the player to interrupt the other machine

## Joining a mid-game session

Keep both instances connected. Start playing on one cabinet, then insert
a coin and start on the other.

![join-in](<./PuyoPuyo2//images/Screenshot 2026-09-11 100352.png>)

The join-screen has **No at the top** and **Yes at the bottom**.
No is selected by default. On the joining cabinet, **press Down, release it,
then press an action button**.

Use the Start buttons again when the game asks players to join.

## Diagnostics and reference

Session logs and byte-stream journals are written to `PUYO2_LINK_DIR`.
For detailed diagnostics, set `$env:PUYO2_LINK_DEBUG = "1"` in each terminal
before launching. Normal mode keeps compact transport summaries and errors.

As an effort of transpancy, I've kept all of the AI development history and all
of its artifacts in the `./PuyoPuyo2` directory. Two notable docs are `HANDOFF.md`
and `\re_notes\COMM_PROTOCOL_SPEC.md`.

## Wired Ethernet LAN (plugin 0.7.0)

There is **one `puyo2link` plugin with two transport modes**, sharing the
same mailbox/game behavior. **Same-PC mode needs no Python or bridge**:
keep using the existing two MAME commands and shared `PUYO2_LINK_DIR`
above. Only the LAN launcher opts into the additional bounded bridge
transport; local file transport has not been replaced.

For **two PCs**, install the
complete `plugins/puyo2link` folder (including `lan.py`) and the same original
ROM set on each PC. Use current standalone MAME and Python 3.8+; no Python
packages or MAME C++ rebuild are needed. Linux is the deployment target;
the launcher also supports Windows. Normal-speed Windows TCP loopback
has exercised linked gameplay, reset recovery and disconnect cleanup.
Physical two-PC Linux/LAN gameplay remains to be confirmed.

Connect both PCs to the same trusted wired LAN. Find A's actual LAN IPv4
address and substitute it for **192.168.1.10 in both commands**. Run from
each PC's MAME installation directory, containing `plugins` and `roms`.
These commands assume the standalone Linux executable is `./mame`:

**MAME opens only after A and B connect and complete their handshake.**
Starting A alone prints a waiting message; it is not running headless.
Ctrl+C cancels startup. The commands below differ by operating system;
use the PowerShell examples on Windows.

**Linux PC A (listener):**

```sh
python3 plugins/puyo2link/lan.py --side A --listen 192.168.1.10 --mame ./mame
```

**Linux PC B (connector):**

```sh
python3 plugins/puyo2link/lan.py --side B --connect 192.168.1.10 --mame ./mame
```

For an installed MAME executable on `PATH`, use `--mame mame` instead.
Equivalent **Windows PowerShell**, from each MAME installation directory:

```powershell
# PC A:
py .\plugins\puyo2link\lan.py --side A --listen 192.168.1.10 --mame .\mame.exe
# PC B:
py .\plugins\puyo2link\lan.py --side B --connect 192.168.1.10 --mame .\mame.exe
```

Each command owns its bridge and **one** MAME child; do not separately
launch MAME or set shared-file IPC variables for LAN mode. The launcher
sets side, a fresh local directory and session identity only in its child's
environment. A and B must be distinct. Startup waits/retries for up to
60 seconds **before launching MAME**; either PC may be started first.
Use `--startup-timeout 120` on both for a longer startup window.
There is no reconnect once the session starts.
Startup socket waits return to Python at least every 100 ms so Ctrl+C
does not wait for the full connection timeout on Windows.

Two local controllers belong to each PC. In MAME's Tab input settings,
map both local players' directions, action buttons, coin and start.
`-joystick` is enabled. Mappings/settings and NVRAM persist separately in
`puyo2-lan-runs/cabinet-A` or `cabinet-B`; these do not reuse your ordinary
MAME cabinet configuration. The four-player and mid-match joining
instructions above are unchanged.

The launcher explicitly uses throttle, speed 1, zero frameskip, and no
refresh-speed/vertical-sync speed forcing. Both PCs must sustain normal
emulation speed; the bridge is not clock synchronization, rollback, or
generic netplay. It relays the communication-board records, not controller
events or game RAM. Do not fast-forward or deliberately pause one cabinet
during linked play. A paused/slow receiver can end the session on its
bounded backlog or stall deadline; the game's own watchdog is unchanged.

**Quit MAME or press Ctrl+C in either launcher to end both cabinets.**
A normal quit is sent to the peer; unexpected EOF, malformed traffic,
I/O failure, a stalled receiver or missed heartbeat is a visible failure
with nonzero exit status. Restart **both launchers** after a failure.
The default heartbeat/stall deadline is 10 seconds (`--timeout`, minimum
3); polling is 3 ms and heartbeats are once per second. These are software
operational limits, not a claim about the original board's baud rate.
Shutdown first asks the local Lua plugin to exit MAME; after three seconds
an unresponsive/paused child is terminated, then killed after another
three seconds if necessary. Only the launcher's own child is targeted.

The listener defaults to **127.0.0.1**, not all network interfaces.
Explicitly bind A's LAN address as above. TCP port **24872** is the default;
`--port 24873` on both changes it. If your firewall blocks it, allow this
one TCP port on A **from B's LAN address only**. No discovery, UPnP,
port-forwarding, tunnels or external services are used. **Trusted LAN only:
no encryption or authentication; never expose this port to the Internet.**
Session IDs prevent accidental cross-session replay, not hostile LAN peers.
Remote traffic cannot select filenames, executable paths or commands.

Every launch prints and preserves a unique directory under
`puyo2-lan-runs` (`--runs PATH` changes the parent). Keep `bridge.log`,
`mame.log`, `proto_*.log`, raw `.bin` audits and authoritative `.bin.wire`
journals when reporting a failure. Do not copy old journals into new runs.
`.status` / `.progress` snapshots are bridge/plugin flow-control evidence:
local append acceptance, TCP transmission and remote Lua parsing are
**different boundaries**, none of which proves consumption by the game.
Closing a file is not an `fsync` durability guarantee.

Regression checks, without launching MAME:

```powershell
py .\PuyoPuyo2\re_notes\test_lan.py
.\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_transport.lua
.\src\3rdparty\bx\tools\bin\windows\genie.exe --file=PuyoPuyo2\re_notes\test_random_inputs.lua
```

The Python check also runs on Linux with
`python3 PuyoPuyo2/re_notes/test_lan.py`. The Lua callback test uses the
existing Windows GENie Lua host and the locally supplied original merged
ROM to verify its ROM premises. Protocol and exact buffer limits are
documented in `PuyoPuyo2/re_notes/COMM_PROTOCOL_SPEC.md`, section 21.
