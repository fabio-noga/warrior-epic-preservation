# Warrior Epic stub server (VM only). Logs every byte to out\stub.log.
# v13: UDP acks (data server), quiet logging. v4: transport handshake (0x62 -> 0x63), pings (0xf1 -> 0xf2), PSIP ConnectReq -> ConnectRes, IS Connect (1 -> 2 + ip3 server list);
# everything else is logged, not answered. Packet header (24 bytes), see RECON.md section 5:
#   +0 u8 version(2) +1 u8 type +2 u8 +3 u8 +4 u16 secret +6 u16 session +8 u16 conn
#   +0xa u16 flags +0x12 u16 total size, payload from +0x18
$out = Join-Path $PSScriptRoot 'out'
New-Item -ItemType Directory -Force $out | Out-Null
$log = Join-Path $out 'stub.log'

$logw = New-Object IO.StreamWriter($log, $true); $logw.AutoFlush = $true   # one handle, not reopened per line
function Log($m) {
    $l = '{0:HH:mm:ss.fff} {1}' -f (Get-Date), $m
    Write-Host $l
    $logw.WriteLine($l)
}

function Dump([byte[]]$b) {
    for ($i = 0; $i -lt $b.Length; $i += 16) {
        $chunk = $b[$i..([Math]::Min($i + 15, $b.Length - 1))]
        $hex = ($chunk | ForEach-Object { $_.ToString('x2') }) -join ' '
        $asc = -join ($chunk | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
        Log ('    {0:x4}  {1,-47}  {2}' -f $i, $hex, $asc)
    }
}

function U16([byte[]]$b, $o) { [BitConverter]::ToUInt16($b, $o) }

# Per-peer transport state learned from the client's 0x62: secret, its session id, its connection id.
# Every server->client frame must carry these (a wrong session id = "INVALID PACKET" on the client).
$peers = @{}

function Frame($peer, [byte]$type, [byte[]]$payload) {
    $st = $peers[$peer]
    $r = New-Object byte[] (0x18 + $payload.Length)
    $r[0] = 2; $r[1] = $type
    if ($st) {
        [BitConverter]::GetBytes([uint16]$st.Secret).CopyTo($r, 4)
        [BitConverter]::GetBytes([uint16]$st.Sess).CopyTo($r, 6)
        [BitConverter]::GetBytes([uint16]$st.Conn).CopyTo($r, 8)
        if ($st.Udp) {
            # UDP: our packets are unsequenced (flag 0x80) and carry the cumulative ack (+0x16 = next expected seq)
            [BitConverter]::GetBytes([uint16]0x80).CopyTo($r, 0xa)
            [BitConverter]::GetBytes([uint16]$st.Recv).CopyTo($r, 0x16)
        }
    }
    [BitConverter]::GetBytes([uint16]$r.Length).CopyTo($r, 0x12)
    if ($payload) { $payload.CopyTo($r, 0x18) }
    return ,$r
}

# PSIP (session layer inside 0xad data frames): u8 2, u8 subtype (1 ConnectReq, 2 ConnectRes, 3..5 TBD).
function PsipReply($peer, [byte[]]$p) {
    if ($p.Length -lt 2 -or $p[0] -ne 2) { return $null }
    if ($p[1] -eq 1 -and $p.Length -ge 0x22) {
        # ConnectRes: echo u16 + request id, result 101001 (success), PSUID (19 bytes, non-zero), server ip/port
        $r = New-Object byte[] 0x25
        $r[0] = 2; $r[1] = 2
        [Array]::Copy($p, 2, $r, 2, 6)
        [BitConverter]::GetBytes([uint32]101001).CopyTo($r, 8)
        $r[0xc] = 1; $r[0xd] = 1                       # PSUID: type 1, id 1
        [Array]::Copy($p, 0x1c, $r, 0x1f, 6)           # ip + port as the client sent them
        Log "PSIP ConnectReq -> ConnectRes (success)"
        return ,(Frame $peer 0xad $r)
    }
    if ($p[1] -eq 3 -and $p.Length -ge 0xd) {
        # Wrapper: +2 u16, +4 u8 service, +5 u32 arg, +9 u32 inner length, +0xd inner message
        $svc = $p[4]; $len = [BitConverter]::ToUInt32($p, 9)
        $inner = [byte[]]$p[0xd..(0xd + $len - 1)]
        Log ("PSIP wrapper service {0} arg 0x{1:x8} inner msg 0x{2:x2} len {3}" -f $svc, [BitConverter]::ToUInt32($p, 5), $inner[0], $len)
        $out = New-Object System.Collections.Generic.List[byte]
        foreach ($ri in (IsReply $inner)) {             # zero or more IS messages back
            $r = New-Object byte[] (0xd + $ri.Length)
            [Array]::Copy($p, 0, $r, 0, 9)              # 02 03, u16, service, arg echoed
            [BitConverter]::GetBytes([uint32]$ri.Length).CopyTo($r, 9)
            $ri.CopyTo($r, 0xd)
            $out.AddRange([byte[]](Frame $peer 0xad $r))  # TCP: frames are simply concatenated
        }
        if ($out.Count -eq 0) { return $null }
        return ,$out.ToArray()
    }
    Log ("PSIP subtype {0} not handled yet" -f $p[1])
    return $null
}

# Interface Server messages (inside the PSIP wrapper). +0 u8 id, 8-byte common header (02 00 04 00 00 00 00 after id).
# Names (from the client's table): ip1/2 Connect to IS req/res, ip3 Synchronize Servers (server push),
# ip4/5 Redirect Transaction, ip6 Client Command, ip7/8 Query IS List, ip9/10 Query FS List.
# Server types (bit flags): MLS 1, IS 2, AS 4, MSS 8, SS 0x10, MCS 0x20, CS 0x40, BS 0x80, GS 0x2000, MS 0x4000, MMS 0x8000,
# WES 0x10000, TS 0x40000, GLS 0x1000000, DSPS 0x2000000.
$ssdUrl = 'http://127.0.0.1:8080/ssd/'   # patcher feed; served (logged) by the HTTP logger below
$servers = 4, 8, 0x10, 0x20, 0x40, 0x80, 0x4000, 0x8000, 0x10000, 0x2000000, 0x2000   # last: GS (game server, id 20), named in MP_StartGameNotice
# A server's PSUID dword at +1 is (typeIndex << 16) | id; the client finds servers by (id, type) with exactly that
# compare (exe 0x436f30, typeIndex = 0x436300). With a zero high word every by-id lookup failed, e.g.
# "SendDataToServer, Invalid server id: 13" on START. ids stay 10 + position in $servers.
$typeIndex = @{ 4 = 3; 8 = 4; 0x10 = 5; 0x20 = 6; 0x40 = 7; 0x80 = 8; 0x4000 = 0xe; 0x8000 = 0xf; 0x10000 = 0x10; 0x2000000 = 0x19; 0x2000 = 0xd }
function ServerId([int]$i) { [uint32](($typeIndex[[int]$servers[$i]] -shl 16) -bor (10 + $i)) }

function IsMsg([byte]$id, [int]$size) {
    $r = New-Object byte[] $size
    $r[0] = $id; $r[1] = 2; $r[3] = 4
    return ,$r
}

# ip3 Synchronize Servers: +8 u8 change (1 = connected), +9 u16 count, then 31-byte records:
# PSUID (19: +0 u8 1, +1 u32 id, +0xb u32, +0xf u32), +0x13 u32 type, +0x17 u32 version, +0x1b u32 status (1 = up)
function SyncServers {
    $r = IsMsg 3 (0xb + 31 * $servers.Count)
    $r[8] = 1
    [BitConverter]::GetBytes([uint16]$servers.Count).CopyTo($r, 9)
    for ($i = 0; $i -lt $servers.Count; $i++) {
        $o = 0xb + 31 * $i
        $r[$o] = 1
        [BitConverter]::GetBytes((ServerId $i)).CopyTo($r, $o + 1)
        [BitConverter]::GetBytes([uint32]$servers[$i]).CopyTo($r, $o + 0x13)
        [BitConverter]::GetBytes([uint32]1).CopyTo($r, $o + 0x17)
        [BitConverter]::GetBytes([uint32]1).CopyTo($r, $o + 0x1b)
    }
    return ,$r
}

# 0x17 AvailableVersion: +8 u32 count, +0xc u32 offset (8), u32 versions (major<<16 | minor).
# The shell needs its own version (4.001; v4.001\gamemain_v4.001.psmf exists) in this list.
function Versions {
    $v = IsMsg 0x17 0x14
    [BitConverter]::GetBytes([uint32]1).CopyTo($v, 8)
    [BitConverter]::GetBytes([uint32]8).CopyTo($v, 0xc)
    [BitConverter]::GetBytes([uint32]0x00040001).CopyTo($v, 0x10)
    return ,$v
}

# 0x10 envelope = a backend server's message relayed by the IS (same layout as the client's 0x0f request,
# but with the 19-byte source PSUID instead of the u32 target type):
# +8 PSUID, +0x1b u8 protocol (AP 4, SP 5), +0x1c u32 1, +0x20 u8 format (3 plain, 5 compressed), +0x21 u32 len, +0x25 data.
function Envelope([byte[]]$req, $type, [byte]$proto, [byte[]]$data) {
    $r = New-Object byte[] (0x25 + $data.Length)
    [Array]::Copy($req, 0, $r, 0, 8); $r[0] = 0x10
    $r[8] = 1; [BitConverter]::GetBytes((ServerId ([array]::IndexOf($servers, [int]$type)))).CopyTo($r, 9)
    $r[0x1b] = $proto; $r[0x1c] = 1; $r[0x20] = 3
    [BitConverter]::GetBytes([uint32]$data.Length).CopyTo($r, 0x21)
    $data.CopyTo($r, 0x25)
    return ,$r
}

function WStr([byte[]]$buf, $off, [string]$s) { [Text.Encoding]::Unicode.GetBytes($s).CopyTo($buf, $off) }

# Backend servers reached through the IS (client 0x0f request: +8 u32 target type, data at +0x16).
# AS (type 4) speaks AP (+0 u8 id, +4 u32 transaction id):
#   AP_Validate_Res (4): +8 u32 result (0x1967C AP_E_ValidateSucc), +0xc u32 AccountID, +0x10 UTF-16 string.
# After a successful login the MSS (type 8) pushes SP (protocol 5):
#   SP_CreateSession_Res (2), fixed 0xa8 bytes: +8 u32 result (0x19A28 = success), +0xc PSUID (19),
#   +0x23 u32 (session value), +0x28 UTF-16[32], +0x68 UTF-16[32]. +4 is overwritten by the client.
$account = 'a'
# Chat-server area tree: regions (map markers, named as in UI\ServerList.txt) under root 1, lobbies under regions.
$areas = @(@{ Id = 2; Parent = 1; Name = 'USA' }, @{ Id = 3; Parent = 2; Name = 'Lobby 1' })
function ServerReply($type, [byte[]]$d) {
    $out = New-Object System.Collections.ArrayList
    if ($type -eq 4) {
        $u = [Text.Encoding]::Unicode.GetBytes($account + [char]0)
        $r = New-Object byte[] (0x10 + $u.Length)
        $r[0] = 4
        [Array]::Copy($d, 4, $r, 4, 4)
        [BitConverter]::GetBytes([uint32]0x1967C).CopyTo($r, 8)
        [BitConverter]::GetBytes([uint32]1).CopyTo($r, 0xc)
        $u.CopyTo($r, 0x10)
        [void]$out.Add(@{ Type = 4; Proto = 4; Data = $r })
        $c = New-Object byte[] 0xa8
        $c[0] = 2
        [BitConverter]::GetBytes([uint32]0x19A28).CopyTo($c, 8)
        $c[0xc] = 1; $c[0xd] = 12                       # session PSUID (our SS)
        [BitConverter]::GetBytes([uint32]1).CopyTo($c, 0x23)
        WStr $c 0x28 $account; WStr $c 0x68 $account
        [void]$out.Add(@{ Type = 8; Proto = 5; Data = $c })
        Log "AS login (AP request 0x$('{0:x2}' -f $d[0])) -> Validate_Res success (AccountID 1) + MSS CreateSession_Res success"
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 0x28) {
        # CS speaks CP (protocol 6). 0x28 Query All Area List -> CP_SynAllArea (0x25): +8 u32 count, records at +0xc:
        # +0 u32 AreaID, +4 u32 parent (1 = top level), +8 u32, +0xc u16 SubLobby, +0xe u16 SubRoom,
        # +0x10 u16 name bytes (incl. NUL), +0x12 UTF-16 name. These are the entries of the "choose a lobby" box.
        $o = New-Object System.Collections.Generic.List[byte]
        $o.AddRange([byte[]]$d[0..7]); $o[0] = 0x25
        $o.AddRange([BitConverter]::GetBytes([uint32]$areas.Count))
        foreach ($a in $areas) {
            $name = [Text.Encoding]::Unicode.GetBytes($a.Name + [char]0)
            $o.AddRange([BitConverter]::GetBytes([uint32]$a.Id)); $o.AddRange([BitConverter]::GetBytes([uint32]$a.Parent))
            $o.AddRange([byte[]](0, 0, 0, 0, 0, 0, 0, 0)); $o.AddRange([BitConverter]::GetBytes([uint16]$name.Length)); $o.AddRange($name)
        }
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $o.ToArray() })
        Log "CS Query All Area List -> $(($areas | % { "$($_.Id) '$($_.Name)' (parent $($_.Parent))" }) -join ', ')"
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 2 -and $d[8] -eq 2) {
        # CP 0x02 sub-op 2 "Query AreaList" (+0xc AreaID) -> CP_SynAreaList (0x03): +8 u32 AreaID, +0xc u32 count,
        # 12-byte records at +0x10: u32 AreaID, u32 SubRoom, u32 SubLobby (counts shown in the lobby box).
        # the client may ask this before its 0x28 is answered; send the area tree first or it "Can Not Find Area"
        foreach ($e in (ServerReply $type ([byte[]](0x28, 1, 0, 0x0c, 0, 0, 0, 0, 0, 0, 0, 0)))) { [void]$out.Add($e) }
        $q = [BitConverter]::ToUInt32($d, 0xc)
        $kids = @($areas | ? { $_.Parent -eq $q })
        $r = New-Object byte[] (0x10 + 12 * $kids.Count)
        [Array]::Copy($d, 0, $r, 0, 8); $r[0] = 3
        [Array]::Copy($d, 0xc, $r, 8, 4)
        [BitConverter]::GetBytes([uint32]$kids.Count).CopyTo($r, 0xc)
        for ($i = 0; $i -lt $kids.Count; $i++) {
            $sub = @($areas | ? { $_.Parent -eq $kids[$i].Id }).Count
            [BitConverter]::GetBytes([uint32]$kids[$i].Id).CopyTo($r, 0x10 + 12 * $i)
            [BitConverter]::GetBytes([uint32]1).CopyTo($r, 0x14 + 12 * $i)          # SubRoom
            [BitConverter]::GetBytes([uint32]$sub).CopyTo($r, 0x18 + 12 * $i)       # SubLobby
        }
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $r })
        Log "CS Query AreaList $q -> $($kids.Count) children"
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 2 -and $d[8] -eq 1) {
        # CP 0x02 kind 1 QueryRoomList (+0xc AreaID, +0x10 room-type mask) -> CP_SyncRoomList (0x04): +0xc AreaID,
        # +0x10 type, +0x14 LSArray {u32 count, u32 offset 8}, 0x60-byte rooms: +0 u32 id, +4 UTF-16[32] name,
        # +0x48 u8 type (matched against the mask), +0x4c/+0x50/+0x54/+0x58 u32 (counts, guessed 0 / max 100).
        $q = [BitConverter]::ToUInt32($d, 0xc); $mask = [BitConverter]::ToUInt32($d, 0x10)
        $r = New-Object byte[] (0x1c + 0x60)
        [Array]::Copy($d, 0, $r, 0, 8); $r[0] = 4
        [Array]::Copy($d, 0xc, $r, 0xc, 8)
        $r[0x14] = 1; $r[0x18] = 8
        [BitConverter]::GetBytes([uint32](100 + $q)).CopyTo($r, 0x1c)
        [Text.Encoding]::Unicode.GetBytes('Lobby 1').CopyTo($r, 0x20)
        $r[0x1c + 0x48] = [byte]($mask -band 0xff)
        [BitConverter]::GetBytes([uint32]100).CopyTo($r, 0x1c + 0x58)
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $r })
        Log ("CS QueryRoomList area {0} mask 0x{1:x} -> room {2} 'Lobby 1'" -f $q, $mask, (100 + $q))
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 0x0a) {
        # CP 0x0a JoinRoom (+4 u32 callback id, +8 u32 RoomID, +0x14 u32 type) -> CP_JoinRoom_Res (0x0b, 0x74 bytes,
        # handler exe 0x47f890): +4 callback (echo), +8 RoomID, +0xc result (0x19e1a = success), +0x10 ChatServer,
        # +0x14 RoomID, +0x18 UTF-16[31] name, +0x58 AreaID, +0x5c type, +0x60.. (guess: town ip, port).
        $room = [BitConverter]::ToUInt32($d, 8)
        $r = New-Object byte[] 0x74
        [Array]::Copy($d, 0, $r, 0, 8); $r[0] = 0x0b
        [Array]::Copy($d, 8, $r, 8, 4); [Array]::Copy($d, 8, $r, 0x14, 4)
        [BitConverter]::GetBytes([uint32]0x19e1a).CopyTo($r, 0xc)
        $r[0x10] = 13      # ChatServer = server index 13 (MCS, where the client sends CP); 14 gives "SendDataToServer, Invalid server id"
        [Text.Encoding]::Unicode.GetBytes($(if ($room -ge 200) { 'Game' } else { 'Lobby 1' })).CopyTo($r, 0x18)
        [BitConverter]::GetBytes([uint32]2).CopyTo($r, 0x58)                       # AreaID: everything lives in region 2
        [Array]::Copy($d, 0x14, $r, 0x5c, 4)   # type as requested (4). 0x10 would go to the GameMain lobby handler (gm+0x82c) but the box then stays open
        $r[0x60] = 100; $r[0x68] = 127; $r[0x6b] = 1; [BitConverter]::GetBytes([uint32]8892).CopyTo($r, 0x6c)   # guess: +0x60 max users, +0x68 town ip, +0x6c port
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $r })
        Log ("CS JoinRoom {0} (callback 0x{1:x8}) -> success" -f $room, [BitConverter]::ToUInt32($d, 4))
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 0x0c) {
        # CP 0x0c RoomSendData = room chat (+8 u32 ToUser (0 = all), +0xc FromUser, +0x10 type, +0x14 RoomID, +0x18 u16 bytes,
        # +0x1a UTF-16 text). Answer CP 0x0d (0x18 bytes; +8 result guessed 0x19e24 = CP_E_SendRoomData_Succ) and relay
        # the message back so it shows in the chat box (exe OnRecvData).
        $r = New-Object byte[] 0x18
        [Array]::Copy($d, 0, $r, 0, 0x18); $r[0] = 0x0d
        [BitConverter]::GetBytes([uint32]0x19e24).CopyTo($r, 8)
        [void]$out.Add(@{ Type = 0x20; Proto = 6; Data = $r })
        [void]$out.Add(@{ Type = 0x20; Proto = 6; Data = $d })
        Log ("CS chat room {0}: {1}" -f [BitConverter]::ToUInt32($d, 0x14), [Text.Encoding]::Unicode.GetString($d, 0x1a, [Math]::Max(0, [BitConverter]::ToUInt16($d, 0x18) - 2)))
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 0x14) {
        # CP 0x14 SendRoomCmd ("Set Room Info"; +4 u32 flags (0x40 buffer, 0x80, 0x400 gaming = START), +8 u32 FromUser,
        # +0xc u8 cmd, +0xd u32 RoomID, +0x11 u32 len, +0x15 data). Answer CP 0x15 SendRoomCmd_Res (0x11 bytes, exe 0x47ab60):
        # +4 flags, +8 result (0x19e2e = CP_E_SendRoomCmd_Succ, codes step by 10 from CreateRoom_Succ 106000),
        # +0xc cmd, +0xd RoomID. Then relay the command back like a room server does for every member (exe OnRecvCmd 0x47eb00).
        $r = New-Object byte[] 0x11
        [Array]::Copy($d, 0, $r, 0, 8); $r[0] = 0x15
        [BitConverter]::GetBytes([uint32]0x19e2e).CopyTo($r, 8)
        [Array]::Copy($d, 0xc, $r, 0xc, 5)
        [void]$out.Add(@{ Type = 0x20; Proto = 6; Data = $r })
        [void]$out.Add(@{ Type = 0x20; Proto = 6; Data = $d })
        Log ("CS RoomCmd {0} flags 0x{1:x} room {2} -> ok + relay" -f $d[0xc], [BitConverter]::ToUInt32($d, 4), [BitConverter]::ToUInt32($d, 0xd))
        if ($d[0xc] -eq 3) {
            # Cmd_StartGame: the match server (MMS) tells the client where the game runs. MP = protocol 9 (name table exe
            # 0x426b10). MP_StartGameNotice_Req (id 0x0f, 0x3b bytes, exe handler 0x476d20): +0xc RoomID, +0x10 u64 GameID,
            # +0x18 u32 Token, +0x2f address {u32 ip, u16 transport (2 = UDP, guess), u16 port}, +0x37 u16 SessionId (guess 20).
            $n = New-Object byte[] 0x3b
            $n[0] = 0x0f; $n[1] = 1
            [BitConverter]::GetBytes([uint32]0x1a2f2).CopyTo($n, 8)   # +8 result: 107250 = success (GameMain 0x66a7cfaa)
            [Array]::Copy($d, 0xd, $n, 0xc, 4)
            $n[0x10] = 1; [BitConverter]::GetBytes([uint32]0).CopyTo($n, 0x18)   # token 0: the in-process ServerWorld is started with gameId 0 (tokens 0)
            $n[0x1c] = 1; [BitConverter]::GetBytes((ServerId ([array]::IndexOf($servers, 0x2000)))).CopyTo($n, 0x1d)   # +0x1c PSUID of the game server
            [BitConverter]::GetBytes([uint32]0x7f000001).CopyTo($n, 0x2f); $n[0x33] = 2
            [BitConverter]::GetBytes([uint16]9999).CopyTo($n, 0x35); $n[0x37] = 20
            [void]$out.Add(@{ Type = 0x8000; Proto = 0xa; Data = $n })   # match messages = protocol 10 (module vtable 0x569740 slot 4); 9 = in-game data frames (type 3 plain, 4 fragmented)
            Log "MP StartGameNotice -> game server 127.0.0.1:9999 session 20, token 0"
        }
    } elseif ($type -in 0x20, 0x40 -and $d[0] -eq 0x08) {
        # CP 0x08 CreateRoom (game room; +4 u32 callback id, +8 AreaID, +0x10 type, ...) -> CP_CreateRoom_Res (0x09, 0x14 bytes,
        # handler exe 0x47fc20): +4 callback (echo), +8 result (0x19e10 = success), +0xc new RoomID, +0x10 ChatServer.
        # The client then sends JoinRoom for the new room (handled above).
        $script:nextRoom = if ($script:nextRoom) { $script:nextRoom + 1 } else { 200 }
        $r = New-Object byte[] 0x14
        [Array]::Copy($d, 0, $r, 0, 8); $r[0] = 0x09
        [BitConverter]::GetBytes([uint32]0x19e10).CopyTo($r, 8)
        [BitConverter]::GetBytes([uint32]$script:nextRoom).CopyTo($r, 0xc)
        $r[0x10] = 13      # ChatServer = server index 13 (MCS, where the client sends CP); 14 gives "SendDataToServer, Invalid server id"
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $r })
        Log ("CS CreateRoom (callback 0x{0:x8}, area {1}, type {2}) -> room {3}" -f [BitConverter]::ToUInt32($d, 4), [BitConverter]::ToUInt32($d, 8), [BitConverter]::ToUInt32($d, 0x10), $script:nextRoom)
        # CP 0x20 SyncUserList (exe OnUserListRecv 0x47fff0; length must be 0x15 + array): +8 u8 1 = add, +9 RoomID,
        # +0xd LSArray {u32 count, u32 offset 8}, user = 0x22-byte header (+0 AccID, +4..+0x14 u32, +0x18 u8 name bytes,
        # +0x19 u8 nick bytes, +0x1a u32 buffer len, +0x1e u32 buffer2 len) + UTF-16 name, nick, buffer, buffer2.
        # Without it GameMain's LogicGameRoom has no player, so order 0x157 never serializes the player data.
        $name = [Text.Encoding]::Unicode.GetBytes('Player')
        $u = New-Object byte[] (0x22 + 2 * $name.Length)
        $u[0] = 12; $u[0x18] = $name.Length; $u[0x19] = $name.Length
        $name.CopyTo($u, 0x22); $name.CopyTo($u, 0x22 + $name.Length)
        $l = New-Object byte[] (0x15 + $u.Length)
        [Array]::Copy($d, 0, $l, 0, 8); $l[0] = 0x20; $l[8] = 1
        [BitConverter]::GetBytes([uint32]$script:nextRoom).CopyTo($l, 9)
        $l[0xd] = 1; $l[0x11] = 8
        $u.CopyTo($l, 0x15)
        [void]$out.Add(@{ Type = 0x40; Proto = 6; Data = $l })
        Log "CS SyncUserList room $($script:nextRoom) -> add user 12"
    } else {
        Log ("server type 0x{0:x} not handled yet, data: {1}" -f $type, (($d | Select-Object -First 64 | % { $_.ToString('x2') }) -join ' '))
    }
    return ,$out
}

