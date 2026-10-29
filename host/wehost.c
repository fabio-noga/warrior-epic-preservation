// wehost.dll: runs the original game server (WEServerWorld.dll) for the Warrior Epic client, in a second game process.
// Injected (sandbox only, vm\inject.ps1) into two WEShell_TGI.exe instances; vm\out\server.pid names the server one:
//   server: an idle shell logged into the hall, so the engine (resource manager, game database, modules) is set up
//           normally. It hosts ServerWorld on its main thread and serves one client on TCP 127.0.0.1:9101.
//   client: the game being played. Its game orders go to the server; the server's frames go into GameMain's input.
// The server runs in its own process because hosting it inside the client shared every module between the two
// (resource manager races, the order dispatcher, combat/animation state). Addresses and findings: notes/PROTOCOL.md.
#include <winsock2.h>
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

// --- client functions (fixed image bases, not relocated) ---
#define HALLUI_STRING_CTOR   0x67601000   // thiscall WString(const wchar_t*), object = 1 pointer, no allocation
#define HALLUI_CREATE_MODULE 0x67603850   // cdecl void* CreateModule(WString dll, WString func)
#define GAMEMAIN_GAME_INPUT  0x66a6b1e0   // cdecl GameInput(0, 0, data, len): payload of a type-3 frame
#define GAMEMAIN_DISPATCHER  0x66aa38d0   // GameMain: OrderDispatcher* GetOrderDispatcher(void)
#define DISP_TO_SERVER       8            // dispatcher+8: cdecl void ToServer(msg, size), client orders (0x2002 login...)
#define DISP_LOCAL           0xc          // dispatcher+0xc: cdecl void Local(msg), UI -> GameMain orders (0x1xx)
#define GAMEMAIN_SER_GAME    0x66aa6790   // thiscall int LogicGameRoomData::Serialize(buf, size) -> length
#define GAMEMAIN_SER_PLAYER  0x66aae880   // thiscall int LogicGameRoomPlayerData::Serialize(buf, size) -> length
#define GAMEDB_INIT_SCRIPT   0x662c1660   // WEGameDataBase (fixed base): thiscall bool InitScriptSystem(), what
                                          // GameDataBase::Initialize(x, 1) does on a server; the client passes 0
#define GAMEMAIN_GET_GAMEDB  0x66aa3960   // GameMain: cdecl GameDataBase* Get() (module "WEGameDataBase")
#define SW_GET_GAMEDB        0x66a6cf00   // ServerWorld (preferred base, relocate): cdecl GameDataBase* Get()
#define SW_VTABLE_PREFERRED  0x66ab5c6c
// Game over. Quest extraction (QUEST.SubmitExtraction) reaches the world as order 0x075e: result text -> world+0xc5c,
// extracted players -> Array world+0xc68 (count at +0x10). A client-hosted world (world+0x38 == 0) then sends the
// results itself (thiscall 0x66a61be0: per player "Send Game Over" + SET_GAMERESULT, frames through the session, then
// the host callback with event 6). With game data set (+0x38 = 1, our case) it waits for the game-server program to
// pull them (vt+0xcc), which we don't have, so we call the client-hosted sender ourselves.
#define SW_SEND_RESULTS      0x66a61be0   // ServerWorld (preferred base, relocate)
#define SW_EXTRACTED         0xc68
#define GAME_SERVER_ID       20
#define GAME_CONN            12           // connection id = account id: in-game orders are matched to the player by account
#define LINK_PORT            9101

// --- ServerWorld vtable slots (thiscall; called through __fastcall with a dummy edx) ---
#define SW_START       0x10   // (WString name, gameId, sessionId, maxPlayers)
#define SW_SET_GAME    0x14   // (buf, len): LogicGameRoomData, required before any login (world+0x38)
#define SW_SET_PLAYER  0x18   // (index, account, ?, ?, ?, room, buf, len): LogicGameRoomPlayerData
#define SW_ADD_CONN    0x1c   // (psuid*, psuid*): 19-byte PSUIDs, +1 u32 = connection id; login moves it into the send list
#define SW_SET_SENDER  0x20   // (sender): session+4 = sender
#define SW_UPDATE      0x28   // (elapsedMs)
#define SW_CONNECTED   0x30   // (conn)
#define SW_PROCESS     0x3c   // (conn, msg, len)  msg = u16 id, u16 size, body
#define SW_SET_HOST    0xd4   // (account): world+0x88 = host account; SetPlayerData marks that player as host (world+0x8c)
#define SW_SET_BUILDQ  0x138  // (queue): host's dungeon-build throttle queue, Update pushes a request while its count < 5
#define SW_START_BUILD 0x13c  // (): starts the world's own build thread (Dungeon_%03d.ddf build + load)
#define SW_STATE       0x90   // world state: 1 = waiting for the dungeon build, 2 = running

// --- link messages: u32 length (type + payload), u8 type, payload ---
#define MSG_START 1           // client -> server: u32 gameLen, game data, u32 playerLen, player data
#define MSG_ORDER 2           // client -> server: one order (u16 id, u16 size, body)
#define MSG_FRAME 3           // server -> client: one frame payload for GameInput

typedef struct { const wchar_t *p; } WString;
typedef void  (__fastcall *StringCtor)(WString *self, int edx, const wchar_t *s);
typedef void *(__cdecl *CreateModuleFn)(WString dll, WString func);
typedef void  (__cdecl *GameInputFn)(int a, int b, const void *data, int len);
typedef int   (__fastcall *Fn1)(void *self, int edx, int a);
typedef int   (__fastcall *Fn2)(void *self, int edx, int a, int b);
typedef int   (__fastcall *Fn3)(void *self, int edx, int a, int b, int c);
typedef int   (__fastcall *Fn4)(void *self, int edx, int a, int b, int c, int d);
typedef int   (__fastcall *Fn8)(void *self, int edx, int a, int b, int c, int d, int e, int f, int g, int h);

static FILE *g_log;
static int g_server;              // role of this process
static HWND g_wnd;
static WNDPROC g_oldProc;

static HANDLE g_console;   // server role: a console window showing the log live (the stub window no longer sees game traffic)

