# warrior-epic-recomp

An effort to make the old MMO **Warrior Epic** (Possibility Space, servers shut down around 2010) playable again
offline, by emulating the servers it talks to. The original client stays almost untouched: it's redirected to
`127.0.0.1` through its own debug config, and a small local server answers it.

> This repository contains **no game files**. You need your own copy of the Warrior Epic installer
> (`Setup.exe`, `GameData\`, the installed `Warrior Epic\` folder). Nothing here contacts any online service.

## Goal

Start a mission (first one: the Ruins of Aberas, "A Sea Dog's Treasure"), fight through it, finish it and collect the
rewards, offline and solo. Since it's no longer an MMO, damage and reward multipliers will be adjustable, and the
rewards tuned so that solo progression feels good.

## Status

| Stage | State |
|---|---|
| Archive format (`.pak`/`.psp`) | Fully decoded, `tools/psp.py` can list/extract/repack |
| Redirect + login (IS, account, session servers) | Works |
| Main hall, data server (money, warriors, items) | Works |
| Recruit / select warriors, character slots | Works, saved to `vm/save.json` |
| Lobby list, lobby join, 3D lobby (town plaza) | Works, needs 3 small in-memory patches |
| Create game, game room (warrior, mission select) | Works |
| START a mission: match notice, in-process game server | Works |
| Mission loads (dungeon built, hero in the level, READY) | Works |
| Mission starts by itself once loaded | Works |
| Combat: moving, skills on the bar, summons animate | Works |
| Combat: hits, damage, health bars, kills, enemy attacks, death and respawn | Works |
| Aberas played start to finish (quest steps, doors, chests, quest reward) | Works |
| Extraction: result (VICTORY, gold, XP, items) reaches the game and the data server | Works |
| Leaving the mission to the results screen, rewards saved | **In progress** |
| Solo tuning (damage / reward multipliers) | Planned |
| Avatar in the 3D lobby, war room data | Not yet |


## How it works

- **Redirect:** `vm/DebugConfig.cfg` uses the client's own debug keys (`isaddress`, `dsaddress`, `gsaddress`,
  `tsaddress`) to point every server connection at `127.0.0.1`.
- **Server:** `vm/stub.ps1` is a single PowerShell script with no dependencies. It emulates:
  - the transport layer (PSDash, TCP/UDP with acks) and the PSIP session layer;
  - the Interface Server and the backend servers routed through it (account, session, chat/lobby);
  - the data server (a compressed UTF-16 key/value protocol);
  - the town server.
- **Game server:** the original `WEServerWorld.dll` (shipped with the client) runs in a **second game process**, a
  copy of the shell that logs in by itself and waits in the hall (not minimized: a minimized game stops its frame loop,
  and the server world runs on it). That process provides the engine the
  server code needs (resource manager, game database, modules). `host/wehost.c` builds `vm/wehost.dll`, which
  `vm/launch.ps1` injects into both instances (sandbox only). In the server instance it hosts the world. In the client
  instance it forwards game orders to the server over `127.0.0.1:9101` and feeds the server's frames back in. The
  game's own `multishell` debug key allows the second instance; the original dedicated server program was never
  shipped.
- **Client changes**, all documented:
  - one 5-byte patch in a copy of the shell exe (skips the dead commercial updater);
  - three verified in-memory patches applied at runtime by `vm/patchmem.ps1` (3D lobby loading and lobby join). No
    game file on disk is modified.
- **Save:** `vm/save.json` is written after every change, and the previous session is kept as `vm/save.json.bak`.

## Running it

Everything runs inside **Windows Sandbox**, with networking disabled. Never run the game binaries on your host.

1. Put the installed game folder next to the repo as `Warrior Epic\` (the `.wsb` maps it read-only), or edit the
   `HostFolder` paths in `vm/*.wsb` to your locations.
2. Double-click `vm/WarriorEpic_test1.wsb`. Inside the sandbox, open `C:\vm` and run `start.cmd`. It copies the game
   to `C:\WE`, applies the exe patch, starts the stub server, launches the game and applies the in-memory patches.
3. Log in with any name and password (see below: there are two game windows).
4. After playing, run `collect.cmd` to copy the game's logs into `vm/out/`.

`vm/sandbox_pos.cmd start` opens the sandbox and puts its window where you last saved it (`sandbox_pos.cmd save`),
when two monitors are connected.

## Working on the game (two windows)

The game server runs in a second copy of the game, so a session has **two game windows**:

1. `start.cmd` opens the first game window, the **game server**. It logs in by itself (or type any name and password).
   Its window is renamed "WARRIOR EPIC - game server (leave running)", and a console window "WE game server (log)"
   shows the server's log, including the quest scripts' `[QuestWorld LUA]` lines.
2. About 20 seconds later the second window opens. This is the one you **play**: log in with anything, recruit or
   pick a warrior, join a lobby, create a game and press START.
3. Leave the server window open in the background. **Don't minimize it** and don't close it: the mission runs inside
   it. Covering it with the window you play is fine.
4. When done, run `collect.cmd`, then close the sandbox. Logs: `vm/out/host_server.log` (server world: orders, hits,
   game over), `vm/out/host_client.log` (everything the server sent your game), `vm/out/stub.log` (the emulated
   servers, including the data server's reward messages).

Running `start.cmd` again kills both games and starts over. A new `vm/wehost.dll` (from `host/build.cmd`) is picked up
on the next `start.cmd`, even in a sandbox that's already open.

`vm/WarriorEpic_auto.wsb` + `vm/run_auto.sh` do an unattended run that clicks through the menus, takes screenshots and
a memory dump, and can attach the breakpoint logger (`vm/bp.ps1`).

## Tools

| File | What it does |
|---|---|
| `tools/psp.py` | List / extract / repack the game's `.pak`/`.psp` archives (stdlib only) |
| `tools/xref.py` | String → code cross-references and disassembly for the 32-bit binaries (capstone + pefile) |
| `tools/dmp.py` | Read memory from full minidumps (stdlib only) |
| `host/build.cmd` | Builds `vm/wehost.dll` (needs the Visual Studio C++ workload, 32-bit) |
| `tools/startgear.py` | Starting equipment and skills per warrior type, from the game data, into `vm/startgear.json` |
| `vm/bp.ps1` | Breakpoint logger: attaches to the game in the sandbox, logs registers and call stacks |
| `vm/patchmem.ps1` | Applies the verified in-memory patches |
| `vm/dump.ps1` | Full memory dump of the running game |

## Ground rules of the project

- The original install is read-only; modified copies live in the sandbox only.
- Static analysis on the host, execution only in Windows Sandbox.
- No contact with any live or legacy server.
- Every client modification is minimal, documented and reversible.

Built with heavy use of Claude Code as a reverse-engineering and coding tool.