# Returns a list of IS messages to send back (possibly empty).
function IsReply([byte[]]$m) {
    $res = New-Object System.Collections.ArrayList
    switch ($m[0]) {
        1 {  # Connect to IS -> ip2 (result 103100 = success, empty description at +0x12), then push ip3
            $r = New-Object byte[] 0x14
            [Array]::Copy($m, 0, $r, 0, 8); $r[0] = 2
            [BitConverter]::GetBytes([uint32]103100).CopyTo($r, 8)
            [void]$res.Add($r)
            [void]$res.Add((SyncServers))
            # 0x17 AvailableVersion: +8 u32 count, +0xc u32 offset (8), u32 versions (major<<16 | minor).
            # The shell needs its own version (4.001, i.e. v4.001\gamemain_v4.001.psmf exists) in this list.
            [void]$res.Add((Versions))
            Log "IS Connect -> ok + server list ($($servers.Count) servers) + versions [4.001]"
        }
        7 {  # Query IS List -> ip8: +9 u16, +0xb u16 count, 49-byte records. Empty list.
            $r = New-Object byte[] 0xd
            [Array]::Copy($m, 0, $r, 0, 8); $r[0] = 8
            [void]$res.Add($r); Log "IS Query IS List -> empty"
        }
        0x18 {  # Query SSD URL -> 0x19: +8 u32 char count, +0xc u32 offset (8), UTF-16 string.
            # The shell waits until this is non-empty, then hands it to the embedded SSN patcher.
            $u = [Text.Encoding]::Unicode.GetBytes($ssdUrl + [char]0)
            $r = New-Object byte[] (0x10 + $u.Length)
            [Array]::Copy($m, 0, $r, 0, 8); $r[0] = 0x19
            [BitConverter]::GetBytes([uint32]($ssdUrl.Length + 1)).CopyTo($r, 8)
            [BitConverter]::GetBytes([uint32]8).CopyTo($r, 0xc)
            $u.CopyTo($r, 0x10)
            [void]$res.Add($r); Log "IS Query SSD URL -> $ssdUrl"
        }
        0x16 { [void]$res.Add((Versions)); Log "IS QueryAvailableVersion -> [4.001]" }   # same push as after Connect
        0x15 { Log "IS Set Client Information (no reply)" }
        0x0c {  # QuerySysInfo -> 0x0d: +8 Session, +0xc ChatRoom, +0x10 GameRoom, +0x14 RegisterNum, +0x18..+0x24, +0x28 Enable3Dlobby
            $r = New-Object byte[] 0x2c
            [Array]::Copy($m, 0, $r, 0, 8); $r[0] = 0x0d
            $r[8] = 1; $r[0xc] = 1; $r[0x14] = 1; $r[0x28] = 1   # ChatRoom 1, Enable3Dlobby 1 (after a lobby JoinRoom the 2D UI goes to Hall_3DLobby)
            [void]$res.Add($r); Log "IS QuerySysInfo -> 1 session, Enable3Dlobby 1"
        }
        0x0e {
            # Request to one server by PSUID (same layout as the 0x10 envelope): +9 u32 server index (10 + position
            # in $servers, 0 = none), +0x1b u8 protocol, +0x20 u8 format, +0x21 u32 len, +0x25 data.
            $idx = [BitConverter]::ToUInt32($m, 9) -band 0xffff   # high word = type index
            $data = [byte[]]$m[0x25..($m.Length - 1)]
            if ($idx -ge 10 -and $idx -lt 10 + $servers.Count) {
                $target = $servers[$idx - 10]
                Log ("IS direct request -> type 0x{0:x} proto {1} data[0]=0x{2:x2} len {3}" -f $target, $m[0x1b], $data[0], $data.Length)
                foreach ($e in (ServerReply $target $data)) { [void]$res.Add((Envelope $m $e.Type $e.Proto $e.Data)) }
            } else {
                Log ("IS msg 0x0e to no server (proto {0}): {1}" -f $m[0x1b], (($data | Select-Object -First 48 | % { $_.ToString('x2') }) -join ' '))
            }
        }
        0x0f {
            # Server request, routed by the IS: +8 u32 target server type, +0xc u8, +0xd u32, +0x11 u8, +0x12 u32 len, +0x16 data.
            # Reply 0x10 has the same fields but a 19-byte source PSUID instead of the u32 type (everything shifts by 15):
            # +8 PSUID, +0x1b u8, +0x1c u32, +0x20 u8 (5 = compressed), +0x21 u32 len, +0x25 data.
            $target = [BitConverter]::ToUInt32($m, 8)
            $data = [byte[]]$m[0x16..($m.Length - 1)]
            Log ("IS server request -> type 0x{0:x} data[0]=0x{1:x2} len {2}" -f $target, $data[0], $data.Length)
            foreach ($e in (ServerReply $target $data)) {    # list of @{Type; Proto; Data}
                [void]$res.Add((Envelope $m $e.Type $e.Proto $e.Data))
            }
        }
        default { Log ("IS msg 0x{0:x2} not handled yet" -f $m[0]) }
    }
    return ,$res
}