static void Log(const char *fmt, ...) {
    SYSTEMTIME t; va_list a; char line[1024]; int n, m;
    if (!g_log) return;
    GetLocalTime(&t);
    n = sprintf(line, "%02d:%02d:%02d.%03d ", t.wHour, t.wMinute, t.wSecond, t.wMilliseconds);
    va_start(a, fmt); m = _vsnprintf(line + n, sizeof line - n - 2, fmt, a); va_end(a);
    n = m < 0 ? (int)sizeof line - 2 : n + m;
    line[n++] = '\n'; line[n] = 0;
    fputs(line, g_log); fflush(g_log);
    if (g_console) { DWORD w; WriteConsoleA(g_console, line, n, &w, NULL); }
}

static void LogHex(const char *tag, const unsigned char *p, int n) {
    char buf[3 * 48 + 1]; int i, m = n < 48 ? n : 48;
    for (i = 0; i < m; i++) sprintf(buf + 3 * i, "%02x ", p[i]);
    buf[3 * m] = 0;
    Log("%s len %d: %s", tag, n, buf);
}

static void *Slot(void *obj, int off) { return (*(void ***)obj)[off / 4]; }

// ---------------- thread-safe message queue (socket thread <-> main thread) ----------------
typedef struct Msg { struct Msg *next; int type, len; unsigned char data[1]; } Msg;
typedef struct { CRITICAL_SECTION cs; Msg *head, **tail; } Queue;
static Queue g_in;    // server: messages from the client; client: frames from the server

static void QInit(Queue *q) { InitializeCriticalSection(&q->cs); q->head = 0; q->tail = &q->head; }
static void QPush(Queue *q, int type, const void *data, int len) {
    Msg *m = (Msg *)malloc(sizeof(Msg) + len);
    if (!m) return;
    m->next = 0; m->type = type; m->len = len; memcpy(m->data, data, len);
    EnterCriticalSection(&q->cs); *q->tail = m; q->tail = &m->next; LeaveCriticalSection(&q->cs);
}
static Msg *QPop(Queue *q) {
    Msg *m;
    EnterCriticalSection(&q->cs);
    m = q->head; if (m) { q->head = m->next; if (!q->head) q->tail = &q->head; }
    LeaveCriticalSection(&q->cs);
    return m;
}

// ---------------- link socket ----------------
static SOCKET g_peer = INVALID_SOCKET;

static int RecvAll(SOCKET s, void *buf, int n) {
    int got = 0, r;
    while (got < n) { r = recv(s, (char *)buf + got, n - got, 0); if (r <= 0) return 0; got += r; }
    return 1;
}

static void SendMsg(int type, const void *a, int alen, const void *b, int blen) {   // main thread only
    unsigned char hdr[5]; unsigned len = 1 + alen + blen;
    if (g_peer == INVALID_SOCKET) return;
    memcpy(hdr, &len, 4); hdr[4] = (unsigned char)type;
    if (send(g_peer, (char *)hdr, 5, 0) != 5 || (alen && send(g_peer, (const char *)a, alen, 0) != alen)
        || (blen && send(g_peer, (const char *)b, blen, 0) != blen)) {
        Log("link send failed (%d), dropping connection", WSAGetLastError());
        closesocket(g_peer); g_peer = INVALID_SOCKET;
    }
}

// Reads messages from the peer until it disconnects, queueing them for the main thread.
static void ReadLink(SOCKET s) {
    unsigned len; unsigned char *buf;
    while (RecvAll(s, &len, 4) && len >= 1 && len < (1 << 22)) {
        buf = (unsigned char *)malloc(len);
        if (!buf || !RecvAll(s, buf, len)) { free(buf); break; }
        QPush(&g_in, buf[0], buf + 1, len - 1);
        free(buf);
    }
}

// =====================================================================================================================
// Server role
// =====================================================================================================================
static void *g_world;
static int g_started, g_ticks, g_buildStarted, g_inWorld;
static unsigned char g_gameData[0x1000], g_playerData[0x2000];
static int g_gameLen, g_playerLen;

// ---- fake IS sender (ServerWorldSession+4): frames go to the client over the link ----
// The session calls vt+0x20(conn, frame, len, proto 9, 0x10002, playerPSUID, 0) for every frame it sends.

static void Deliver(const unsigned char *data, int len) { SendMsg(MSG_FRAME, data, len, 0, 0); }

static int __fastcall SenderSend(void *self, int edx, int conn, const unsigned char *f, int len, int proto, int flags, void *psuid, int x) {
    if (len < 1) return 1;
    if (f[0] == 3) Deliver(f + 1, len - 1);                          // plain frame
    // type 4: a whole frame behind a 9-byte header, +1/+5 = two session counters (session 0x66a0a6ce: written when
    // the connection's +0x2c is non-zero). Not fragments: waiting for "+5 bytes" lost every combat result (0x0506).
    else if (f[0] == 4 && len >= 9) Deliver(f + 9, len - 9);
    else LogHex("sender: unknown frame", f, len);
    return 1;
}

// vt+0x38: multicast, (conn list, frame, len, proto 9, 0x10002) (session 0x66a0a9cc). The list (psdash Array, count at
// +0x10) excludes connections the session sends a private copy to (e.g. 0x2013 with the "local player" flag), so an
// empty list must deliver nothing. One player: a non-empty list means us.
static int __fastcall SenderMulti(void *self, int edx, void *conns, const unsigned char *f, int len, int proto, int flags) {
    // Empty list = everyone already got a private copy (the player gets its own via vt+0x20): drop it. Delivering it
    // anyway doubled every combat result (0x0506) and monsters died on screen before the server killed them.
    if (!*(int *)((char *)conns + 0x10)) return 1;
    return SenderSend(self, 0, GAME_CONN, f, len, proto, flags, 0, 0);
}

// Any other slot the session might call: log it (argument count unknown, so it may still crash; the log says which).
#define STUB(n) static int __fastcall Stub##n(void *s, int e) { Log("sender slot 0x%x called", (n) * 4); return 1; }
STUB(0) STUB(1) STUB(2) STUB(3) STUB(4) STUB(5) STUB(6) STUB(7) STUB(9) STUB(10) STUB(11) STUB(12) STUB(13)
STUB(15) STUB(16) STUB(17) STUB(18) STUB(19) STUB(20) STUB(21) STUB(22) STUB(23)
static void *g_senderVt[24] = { Stub0, Stub1, Stub2, Stub3, Stub4, Stub5, Stub6, Stub7, SenderSend, Stub9, Stub10, Stub11,
    Stub12, Stub13, SenderMulti, Stub15, Stub16, Stub17, Stub18, Stub19, Stub20, Stub21, Stub22, Stub23 };
