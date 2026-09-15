# Puyo Puyo 2 link plugin for MAME

A Lua plugin that emulates the Puyo Puyo 2 arcade communication board,
connecting two MAME instances on one computer for four-player play.

This run on an unmodified `puyopuy2.zip` rom on stock MAME.

![side-by-side](./PuyoPuyo2/images/Screenshot%202026-09-11%20131908.png)

## Disclaimer

**This was AI-generated.** Not even AI-assisted; AI drove the whole development.
I am not a MAME developer. I'm not even experienced in LUA so please temper your
expectations. I encourage anyone to review and rewrite this by hand if you are
so inclined to. This was spurred out of my own curiosity of an obscure feature
in the original arcade release of this wonderful game.

## Files

The plugin is in `plugins\puyo2link`. Investigation notes, disassembly,
logs and development artifacts are in `PuyoPuyo2` for reference.
MAME and game ROM files are **not included**; supply your own installation
and legally obtained ROM set.

## Install

These instructions use Windows PowerShell and were exercised with MAME 0.289.

1. Copy the entire `plugins\puyo2link` folder into your MAME installation's
   `plugins` folder.
2. Put your original `puyopuy2.zip` ROM set in MAME's `roms` folder.
3. Open two PowerShell terminals in the **same MAME installation folder**.

The resulting layout should include:

```text
mame\
  mame.exe
  plugins\
    puyo2link\
      init.lua
      transport.lua
      plugin.json
  roms\
    puyopuy2.zip
```

## Launch two cabinets

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
11111111111111111111111111111111111111111111111111111111111111111111111111111111
Pressing start on one machine will cause both machines to respond:
![wait-screen](<./PuyoPuyo2/images/Screenshot 2026-09-11 104558.png>)

Press start on all four players. It will begin the 4-player mode.
- If only two players join, they will play on their respective machine.
    - If the machine did not have a joined player, it will return to the attract
      demo.
    - Starting a game on a machine while the other machine is mid-match offers
      the incoming player interrupt the other machine for a multiplayer game

## Joining a mid-game session

Keep both instances connected. Start playing on one cabinet, then insert
a coin and start on the other.

![join-in](<./PuyoPuyo2//images/Screenshot 2026-09-11 100352.png>)

The join-screen has **No at the top** and **Yes at the bottom**.
No is selected by default. On the joining cabinet, **press Down, release it,
then press an action button**.

Use the Start buttons once more when the game asks players to join.

## Diagnostics and reference

Session logs and byte-stream journals are written to `PUYO2_LINK_DIR`.
For detailed diagnostics, set `$env:PUYO2_LINK_DEBUG = "1"` in each terminal
before launching. Normal mode keeps compact transport summaries and errors.

As an effort of transpancy, I've kept all of the AI development history and all
of its artifacts in the `./PuyoPuyo2` directory. Two notable docs are `HANDOFF.md`
and `\re_notes\COMM_PROTOCOL_SPEC.md`.