# Returns the reply frame for one received frame, or $null.
# ---- Data server (WEDS, UDP 8899): PSP-compressed UTF-16 text, see PROTOCOL.md section 5 ----
$pspMark = [byte[]](0xf7,0xf4,0xe4,0xc8,0xca,0xd7,0xd5,0xc2,0xd4,0xd4,0xc2,0xc3,0xe1,0xce,0xcb,0xc2)
function IsPspZ([byte[]]$p) { $p.Length -gt 22 -and -not (Compare-Object $p[0..15] $pspMark -SyncWindow 0) }

function PspUnpack([byte[]]$p) {          # MARK, u32 rawsize, zlib (2-byte header + deflate + adler32)
    $ms = [IO.MemoryStream]::new($p, 22, $p.Length - 22)
    $ds = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $o = New-Object IO.MemoryStream; $ds.CopyTo($o); $ds.Close()
    return ,$o.ToArray()
}

function PspPack([byte[]]$raw) {
    $o = New-Object IO.MemoryStream
    $o.Write($pspMark, 0, 16); $o.Write([BitConverter]::GetBytes([uint32]$raw.Length), 0, 4)
    $o.WriteByte(0x78); $o.WriteByte(0x9c)
    $d = New-Object IO.Compression.DeflateStream($o, [IO.Compression.CompressionMode]::Compress, $true)
    $d.Write($raw, 0, $raw.Length); $d.Close()
    $a = 1; $b = 0; foreach ($x in $raw) { $a = ($a + $x) % 65521; $b = ($b + $a) % 65521 }
    $ad = [BitConverter]::GetBytes([uint32]([int64]$b * 65536 + $a)); [Array]::Reverse($ad)   # adler32, big endian (int64: -shl overflows Int32)
    $o.Write($ad, 0, 4)
    return ,$o.ToArray()
}