static struct { void **vt; } g_sender = { g_senderVt };

// Ring queue {+4 capacity, +0x10 count, +0x18 head, +0x1c items}: count 5 = "full", so Update never enqueues and we start
// the build ourselves (ServerTick).
static DWORD g_buildQueue[8] = { 0, 5, 0, 0, 5, 0, 0, 0 };

static void CreateWorld(void) {
    WString dll, func;
    HMODULE sw = GetModuleHandleW(L"WEServerWorld.dll");
    if (sw) {   // already loaded: call the export directly, it allocates a new world every time
        g_world = ((void *(__cdecl *)(void))GetProcAddress(sw, "CreateServerWorld"))();
        Log("CreateServerWorld (export) -> %p", g_world);
        return;
    }
    ((StringCtor)HALLUI_STRING_CTOR)(&dll, 0, L"WEServerWorld.dll");
    ((StringCtor)HALLUI_STRING_CTOR)(&func, 0, L"CreateServerWorld");
    g_world = ((CreateModuleFn)HALLUI_CREATE_MODULE)(dll, func);
    Log("CreateServerWorld -> %p, vtable %p", g_world, g_world ? *(void **)g_world : 0);
}

static void HookHitProbe(void);
static void StartGame(void) {
    static const wchar_t name[] = L"localgame";
    int r;
    // A new match (the client left the previous one, or created another room) always gets a fresh world.
    // ponytail: the old world is abandoned, not destroyed (no known safe teardown); a few MB per match
    if (g_world) Log("new match, dropping world %p", g_world);
    g_world = 0; g_started = 0; g_buildStarted = 0; g_ticks = 0;
    CreateWorld();
    if (!g_world) return;
    {   // Combat looks up the "WEScriptSystem" module (skills, attacks); only a server-side database init creates it.
        static int scripts;
        if (!scripts) {
            void *db = ((void *(__cdecl *)(void))(SW_GET_GAMEDB + (DWORD)*(void **)g_world - SW_VTABLE_PREFERRED))();
            int ok = db ? ((int (__fastcall *)(void *, int))GAMEDB_INIT_SCRIPT)(db, 0) : 0;
            Log("gamedatabase %p, script system init -> %d", db, ok);
            scripts = ok;
        }
    }
    // gameId 0: tokens are 0 and the no-player timeout is off (ServerWorld Start, see notes).
    r = ((Fn4)Slot(g_world, SW_START))(g_world, 0, (int)name, 0, GAME_SERVER_ID, 1);
    Log("Start -> %d", r);
    if (!g_gameLen) { memset(g_gameData, 0, 40); g_gameData[0] = 1; g_gameLen = 40; Log("no game data, using default (campaign/stage/mission 0)"); }
    ((Fn2)Slot(g_world, SW_SET_GAME))(g_world, 0, (int)g_gameData, g_gameLen);
    Log("SetGameData %d bytes, ready flag %d", g_gameLen, *(int *)((char *)g_world + 0x38));
    // Single player: we are the host. The original host program set this (else world+0x88 is uninitialized: the log
    // showed a different garbage HostAccountId each run) and host-only notices (monster deaths...) went nowhere.
    ((Fn1)Slot(g_world, SW_SET_HOST))(g_world, 0, GAME_CONN);
    if (g_playerLen) {
        ((Fn8)Slot(g_world, SW_SET_PLAYER))(g_world, 0, 0, GAME_CONN, 0, 0, 0, 200, (int)g_playerData, g_playerLen);
        Log("SetPlayerData %d bytes", g_playerLen);
    } else Log("no player data");
    ((Fn1)Slot(g_world, SW_SET_BUILDQ))(g_world, 0, (int)g_buildQueue);
    ((Fn1)Slot(g_world, SW_SET_SENDER))(g_world, 0, (int)&g_sender);
    {   static unsigned char psuid[2][0x13];
        *(DWORD *)(psuid[0] + 1) = GAME_CONN; *(DWORD *)(psuid[1] + 1) = GAME_CONN;
        ((Fn2)Slot(g_world, SW_ADD_CONN))(g_world, 0, (int)psuid[0], (int)psuid[1]);
    }
    ((Fn1)Slot(g_world, SW_CONNECTED))(g_world, 0, GAME_CONN);
    Log("sender installed, player %d connected", GAME_CONN);
    HookHitProbe();   // WECombatWorld is loaded by the world by now
    g_started = 1;
}

// ---- probe: hit resolution results. WECombatWorld calls int __cdecl ResolveHit(attrs*) once per landed attack
// (call site +0x4804e); result 1 = miss, 2 = hit, 3 = critical (caller 0x67648056). The call is redirected through
// LogHit, which calls the original and logs result + the first input dwords (attack/defense values). ----
#define COMBAT_HIT_CALLSITE  0x6764804e
typedef int (__cdecl *ResolveFn)(void *attrs);
static ResolveFn g_resolve;
static volatile LONG g_hits;
// After a hit, watch the defender's Life (first u16 of its attribute block: Life, MaxLife, AttackSkill, DefenseSkill...)
// for a few seconds: does the server actually apply damage?
static unsigned short *g_watchLife; static unsigned short g_watchLast; static DWORD g_watchUntil;
static void WatchLife(void) {
    unsigned short v;
    if (!g_watchLife || GetTickCount() > g_watchUntil) { g_watchLife = 0; return; }
    __try { v = *g_watchLife; } __except (EXCEPTION_EXECUTE_HANDLER) { g_watchLife = 0; return; }
    if (v != g_watchLast) { Log("combat: defender %p life %u -> %u", g_watchLife, g_watchLast, v); g_watchLast = v; }
}

