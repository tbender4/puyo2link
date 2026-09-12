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

## Connecting via LAN (plugin 0.7.0)

In this branch contains a LAN networking mode. It has been tested cross platform
between Ubuntu and Windows with MAME 0.284+.

### Requirements
- Two PCs on the same LAN network
- Python 3.8+ installed on both PCs

### Installation

On both PCs, copy the complete `plugins/puyo2link` folder (including `lan.py`)
to the MAME directory.

### Setup
- Connect both PCs to the same LAN.
- Find the host PC's LAN IPv4 address. Replace them with IP addresses below.

These commands assume the standalone Linux executable is `mame` (added to PATH
by SDLMAME):

**Linux PC A (listener):**

```sh
python3 ~/plugins/puyo2link/lan.py --side A --listen 192.168.1.10 --mame ./mame
```

**Linux PC B (connector):**

```sh
python3 plugins/puyo2link/lan.py --side B --connect 192.168.1.10 --mame ./mame
```


Equivalent **Windows PowerShell**, from each MAME installation directory:

```powershell
# PC A:
py .\plugins\puyo2link\lan.py --side A --listen 192.168.1.10 --mame .\mame.exe
# PC B:
py .\plugins\puyo2link\lan.py --side B --connect 192.168.1.10 --mame .\mame.exe
```

**MAME opens only after A and B connect and complete their handshake.**
Startup waits/retries for up to 60 seconds **before launching MAME**.

### Additional Notes
- Two local controllers belong to each PC. In MAME's Tab input settings,
  map both local players' directions, action buttons, coin and start.
- The launcher explicitly uses throttle, speed 1, zero frameskip, and no
  refresh-speed/vertical-sync speed forcing. 
- The listener defaults to **127.0.0.1**, not all network interfaces.
  Explicitly bind A's LAN address as above.
- TCP port **24872** is the default; `--port 24873` on both changes it.