# Built-in save (ponytail: hard-coded; becomes a JSON save file once the format is confirmed).
# Keys are flat paths; arrays are name[i] with an explicit name# count. Values carry their wire type.
$save = [ordered]@{
    # arrays are declared with a '#'-prefixed type (array flag 0x100) and an empty value, then filled with name[i]
    'novice' = 'DWD:0'; 'gamemoney' = 'DWD:100000'; 'realmoney' = 'DWD:100000'; 'halllevel' = 'DWD:1'
    'hallwealth' = 'DWD:0'; 'maxcharacter' = 'DWD:8'; 'sacrifice' = 'DWD:0'; 'cheatmode' = 'DWD:0'
    'tutorialflag' = '#DWD:'
    'warriors' = '#STT:'; 'warriors~apd' = '1'   # declare the array, then APD (append) 1 element -> warriors[0]
    'warriors[0].instanceid' = 'DWD:1'; 'warriors[0].warriorid' = 'DWD:16777224'; 'warriors[0].nickname' = 'STR:a'
    'warriors[0].level' = 'DWD:1'; 'warriors[0].experience' = 'DWD:0'; 'warriors[0].flag' = 'DWD:0'
    'warriors[0].totalskillpoint' = 'DWD:0'; 'warriors[0].normalskillpoint' = 'DWD:0'; 'warriors[0].specialskillpoint' = 'DWD:0'
    'warriors[0].equipment' = '#DWD:'; 'warriors[0].skill' = '#STT:'; 'warriors[0].badge' = '#STT:'
    'curselwarriorid' = 'DWD:1'
    'equipments' = '#STT:'; 'spiritslots' = '#DWD:'; 'monsterspirit' = '#STT:'
    'items' = '#STT:'; 'itemslots' = '#STT:'
    'campaigns' = '#STT:'; 'campaigns~apd' = '1'; 'campaigns[0].name' = 'STR:Adventure'; 'campaigns[0].stage' = 'DWD:5'   # accepted campaign (else "campaign is not accepted Adventure")
    'quests' = '#STT:'; 'curselcampaignname' = 'STR:Adventure'; 'lastgameresult' = 'DWD:0'
    'campaignrecord_stage' = '#STT:'; 'campaignrecord_region' = '#STT:'; 'campaignrecord_area' = '#STT:'
    'campaignrecord_quest' = '#STT:'; 'campaignrecord_questtype' = '#STT:'
    'workrooms' = '#STT:'; 'curwarroom' = 'DWD:0'; 'warroomoptions' = '#STT:'; 'warroomobjects' = '#STT:'
    'trophy' = '#STT:'; 'prices' = '#STT:'
}
# Persistent save (Phase 4): vm\save.json overrides the defaults above and is rewritten after every data-server
# operation, so recruits/selections survive stub restarts. Delete it to start from the defaults again.
$saveFile = Join-Path $PSScriptRoot 'save.json'
if (Test-Path $saveFile) {
    Copy-Item $saveFile "$saveFile.bak" -Force   # previous session's save, in case a run goes wrong
    $save = [ordered]@{}
    foreach ($pr in (Get-Content $saveFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties) { $save[$pr.Name] = [string]$pr.Value }
}
# Starting gear and skills per warrior type (vm\startgear.json, made on the host by tools\startgear.py from the game's
# own .base files): the original data server filled them on ADD_WARRIOR. Without them a warrior has no weapon (no basic
# attack) and an empty skill bar.
$startGear = @{}
$gearFile = Join-Path $PSScriptRoot 'startgear.json'
if (Test-Path $gearFile) { foreach ($pr in (Get-Content $gearFile -Raw | ConvertFrom-Json).PSObject.Properties) { $startGear[$pr.Name] = $pr.Value } }
function GearKeys([string]$prefix, [string]$warriorid) {
    # ordered key/values for one warrior: declare, APD n, elements (skill entries: skillid, skillbarindex, level array)
    $g = $startGear[($warriorid -replace '^DWD:')]
    $kv = [ordered]@{}
    $eq = @(if ($g) { $g.equipment }); $sk = @(if ($g) { $g.skill })
    $kv["${prefix}equipment"] = '#DWD:'
    if ($eq.Count) { $kv["${prefix}equipment~apd"] = "$($eq.Count)"; for ($j = 0; $j -lt $eq.Count; $j++) { $kv["${prefix}equipment[$j]"] = "DWD:$($eq[$j])" } }
    $kv["${prefix}skill"] = '#STT:'
    if ($sk.Count) {
        $kv["${prefix}skill~apd"] = "$($sk.Count)"
        for ($j = 0; $j -lt $sk.Count; $j++) {
            $kv["${prefix}skill[$j].skillid"] = "DWD:$($sk[$j])"; $kv["${prefix}skill[$j].skillbarindex"] = "DWD:$j"; $kv["${prefix}skill[$j].level"] = '#DWD:'
        }
    }
    return $kv
}
# Backfill warriors saved before startgear existed (empty equipment): add their starting gear once.
foreach ($k in @($save.Keys)) {
    if ($k -match '^warriors\[(\d+)\]\.warriorid$' -and -not $save.Contains("warriors[$($Matches[1])].equipment~apd")) {
        $i = $Matches[1]; $kv = GearKeys "warriors[$i]." $save[$k]
        if ($kv.Contains("warriors[$i].equipment~apd")) { foreach ($e in $kv.GetEnumerator()) { $save[$e.Key] = $e.Value } }
    }
}

function SaveState {
    $tmp = "$saveFile.tmp"
    $save | ConvertTo-Json | Set-Content $tmp -Encoding UTF8
    Move-Item $tmp $saveFile -Force   # write-then-rename so a crash never leaves half a save
}
function DsReply($peer, [byte[]]$p) {
    $text = [Text.Encoding]::Unicode.GetString((PspUnpack $p)).TrimStart([char]0xFEFF)
    $lines = $text -split "`r`n" | Where-Object { $_ }
    Log ("DS <- " + ($lines -join ' / '))
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($lines[0])                                   # echo header USD|type|callback-id
    $req = @{}; foreach ($l in $lines) { $f = $l -split '\|', 3; if ($f[0] -eq 'DEF') { $req[$f[1]] = $f[2] } }
    $op = if ($req['operation']) { $req['operation'] -replace '^STR:' } else { '' }
    if ($op -eq 'ADD_WARRIOR') {
        # recruit (callback WEGameMain 0x66a6f5a0): operationresult != 0, then the new warrior's fields + costs.
        $i = [int]$save['warriors~apd']; $id = $i + 1
        $w = [ordered]@{ instanceid = "DWD:$id"; warriorid = $req['warriorid']; nickname = $req['nickname']; level = $req['level']
            experience = 'DWD:0'; flag = $req['flag']; totalskillpoint = 'DWD:0'; normalskillpoint = 'DWD:0'; specialskillpoint = 'DWD:0' }
        foreach ($e in (GearKeys '' $req['warriorid']).GetEnumerator()) { $w[$e.Key] = $e.Value }
        $w['badge'] = '#STT:'
        $out.Add('DEF|operationresult|DWD:1')
        foreach ($k in $w.Keys) {
            if ($k.EndsWith('~apd')) { $out.Add("APD|$($k -replace '~apd$')|$($w[$k])") } else { $out.Add("DEF|$k|$($w[$k])") }
            $save["warriors[$i].$k"] = $w[$k]
        }
        $out.Add('DEF|gamemoneycost|DWD:0'); $out.Add('DEF|realmoneycost|DWD:0'); $out.Add('DEF|shownotice|DWD:0')
        $save['warriors~apd'] = "$($i + 1)"
        Log "DS ADD_WARRIOR -> instance $id ($($req['nickname']))"
    } elseif ($op -eq 'SELECT_WARRIOR') {
        $save['curselwarriorid'] = $req['instanceid']; $out.Add('DEF|operationresult|DWD:1')
        Log "DS SELECT_WARRIOR -> curselwarriorid $($req['instanceid'])"
    } elseif ($op -eq 'CHANGE_WARRIORNAME') {
        # callback WEGameMain 0x66a6cb20: operationresult, then instanceid + warriorname echoed (applied by the client)
        $out.Add('DEF|operationresult|DWD:1'); $out.Add("DEF|instanceid|$($req['instanceid'])"); $out.Add("DEF|warriorname|$($req['warriorname'])")
        foreach ($k in @($save.Keys)) {
            if ($k -match '^warriors\[(\d+)\]\.instanceid$' -and $save[$k] -eq $req['instanceid']) { $save["warriors[$($Matches[1])].nickname"] = $req['warriorname'] }
        }
        Log "DS CHANGE_WARRIORNAME -> $($req['instanceid']) = $($req['warriorname'])"
    } elseif ($op -eq 'SELECT_CAMPAIGN') {
        $save['curselcampaignname'] = $req['campaignname']; $out.Add('DEF|operationresult|DWD:1')
    } elseif ($op -eq 'CHANGE_CAMPAIGNRECORD') {
        $out.Add('DEF|operationresult|DWD:1')    # ponytail: not stored; campaignrecord_* are arrays in the save, format still unknown
        Log "DS CHANGE_CAMPAIGNRECORD -> $($req['area']) $($req['quest'])"
    } elseif ($op -eq 'ADD_MAXCHARACTER') {
        $save['maxcharacter'] = "DWD:$([int]($save['maxcharacter'] -replace 'DWD:') + 1)"; $out.Add('DEF|operationresult|DWD:1')
        Log "DS ADD_MAXCHARACTER -> $($save['maxcharacter'])"
    } elseif ($op -and $op -ne 'GET_NEWPRICE') {
        $out.Add('DEF|operationresult|DWD:1')                 # ponytail: blanket success for unknown operations; add real replies as they show up
        Log "DS operation $op not modelled, answered operationresult 1"
    }
    foreach ($l in $lines | Select-Object -Skip 1) {
        $f = $l -split '\|'
        $keys = @()
        if ($f[0] -eq 'QUE') { $keys = @($f[1]) }
        elseif ($f[0] -eq 'DEF' -and $f[1] -eq 'operation' -and $f[2] -eq 'STR:GET_NEWPRICE') { $keys = @('prices') }
        foreach ($k in $keys) {
            $hit = $false
            foreach ($e in $save.GetEnumerator()) {
                $name = $e.Key -replace '~apd$'
                if ($e.Key.EndsWith('~apd') -and ($name -eq $k -or $name.StartsWith("$k[") -or $name.StartsWith("$k#"))) {
                    $out.Add("APD|$name|$($e.Value)"); $hit = $true   # APD|array|n appends n elements (also nested: warriors[0].skill)
                }
                elseif ($e.Key -eq $k -or $e.Key.StartsWith("$k#") -or $e.Key.StartsWith("$k[")) { $out.Add("DEF|$($e.Key)|$($e.Value)"); $hit = $true }   # DEF = typed value (RED is a reference)
            }
            if (-not $hit) { Log "DS no data for key '$k'" }
        }
    }
    if ($op -and $op -ne 'GET_NEWPRICE') { SaveState }
    Log ("DS -> " + ($out -join ' / '))
    $raw = [Text.Encoding]::Unicode.GetPreamble() + [Text.Encoding]::Unicode.GetBytes(($out -join "`r`n") + "`r`n")
    return ,(Frame $peer 0xad (PspPack $raw))
}

# ---- Town server (UDP 8892, join session 19): raw binary messages, u16 id (0x300..0x30f), u16 total size, body ----
# Client handler: WEGameMain TownWork vtable 0x66b6fe8c, slot 2 (0x66a68070) dispatches received ids.
# 0x300 +4 u32 player id: "player entered"; for the client's own id it answers 0x301 (4 bytes, no body).
$accountId = 1
function TownMsg([uint16]$id, [byte[]]$body) {
    $m = New-Object byte[] (4 + $body.Length)
    [BitConverter]::GetBytes($id).CopyTo($m, 0); [BitConverter]::GetBytes([uint16]$m.Length).CopyTo($m, 2)
    $body.CopyTo($m, 4)
    Log ("TS -> 0x{0:x3} " -f $id + (($m | % { $_.ToString('x2') }) -join ' '))
    return ,$m
}
function TownReply($peer, [byte[]]$p) {
    Log ("TS <- 0x{0:x3} len {1}: {2}" -f (U16 $p 0), $p.Length, (($p | Select-Object -First 64 | % { $_.ToString('x2') }) -join ' '))
    if ((U16 $p 0) -eq 0x301) {
        # 0x302 (handler 0x66a6818e) only spawns players found in the client's cache of *other* users (GameMain+0x6dc),
        # so we use 0x303 (handler 0x66a6833c): +4 u32 player id, +8 u32 warrior instance id, +0x10..+0x1f position.
        # For a player not in the cache it builds the entry itself and calls the 3D lobby stage's spawn (vt+0x60).
        $out = @()
        foreach ($id in 12, 1) {
            $b = New-Object byte[] 0x1c
            [BitConverter]::GetBytes([uint32]$id).CopyTo($b, 0); $b[4] = 1
            $out += Frame $peer 0xad (TownMsg 0x303 $b)
        }
        return ,[byte[]]$out
    }
    return $null
}

function Reply($peer, [byte[]]$f) {
    if ($f.Length -lt 0x18 -or $f[0] -ne 2) { return $null }
    $payload = if ($f.Length -gt 0x18) { [byte[]]$f[0x18..($f.Length - 1)] } else { New-Object byte[] 0 }
    switch ($f[1]) {
        0x62 {  # connect request -> connect accept
            # the client's own session/conn ids are in the payload (+0x18/+0x1a); the header session field is the session it joins
            # Udp/Recv: UDP reliability state (Recv = next sequence number expected from the client)
            $peers[$peer] = @{ Secret = (U16 $f 4); Sess = (U16 $f 0x18); Conn = (U16 $f 0x1a); Udp = $peer.StartsWith('udp:'); Recv = (U16 $f 0x14) + 1 }   # the join itself is seq 0
            $p = New-Object byte[] 0x10
            $p[0] = 1; $p[2] = 1                            # our connection id / session (non-zero)
            if ($f.Length -ge 0x20) { [Array]::Copy($f, 0x1c, $p, 4, 4) }  # echo client tick
            return ,(Frame $peer 0x63 $p)
        }
        0xf1 { return ,(Frame $peer 0xf2 $payload) }      # ping -> pong, same body
        0x63 {  # client confirms the connection; the town server speaks first
            # the client compares the id with dword(PSUID+1) of its session: 12 (MSS session) or 1 (PSIP); a wrong one is ignored
            if ($peer.StartsWith('udp:8892>')) {
                return ,[byte[]]((Frame $peer 0xad (TownMsg 0x300 ([BitConverter]::GetBytes([uint32]12)))) + (Frame $peer 0xad (TownMsg 0x300 ([BitConverter]::GetBytes([uint32]1)))))
            }
        }
        0xad {
            if ($f[2] -ne 0) { Log "fragmented 0xad not supported yet"; return $null }
            $x = if ($peer.StartsWith('udp:8892>')) { TownReply $peer $payload }
                 elseif (IsPspZ $payload) { DsReply $peer $payload } else { PsipReply $peer $payload }
            if ($null -ne $x) { return ,$x }
        }
    }
    return $null
}

# UDP packets are sequenced (must be acked) unless type 0x61/0x64/0xf3 or flag 0x80 (UDPConnection 0x41ad20).
function IsSequenced([byte[]]$f) { -not ($f[1] -in 0x61, 0x64, 0xf3 -or ((U16 $f 0xa) -band 0x80)) }
$quiet = 0xf1, 0xf2, 0xf3          # not dumped (pings/acks)

function Handle($proto, $port, $peer, [byte[]]$f, $send) {
    $dup = $false
    $st = $peers[$peer]
    if ($st -and $st.Udp -and $f[1] -ne 0x62 -and (IsSequenced $f)) {
        $seq = U16 $f 0x14
        if ($seq -eq $st.Recv) { $st.Recv = ($seq + 1) % 0x10000 } elseif ($seq -lt $st.Recv) { $dup = $true }
    }
    if (-not $dup) {
        Log ("{0} {1} <- {2} type 0x{3:x2} size {4}" -f $proto, $port, $peer, $f[1], $f.Length)
        if ($f[1] -notin $quiet) { Dump $f }
    }
    $r = if ($dup) { $null } else { Reply $peer $f }
    if ($null -ne $r) {
        Log ("{0} {1} -> {2} type 0x{3:x2} size {4}" -f $proto, $port, $peer, $r[1], $r.Length)
        if ($r[1] -notin $quiet) { Dump $r }
        & $send $r
    }
    $st = $peers[$peer]
    if ($st -and $st.Udp -and $null -eq $r -and $f[1] -ne 0xf3 -and (IsSequenced $f)) {
        # bare ack (0xf3): +0x10 = 1 like the client's own acks, +0x16 = next expected seq, 4 zero bytes
        $a = Frame $peer 0xf3 (New-Object byte[] 4)
        $a[0x10] = 1
        & $send $a
    }
}

$lo = [Net.IPAddress]::Loopback
$tcp = foreach ($p in 7788, 8088, 8888, 23, 8080) {
    $l = New-Object Net.Sockets.TcpListener($lo, $p); $l.Start()
    [pscustomobject]@{ P = $p; L = $l }
}
$udp = foreach ($p in 8899, 9999, 8892) {
    $uc = New-Object Net.Sockets.UdpClient((New-Object Net.IPEndPoint($lo, $p)))
    [void]$uc.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null)   # SIO_UDP_CONNRESET off: ignore ICMP port-unreachable
    [pscustomobject]@{ P = $p; U = $uc }
}
Log "stub v56 up: TCP 7788 8088 8888 23 + HTTP 8080, UDP 8899 9999 8892 (log: $log)"