static int __cdecl LogHit(void *attrs) {
    int r = g_resolve(attrs);
    if (r == 2 || r == 3) {
        __try { g_watchLife = (unsigned short *)((DWORD *)attrs)[4]; g_watchLast = *g_watchLife; g_watchUntil = GetTickCount() + 4000;
                Log("combat: watching defender %p, life %u/%u", g_watchLife, g_watchLife[0], g_watchLife[1]); }
        __except (EXCEPTION_EXECUTE_HANDLER) { g_watchLife = 0; }
    }
    LONG n = InterlockedIncrement(&g_hits);
    if (n <= 20 || n % 25 == 0) {
        DWORD *d = (DWORD *)attrs;
        Log("combat: hit #%ld -> %d (%s) attrs %08lx %08lx %08lx %08lx %08lx %08lx", n, r, r == 1 ? "miss" : r == 2 ? "hit" : r == 3 ? "critical" : "?",
            d[0], d[1], d[2], d[3], d[4], d[5]);
        if (n <= 3) {   // +0xc / +0x10 look like attacker / defender BaseCharacterAttribute (AttackSkill, DefenseSkill, Level)
            __try { LogHex("  attacker attrs", (unsigned char *)d[3], 32); LogHex("  defender attrs", (unsigned char *)d[4], 32); }
            __except (EXCEPTION_EXECUTE_HANDLER) { Log("  attrs not readable"); }
        }
    }
    return r;
}

// ---- probe: call counts of every WECombatWorld vtable method (0x676940a4, 30 slots), to see which combat entry
// points run during a fight. Each slot is replaced by a thunk that counts and jumps to the original. ----
#define COMBAT_VTABLE 0x676940a4
#define COMBAT_SLOTS  30
static volatile LONG g_cwCount[COMBAT_SLOTS]; static void *g_cwOrig[COMBAT_SLOTS]; static LONG g_cwLast[COMBAT_SLOTS];
static __declspec(naked) void CwT0(void) { __asm { lock inc dword ptr [g_cwCount + 0] } __asm { jmp dword ptr [g_cwOrig + 0] } }
static __declspec(naked) void CwT1(void) { __asm { lock inc dword ptr [g_cwCount + 4] } __asm { jmp dword ptr [g_cwOrig + 4] } }
static __declspec(naked) void CwT2(void) { __asm { lock inc dword ptr [g_cwCount + 8] } __asm { jmp dword ptr [g_cwOrig + 8] } }
static __declspec(naked) void CwT3(void) { __asm { lock inc dword ptr [g_cwCount + 12] } __asm { jmp dword ptr [g_cwOrig + 12] } }
static __declspec(naked) void CwT4(void) { __asm { lock inc dword ptr [g_cwCount + 16] } __asm { jmp dword ptr [g_cwOrig + 16] } }
static __declspec(naked) void CwT5(void) { __asm { lock inc dword ptr [g_cwCount + 20] } __asm { jmp dword ptr [g_cwOrig + 20] } }
static __declspec(naked) void CwT6(void) { __asm { lock inc dword ptr [g_cwCount + 24] } __asm { jmp dword ptr [g_cwOrig + 24] } }
static __declspec(naked) void CwT7(void) { __asm { lock inc dword ptr [g_cwCount + 28] } __asm { jmp dword ptr [g_cwOrig + 28] } }
static __declspec(naked) void CwT8(void) { __asm { lock inc dword ptr [g_cwCount + 32] } __asm { jmp dword ptr [g_cwOrig + 32] } }
static __declspec(naked) void CwT9(void) { __asm { lock inc dword ptr [g_cwCount + 36] } __asm { jmp dword ptr [g_cwOrig + 36] } }
static __declspec(naked) void CwT10(void) { __asm { lock inc dword ptr [g_cwCount + 40] } __asm { jmp dword ptr [g_cwOrig + 40] } }
static __declspec(naked) void CwT11(void) { __asm { lock inc dword ptr [g_cwCount + 44] } __asm { jmp dword ptr [g_cwOrig + 44] } }
static __declspec(naked) void CwT12(void) { __asm { lock inc dword ptr [g_cwCount + 48] } __asm { jmp dword ptr [g_cwOrig + 48] } }
static __declspec(naked) void CwT13(void) { __asm { lock inc dword ptr [g_cwCount + 52] } __asm { jmp dword ptr [g_cwOrig + 52] } }
static __declspec(naked) void CwT14(void) { __asm { lock inc dword ptr [g_cwCount + 56] } __asm { jmp dword ptr [g_cwOrig + 56] } }
static __declspec(naked) void CwT15(void) { __asm { lock inc dword ptr [g_cwCount + 60] } __asm { jmp dword ptr [g_cwOrig + 60] } }
static __declspec(naked) void CwT16(void) { __asm { lock inc dword ptr [g_cwCount + 64] } __asm { jmp dword ptr [g_cwOrig + 64] } }
static __declspec(naked) void CwT17(void) { __asm { lock inc dword ptr [g_cwCount + 68] } __asm { jmp dword ptr [g_cwOrig + 68] } }
static __declspec(naked) void CwT18(void) { __asm { lock inc dword ptr [g_cwCount + 72] } __asm { jmp dword ptr [g_cwOrig + 72] } }
static __declspec(naked) void CwT19(void) { __asm { lock inc dword ptr [g_cwCount + 76] } __asm { jmp dword ptr [g_cwOrig + 76] } }
static __declspec(naked) void CwT20(void) { __asm { lock inc dword ptr [g_cwCount + 80] } __asm { jmp dword ptr [g_cwOrig + 80] } }
static __declspec(naked) void CwT21(void) { __asm { lock inc dword ptr [g_cwCount + 84] } __asm { jmp dword ptr [g_cwOrig + 84] } }
static __declspec(naked) void CwT22(void) { __asm { lock inc dword ptr [g_cwCount + 88] } __asm { jmp dword ptr [g_cwOrig + 88] } }
static __declspec(naked) void CwT23(void) { __asm { lock inc dword ptr [g_cwCount + 92] } __asm { jmp dword ptr [g_cwOrig + 92] } }
static __declspec(naked) void CwT24(void) { __asm { lock inc dword ptr [g_cwCount + 96] } __asm { jmp dword ptr [g_cwOrig + 96] } }
static __declspec(naked) void CwT25(void) { __asm { lock inc dword ptr [g_cwCount + 100] } __asm { jmp dword ptr [g_cwOrig + 100] } }
static __declspec(naked) void CwT26(void) { __asm { lock inc dword ptr [g_cwCount + 104] } __asm { jmp dword ptr [g_cwOrig + 104] } }
static __declspec(naked) void CwT27(void) { __asm { lock inc dword ptr [g_cwCount + 108] } __asm { jmp dword ptr [g_cwOrig + 108] } }
static __declspec(naked) void CwT28(void) { __asm { lock inc dword ptr [g_cwCount + 112] } __asm { jmp dword ptr [g_cwOrig + 112] } }
static __declspec(naked) void CwT29(void) { __asm { lock inc dword ptr [g_cwCount + 116] } __asm { jmp dword ptr [g_cwOrig + 116] } }
static void *g_cwThunk[COMBAT_SLOTS] = { CwT0, CwT1, CwT2, CwT3, CwT4, CwT5, CwT6, CwT7, CwT8, CwT9, CwT10, CwT11, CwT12, CwT13, CwT14, CwT15, CwT16, CwT17, CwT18, CwT19, CwT20, CwT21, CwT22, CwT23, CwT24, CwT25, CwT26, CwT27, CwT28, CwT29 };

