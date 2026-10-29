# warrior-epic-recomp

An effort to make the old MMO **Warrior Epic** (Possibility Space, servers shut down around 2010) playable again
offline, by emulating the servers it talks to. The original client stays almost untouched: it's redirected to
`127.0.0.1` through its own debug config, and a small local server answers it.

> This repository contains **no game files**. You need your own copy of the Warrior Epic installer
> (`Setup.exe`, `GameData\`, the installed `Warrior Epic\` folder). Nothing here contacts any online service.

## Status

| Stage | State |
|---|---|
| Archive format (`.pak`/`.psp`) | Fully decoded, `tools/psp.py` can list/extract/repack |
| Redirect + login (IS, account, session servers) | Works |
| Main hall, data server (money, warriors, items) | Works |
| Recruit / select warriors, character slots | Works, saved to `vm/save.json` |
| Lobby list, lobby join, 3D lobby (town plaza) | Works, needs 3 small in-memory patches |
| Create game, game room (warrior, mission select) | Works |
| START a mission (game server) | **In progress** |
| Avatar in the 3D lobby, war room data, rewards | Not yet |


## How it works

- **Redirect:** `vm/DebugConfig.cfg` uses the client's own debug keys (`isaddress`, `dsaddress`, `gsaddress`,
  `tsaddress`) to point every server connection at `127.0.0.1`.
- **Server:** `vm/stub.ps1` is a single PowerShell script with no dependencies. It emulates:
  - the transport layer (PSDash, TCP/UDP with acks) and the PSIP session layer;
  - the Interface Server and the backend servers routed through it (account, session, chat/lobby);
  - the data server (a compressed UTF-16 key/value protocol);
  - the town server.
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
3. Log in with any name and password.
4. After playing, run `collect.cmd` to copy the game's logs into `vm/out/`.

`vm/WarriorEpic_auto.wsb` + `vm/run_auto.sh` do an unattended run that clicks through the menus, takes screenshots and
a memory dump, and can attach the breakpoint logger (`vm/bp.ps1`).

## Tools

| File | What it does |
|---|---|
| `tools/psp.py` | List / extract / repack the game's `.pak`/`.psp` archives (stdlib only) |
| `tools/xref.py` | String → code cross-references and disassembly for the 32-bit binaries (capstone + pefile) |
| `tools/dmp.py` | Read memory from full minidumps (stdlib only) |
| `vm/bp.ps1` | Breakpoint logger: attaches to the game in the sandbox, logs registers and call stacks |
| `vm/patchmem.ps1` | Applies the verified in-memory patches |
| `vm/dump.ps1` | Full memory dump of the running game |

## Ground rules of the project

- The original install is read-only; modified copies live in the sandbox only.
- Static analysis on the host, execution only in Windows Sandbox.
- No contact with any live or legacy server.
- Every client modification is minimal, documented and reversible.

Built with heavy use of Claude Code as a reverse-engineering and coding tool.