$conns = New-Object System.Collections.ArrayList
while ($true) {
    foreach ($t in $tcp) {
        while ($t.L.Pending()) {
            $c = $t.L.AcceptTcpClient()
            $c.NoDelay = $true
            [void]$conns.Add([pscustomobject]@{ P = $t.P; C = $c; S = $c.GetStream(); R = "$($c.Client.RemoteEndPoint)"; B = (New-Object System.Collections.Generic.List[byte]) })
            Log "TCP $($t.P) accept from $($c.Client.RemoteEndPoint)"
        }
    }
    foreach ($k in @($conns)) {
        try {
            if ($k.P -eq 8080 -and $k.C.Available -gt 0) {   # plain HTTP: log the request, answer 404
                $buf = New-Object byte[] $k.C.Available
                $n = $k.S.Read($buf, 0, $buf.Length)
                Log ("HTTP 8080 <- {0}`n{1}" -f $k.R, [Text.Encoding]::ASCII.GetString($buf, 0, $n))
                $resp = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
                $k.S.Write($resp, 0, $resp.Length); $k.C.Close(); $conns.Remove($k); continue
            }
            if ($k.C.Available -gt 0) {
                $buf = New-Object byte[] $k.C.Available
                $n = $k.S.Read($buf, 0, $buf.Length)
                $k.B.AddRange([byte[]]$buf[0..($n - 1)])
                # split the TCP stream into frames using the size field at +0x12
                while ($k.B.Count -ge 0x14) {
                    $size = [BitConverter]::ToUInt16($k.B.GetRange(0x12, 2).ToArray(), 0)
                    if ($size -lt 0x18) { Log "TCP $($k.P) bad frame size $size, dumping buffer"; Dump $k.B.ToArray(); $k.B.Clear(); break }
                    if ($k.B.Count -lt $size) { break }
                    $f = $k.B.GetRange(0, $size).ToArray(); $k.B.RemoveRange(0, $size)
                    $s = $k.S
                    Handle 'TCP' $k.P $k.R $f { param($r)
                        # one Write per frame (replies may hold several concatenated frames)
                        for ($o = 0; $o -lt $r.Length) { $sz = [BitConverter]::ToUInt16($r, $o + 0x12); $s.Write($r, $o, $sz); $s.Flush(); $o += $sz }
                    }
                }
            } elseif ($k.C.Client.Poll(0, 'SelectRead')) {
                Log "TCP $($k.P) closed by $($k.R)"
                $k.C.Close(); $conns.Remove($k)
            }
        } catch { Log "TCP $($k.P) error: $_"; $conns.Remove($k) }
    }
    foreach ($u in $udp) {
        while ($u.U.Available -gt 0) {
            $ep = New-Object Net.IPEndPoint($lo, 0)
            try { $b = $u.U.Receive([ref]$ep) } catch { Log "UDP $($u.P) error: $_"; break }
            $uc = $u.U; $dst = $ep
            # key = server port + client endpoint: the client talks to 8899 and 8892 from the same socket
            Handle 'UDP' $u.P "udp:$($u.P)>$ep" $b { param($r)   # one datagram per frame
                for ($o = 0; $o -lt $r.Length) { $sz = [BitConverter]::ToUInt16($r, $o + 0x12); [void]$uc.Send([byte[]]$r[$o..($o + $sz - 1)], $sz, $dst); $o += $sz }
            }
        }
    }
    Start-Sleep -Milliseconds 20
}