static void HookCombatCounters(HMODULE cw) {
    void **vt = (void **)(COMBAT_VTABLE - 0x67600000 + (DWORD)cw); DWORD old; int i;
    VirtualProtect(vt, sizeof(void *) * COMBAT_SLOTS, PAGE_READWRITE, &old);
    for (i = 0; i < COMBAT_SLOTS; i++) { g_cwOrig[i] = vt[i]; vt[i] = g_cwThunk[i]; }
    VirtualProtect(vt, sizeof(void *) * COMBAT_SLOTS, old, &old);
    Log("combat counters installed on vtable %p", vt);
}

static void LogCombatCounters(void) {
    char buf[600]; int i, n = 0;
    for (i = 0; i < COMBAT_SLOTS; i++) {
        LONG c = g_cwCount[i], d = c - g_cwLast[i];
        if (d && n < (int)sizeof buf - 24) n += sprintf(buf + n, " %02x:%ld", i * 4, d);
        g_cwLast[i] = c;
    }
    if (n) Log("combat calls (slot:count in the last period):%s", buf);
}

static void HookHitProbe(void) {
    static int done;
    HMODULE cw = GetModuleHandleW(L"WECombatWorld.dll");
    unsigned char *p; DWORD old;
    if (done || !cw) return;
    done = 1;
    p = (unsigned char *)(COMBAT_HIT_CALLSITE - 0x67600000 + (DWORD)cw);
    if (p[0] != 0xE8) { LogHex("hit probe: unexpected bytes", p, 5); return; }
    g_resolve = (ResolveFn)(p + 5 + *(int *)(p + 1));
    VirtualProtect(p, 5, PAGE_EXECUTE_READWRITE, &old);
    *(int *)(p + 1) = (int)((unsigned char *)LogHit - (p + 5));
    VirtualProtect(p, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 5);
    Log("hit probe installed at %p (resolver %p)", p, g_resolve);
    HookCombatCounters(cw);
}

static void Process(const unsigned char *data, int len) {
    __try { ((Fn3)Slot(g_world, SW_PROCESS))(g_world, 0, GAME_CONN, (int)data, len); }   // ret 0xc: 3 args
    __except (EXCEPTION_EXECUTE_HANDLER) { Log("ProcessMessage crashed %08lx on 0x%x", GetExceptionCode(), *(unsigned short *)data); }
}

static void HandleStart(const unsigned char *p, int len) {
    unsigned g, pl;
    if (len < 8 || (g = *(unsigned *)p) > sizeof g_gameData || 8 + g > (unsigned)len
        || (pl = *(unsigned *)(p + 4 + g)) > sizeof g_playerData || 8 + g + pl > (unsigned)len) { Log("bad START message"); return; }
    memcpy(g_gameData, p + 4, g); g_gameLen = g;
    memcpy(g_playerData, p + 8 + g, pl); g_playerLen = pl;
    Log("START: game data %u bytes, player data %u bytes", g, pl);
    {   FILE *f = _wfopen(L"C:\\vm\\out\\playerdata.bin", L"wb");   // raw (PSP-compressed) LogicGameRoomPlayerData, for decoding
        if (f) { fwrite(g_playerData, 1, pl, f); fclose(f); }
    }
    __try { StartGame(); } __except (EXCEPTION_EXECUTE_HANDLER) { Log("StartGame crashed %08lx", GetExceptionCode()); g_started = 0; }
}

// Main thread (window timer / per-frame orders): client messages, then Update, at most every 50 ms.
static volatile DWORD g_lastTick, g_mainTid;   // watchdog: when the world last ran, and on which thread

static void CheckGameOver(void) {
    static void *sent;   // once per world
    int n = *(int *)((char *)g_world + SW_EXTRACTED + 0x10), r = -1;
    if (!n || sent == g_world) return;
    sent = g_world;
    __try { r = ((int (__fastcall *)(void *, int))(SW_SEND_RESULTS + (DWORD)*(void **)g_world - SW_VTABLE_PREFERRED))(g_world, 0); }
    __except (EXCEPTION_EXECUTE_HANDLER) { Log("send results crashed %08lx", GetExceptionCode()); return; }
    Log("game over: %d player(s) extracted, results sent -> %d", n, r);
}

static void ServerTick(void) {
    static DWORD last; DWORD now = GetTickCount();
    Msg *m;
    g_lastTick = now; g_mainTid = GetCurrentThreadId();
    if (g_inWorld) return;
    g_inWorld = 1;
    while ((m = QPop(&g_in))) {
        if (m->type == MSG_START) HandleStart(m->data, m->len);
        else if (m->type == MSG_ORDER && g_started) { LogHex("<- client", m->data, m->len); Process(m->data, m->len); }
        free(m);
    }
    if (g_started && now - last >= 50) {
        // ponytail: elapsed is wall time since the last tick; a long stall gives the world one big step
        if (g_ticks % 200 == 199) LogCombatCounters();
        WatchLife();
        if (++g_ticks % 100 == 0 || g_ticks < 4) Log("tick %d, world update, state %d", g_ticks, *(int *)((char *)g_world + SW_STATE));
        if (!g_buildStarted && *(int *)((char *)g_world + SW_STATE) == 1) {
            // Asserts "mBuildThread != _null" and faults after setting its flags; the world then builds on its own
            // thread anyway ("BuildDungeon OK"). Logged, harmless.
            g_buildStarted = 1;
            __try { ((void (__fastcall *)(void *, int))Slot(g_world, SW_START_BUILD))(g_world, 0); Log("build thread started"); }
            __except (EXCEPTION_EXECUTE_HANDLER) { Log("StartBuild crashed %08lx", GetExceptionCode()); }
        }
        __try { ((Fn1)Slot(g_world, SW_UPDATE))(g_world, 0, (int)(now - last)); }
        __except (EXCEPTION_EXECUTE_HANDLER) { Log("Update crashed %08lx, stopping", GetExceptionCode()); g_started = 0; }
        WatchLife();
        CheckGameOver();
        last = now;
    } else if (!g_started) last = now;
    g_inWorld = 0;
}

