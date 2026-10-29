#!/bin/sh
# Host-side helper: one automated sandbox run (Git Bash). Optional args = breakpoint addresses for bp.ps1.
# Waits for out/done.txt (max ~9 min), then prints the tracer log and the useful stub/trace lines.
cd "$(dirname "$0")/out" || exit 1
sed -i 's/\r*$/\r/' ../auto.cmd
rm -f done.txt screen_*.png click.txt bp.txt
[ $# -gt 0 ] && echo "$*" > bp_addrs.txt
cmd //c start "" "$(cygpath -w ../WarriorEpic_auto.wsb)"
# put the sandbox window where the user saved it (vm/sandbox_pos.json), only with two monitors connected
powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w ../sandbox_pos.ps1)" restore >/dev/null 2>&1 &
for i in $(seq 1 110); do [ -f done.txt ] && break; sleep 5; done
[ -f done.txt ] || echo "TIMEOUT: no done.txt"
cat click.txt bp.txt 2>/dev/null
n=$(grep -n "stub v.* up" stub.log | tail -1 | cut -d: -f1)
awk "NR>=$n" stub.log | grep -E "stub v|CS |TS |IS msg 0x0e to|server type|DS <- .*(ADD|SET|CRE)" | grep -v -E "0x800000|proto 7|proto 11|type 0x20 not" | tail -15
f=$(ls -t WE_new_files/Log/*Trace*.log | head -1)
iconv -f utf-16le -t utf-8 "$f" | tr -d '\r' | grep -v -E "Campaign|QuerySysInfo|Change Server|^\[[^]]*\]   " | awk '/QueryRoomList/{p=1} p' | head -25
ls screen_*.png 2>/dev/null