static DWORD WINAPI ServerLink(LPVOID p) {
    SOCKET ls = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    struct sockaddr_in a = { 0 };
    a.sin_family = AF_INET; a.sin_port = htons(LINK_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(ls, (struct sockaddr *)&a, sizeof a) || listen(ls, 1)) { Log("link listen on %d failed (%d)", LINK_PORT, WSAGetLastError()); return 0; }
    Log("link listening on 127.0.0.1:%d", LINK_PORT);
    for (;;) {
        SOCKET s = accept(ls, 0, 0);
        if (s == INVALID_SOCKET) { Sleep(500); continue; }
        Log("client linked");
        g_peer = s;
        ReadLink(s);
        Log("client link closed");
        if (g_peer == s) g_peer = INVALID_SOCKET;
        closesocket(s);
    }
}

// =====================================================================================================================
// Client role
// =====================================================================================================================
static int g_inMatch, g_flushing;

// ---- capture of the client's own room serializations (what the dispatch server used to forward) ----
typedef int (__fastcall *SerFn)(void *self, int edx, unsigned char *buf, int size);
static unsigned char g_serGameTramp[16], g_serPlayerTramp[16];

static int __fastcall SerGame(void *self, int edx, unsigned char *buf, int size) {
    int r = ((SerFn)(void *)g_serGameTramp)(self, 0, buf, size);
    if (r > 0 && r <= (int)sizeof g_gameData) { memcpy(g_gameData, buf, r); g_gameLen = r; LogHex("captured game data", buf, r); }
    return r;
}

static int __fastcall SerPlayer(void *self, int edx, unsigned char *buf, int size) {
    int r = ((SerFn)(void *)g_serPlayerTramp)(self, 0, buf, size);
    if (r > 0 && r <= (int)sizeof g_playerData) { memcpy(g_playerData, buf, r); g_playerLen = r; LogHex("captured player data", buf, r); }
    return r;
}

// Prologue of both: push ebp; mov ebp,esp; push -1; push imm32 (10 position-independent bytes).
static void HookSerializer(DWORD at, unsigned char *tramp, void *hook, const char *name) {
    unsigned char *p = (unsigned char *)at; DWORD old;
    if (p[0] != 0x55 || p[1] != 0x8b || p[2] != 0xec || p[3] != 0x6a || p[4] != 0xff || p[5] != 0x68) { LogHex(name, p, 10); Log("%s: unexpected bytes, not hooked", name); return; }
    memcpy(tramp, p, 10); tramp[10] = 0xE9; *(DWORD *)(tramp + 11) = (DWORD)(p + 10) - (DWORD)(tramp + 15);
    VirtualProtect(tramp, 16, PAGE_EXECUTE_READWRITE, &old);
    VirtualProtect(p, 5, PAGE_EXECUTE_READWRITE, &old);
    p[0] = 0xE9; *(DWORD *)(p + 1) = (DWORD)hook - (DWORD)(p + 5);
    VirtualProtect(p, 5, old, &old);
    FlushInstructionCache(GetCurrentProcess(), p, 5);
    Log("%s hooked", name);
}

static DWORD WINAPI ClientLinkReader(LPVOID p) {
    SOCKET s = (SOCKET)p;
    ReadLink(s);
    Log("server link closed");
    if (g_peer == s) g_peer = INVALID_SOCKET;
    closesocket(s);
    return 0;
}

static int ConnectServer(void) {   // main thread
    SOCKET s; struct sockaddr_in a = { 0 };
    if (g_peer != INVALID_SOCKET) return 1;
    s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    a.sin_family = AF_INET; a.sin_port = htons(LINK_PORT); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(s, (struct sockaddr *)&a, sizeof a)) { Log("server link connect failed (%d)", WSAGetLastError()); closesocket(s); return 0; }
    g_peer = s;
    CloseHandle(CreateThread(NULL, 0, ClientLinkReader, (LPVOID)s, 0, NULL));
    Log("server linked");
    return 1;
}

// Server frames into the client, at the per-frame tick (a safe point in its loop; never inside its own send calls).
static void ClientFlush(void) {
    Msg *m;
    if (g_inMatch) HookHitProbe();   // same probe in the client: does the client resolve hits itself (prediction)?
    if (g_flushing) return;
    g_flushing = 1;
    while ((m = QPop(&g_in))) {
        if (m->type == MSG_FRAME) {
            // A frame can batch several orders (seen: 0x0506 combat results, 701 bytes of 78-byte orders), but the
            // dispatcher's input handles exactly one order per call and ignores the length, so split by each order's
            // own size (u16 at +2), as the client's network layer does.
            int off = 0;
            LogHex("-> client", m->data, m->len);
            while (off + 4 <= m->len) {
                const unsigned char *o = m->data + off;
                int sz = *(unsigned short *)(o + 2);
                if (sz < 4 || off + sz > m->len) { LogHex("  bad order size in frame", o, m->len - off); break; }
                if (off) LogHex("  + batched order", o, sz);
                if (*(unsigned short *)o == 0x2024) {   // game result: GameMain hands it to the UI at +0x294/+0x2a0
                    char *gm = *(char **)0x66b9cae0;     // unless +0x234 == 1 (handler 0x66aa4f2c)
                    if (gm) Log("game result for the UI: GameMain+0x234 = %d, ui +0x294 %p, +0x2a0 %p",
                                *(int *)(gm + 0x234), *(void **)(gm + 0x294), *(void **)(gm + 0x2a0));
                }
                __try { ((GameInputFn)GAMEMAIN_GAME_INPUT)(0, 0, o, sz); }
                __except (EXCEPTION_EXECUTE_HANDLER) { Log("GameInput crashed %08lx on 0x%x", GetExceptionCode(), *(unsigned short *)o); }
                off += sz;
            }
        }
        free(m);
    }
    g_flushing = 0;
}

// ---- OrderDispatcher callbacks (the path the game orders really take) ----
typedef void (__cdecl *ToServerFn)(const unsigned char *msg, int size);
typedef void (__cdecl *LocalFn)(const unsigned char *msg);
static ToServerFn g_origToServer;
static LocalFn g_origLocal;
static void **g_disp;

// Server role probe: orders the server's own modules (combat, AI, quest) push through the dispatcher's +8 / +0xc
// during a match. In this process those callbacks belong to the idle hall client, so anything meant for the players
// (e.g. a monster death) would be swallowed there. Logs the first 3 of each id with a dump, passes everything through.
static void ServerSaw(const char *path, const unsigned char *msg) {
    static unsigned short ids[256]; static int counts[256], n;
    unsigned short id = *(unsigned short *)msg; int i;
    if (!g_started || (id >= 0x195 && id <= 0x197)) return;
    for (i = 0; i < n && ids[i] != id; i++) ;
    if (i == n) { if (n == 256) return; ids[n++] = id; }
    if (++counts[i] <= 3) { char tag[48]; sprintf(tag, "server dispatch %s 0x%04x #%d", path, id, counts[i]); LogHex(tag, msg, *(unsigned short *)(msg + 2)); }
}

static void __cdecl MyToServer(const unsigned char *msg, int size) {
    unsigned short id = *(unsigned short *)msg;
    if (g_server) { ServerSaw("+8", msg); if (g_origToServer) g_origToServer(msg, size); return; }
    if (id == 0x2002) {
        // Test: the client may resolve combat results itself (no monster life/death frames come from the server,
        // yet the player's own HP changes on screen). Its hit formula needs the script system, which only a server
        // database init creates; create it in the client too (once).
        static int scripts;
        if (!scripts) {
            void *db = 0; int ok = 0;
            __try { db = ((void *(__cdecl *)(void))GAMEMAIN_GET_GAMEDB)(); ok = db ? ((int (__fastcall *)(void *, int))GAMEDB_INIT_SCRIPT)(db, 0) : 0; }
            __except (EXCEPTION_EXECUTE_HANDLER) { Log("client script init crashed %08lx", GetExceptionCode()); }
            Log("client gamedatabase %p, script system init -> %d", db, ok);
            scripts = 1;
        }   // match login: (re)start the server's world with this room's data, then pass the login on
        if (ConnectServer()) {
            static unsigned char start[8 + sizeof g_gameData + sizeof g_playerData];
            unsigned g = g_gameLen, p = g_playerLen;
            memcpy(start, &g, 4); memcpy(start + 4, g_gameData, g);
            memcpy(start + 4 + g, &p, 4); memcpy(start + 8 + g, g_playerData, p);
            SendMsg(MSG_START, start, 8 + g + p, 0, 0);
        }
    }
    // ponytail: routing by id; town-server orders are 0x03xx, everything else in a match belongs to the game server
    if ((g_inMatch || id == 0x2002) && (id < 0x300 || id > 0x3ff) && g_peer != INVALID_SOCKET) {
        g_inMatch = 1;
        LogHex("<- client", msg, size);
        SendMsg(MSG_ORDER, msg, size, 0, 0);
        return;
    }
    if (g_origToServer) g_origToServer(msg, size);
}

static void __cdecl MyLocal(const unsigned char *msg) {
    unsigned short id = *(unsigned short *)msg;
    if (id >= 0x195 && id <= 0x197) { if (g_server) ServerTick(); else ClientFlush(); }   // per-frame orders
    else if (g_server) ServerSaw("+c", msg);
    g_origLocal(msg);
}

// Re-run every tick and every second from Boot: GameMain can replace its dispatcher (seen after order 0x10d, a scene
// switch) and re-install its callbacks, so the pointer and the hooks are re-checked.
static void HookDispatcher(void) {
    void **d;
    if (!GetModuleHandleW(L"WEGameMain.dll")) return;
    __try { d = ((void **(__cdecl *)(void))GAMEMAIN_DISPATCHER)(); }
    __except (EXCEPTION_EXECUTE_HANDLER) { return; }
    if (!d) return;
    if (d != g_disp) { g_disp = d; Log("OrderDispatcher %p cb +8 %p +c %p", d, d[2], d[3]); }
    if (d[DISP_LOCAL / 4] && d[DISP_LOCAL / 4] != (void *)MyLocal) {
        g_origLocal = (LocalFn)d[DISP_LOCAL / 4]; d[DISP_LOCAL / 4] = (void *)MyLocal; Log("dispatcher Local hooked (orig %p)", g_origLocal);
    }
    if (d[DISP_TO_SERVER / 4] && d[DISP_TO_SERVER / 4] != (void *)MyToServer) {
        g_origToServer = (ToServerFn)d[DISP_TO_SERVER / 4]; d[DISP_TO_SERVER / 4] = (void *)MyToServer;
        Log("dispatcher ToServer hooked (orig %p)", g_origToServer);
    }
}

// =====================================================================================================================
// Both roles: crash logging, main-thread timer, boot
// =====================================================================================================================
static void LogAddr(const char *tag, DWORD a) {
    HMODULE m = NULL; wchar_t name[MAX_PATH] = L"?";
    GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, (LPCWSTR)a, &m);
    if (m) GetModuleFileNameW(m, name, MAX_PATH);
    Log("%s %08lx = %ls+%lx", tag, a, wcsrchr(name, L'\\') ? wcsrchr(name, L'\\') + 1 : name, a - (DWORD)m);
}

// Log serious exceptions (first chance), each faulting address once, with a raw stack scan for return addresses.
static LONG CALLBACK OnException(EXCEPTION_POINTERS *e) {
    static DWORD seen[40]; static int n;
    DWORD c = e->ExceptionRecord->ExceptionCode, at = (DWORD)e->ExceptionRecord->ExceptionAddress, *sp; int i, k;
    if (c != EXCEPTION_ACCESS_VIOLATION && c != EXCEPTION_STACK_OVERFLOW && c != 0xC0000409 && c != EXCEPTION_ILLEGAL_INSTRUCTION
        && c != EXCEPTION_INT_DIVIDE_BY_ZERO && c != 0xC0000374 && c != EXCEPTION_PRIV_INSTRUCTION) return EXCEPTION_CONTINUE_SEARCH;
    for (i = 0; i < n; i++) if (seen[i] == at) return EXCEPTION_CONTINUE_SEARCH;
    if (n >= 40) return EXCEPTION_CONTINUE_SEARCH;
    seen[n++] = at;
    Log("EXCEPTION %08lx thread %lu, info %08lx %08lx", c, GetCurrentThreadId(),
        (DWORD)e->ExceptionRecord->ExceptionInformation[0], (DWORD)e->ExceptionRecord->ExceptionInformation[1]);
    LogAddr("  at", at);
    sp = (DWORD *)e->ContextRecord->Esp;
    for (i = 0, k = 0; i < 400 && k < 12; i++) {
        DWORD v; MEMORY_BASIC_INFORMATION mi;
        __try { v = sp[i]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
        if (v > 0x400000 && VirtualQuery((void *)v, &mi, sizeof mi) && (mi.Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE))) { LogAddr("  stack", v); k++; }
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

static void Tick(void) {
    HookDispatcher();
    if (g_server) ServerTick(); else ClientFlush();
}

static LRESULT CALLBACK HookProc(HWND h, UINT msg, WPARAM w, LPARAM l) {
    if (msg == WM_TIMER && w == 0x57E) { Tick(); return 0; }
    return CallWindowProcW(g_oldProc, h, msg, w, l);
}

static BOOL CALLBACK FindGameWindow(HWND h, LPARAM l) {
    DWORD pid; wchar_t title[64];
    GetWindowThreadProcessId(h, &pid);
    if (pid == GetCurrentProcessId() && IsWindowVisible(h) && GetWindowTextW(h, title, 64) && wcsstr(title, L"WARRIOR")) { g_wnd = h; return FALSE; }
    return TRUE;
}

// Server watchdog (called every second from Boot): if the world hasn't ticked for 5 s during a match, pause the main
// thread and log where it is (EIP + return addresses on its stack), once per stall.
static void LogAddr(const char *tag, DWORD a);
static void Watchdog(void) {
    static DWORD reported;
    HANDLE th; CONTEXT c; DWORD *sp; int i, k;
    if (!g_server || !g_started || !g_mainTid || GetTickCount() - g_lastTick < 5000 || reported == g_lastTick) return;
    reported = g_lastTick;
    Log("WATCHDOG: no world update for %lu ms, main thread %lu:", GetTickCount() - g_lastTick, g_mainTid);
    th = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT, FALSE, g_mainTid);
    if (!th) { Log("  OpenThread failed %lu", GetLastError()); return; }
    SuspendThread(th);
    c.ContextFlags = CONTEXT_FULL;
    if (GetThreadContext(th, &c)) {
        LogAddr("  at", c.Eip);
        sp = (DWORD *)c.Esp;
        for (i = 0, k = 0; i < 2000 && k < 16; i++) {
            DWORD v; MEMORY_BASIC_INFORMATION mi;
            __try { v = sp[i]; } __except (EXCEPTION_EXECUTE_HANDLER) { break; }
            if (v > 0x400000 && VirtualQuery((void *)v, &mi, sizeof mi) && (mi.Protect & (PAGE_EXECUTE_READ | PAGE_EXECUTE_READWRITE | PAGE_EXECUTE))) { LogAddr("  stack", v); k++; }
        }
    }
    ResumeThread(th); CloseHandle(th);
}

// The shell replaces its login window with the game window, so keep watching and hook whichever is current.
static DWORD WINAPI Boot(LPVOID p) {
    HWND hooked = NULL;
    WSADATA wsa;
    WSAStartup(MAKEWORD(2, 2), &wsa);
    if (g_server) CloseHandle(CreateThread(NULL, 0, ServerLink, NULL, 0, NULL));
    while (!GetModuleHandleW(L"WEGameMain.dll")) Sleep(200);
    if (!g_server) {
        HookSerializer(GAMEMAIN_SER_GAME, g_serGameTramp, SerGame, "LogicGameRoomData::Serialize");
        HookSerializer(GAMEMAIN_SER_PLAYER, g_serPlayerTramp, SerPlayer, "LogicGameRoomPlayerData::Serialize");
    }
    for (;;) {
        if (!GetModuleHandleW(L"WEHallUI.dll")) { Sleep(1000); continue; }   // leave the login window alone
        g_wnd = NULL;
        EnumWindows(FindGameWindow, 0);
        if (g_wnd && g_wnd != hooked) {
            g_oldProc = (WNDPROC)SetWindowLongPtrW(g_wnd, GWLP_WNDPROC, (LONG_PTR)HookProc);
            SetTimer(g_wnd, 0x57E, 50, NULL);
            hooked = g_wnd;
            Log("hooked window %p", g_wnd);
            if (g_server) SetWindowTextW(g_wnd, L"WARRIOR EPIC - game server (leave running)");   // keeps "WARRIOR" for the scripts
        }
        HookDispatcher();   // also when the window timer doesn't fire (3D lobby, dungeon)
        Watchdog();
        Sleep(1000);
    }
}

static int ReadServerPid(void) {
    FILE *f = _wfopen(L"C:\\vm\\out\\server.pid", L"r"); int pid = 0;
    if (f) { if (fscanf(f, "%d", &pid) != 1) pid = 0; fclose(f); }
    return pid;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID r) {
    if (reason == DLL_PROCESS_ATTACH) {
        g_server = ReadServerPid() == (int)GetCurrentProcessId();
        g_log = _wfopen(g_server ? L"C:\\vm\\out\\host_server.log" : L"C:\\vm\\out\\host_client.log", L"a");
        if (g_server && AllocConsole()) {
            SetConsoleTitleW(L"WE game server (log)");
            g_console = GetStdHandle(STD_OUTPUT_HANDLE);
        }
        Log("wehost loaded into pid %lu as %s", GetCurrentProcessId(), g_server ? "SERVER" : "CLIENT");
        QInit(&g_in);
        AddVectoredExceptionHandler(1, OnException);
        DisableThreadLibraryCalls(inst);
        CloseHandle(CreateThread(NULL, 0, Boot, NULL, 0, NULL));
    }
    return TRUE;
}
