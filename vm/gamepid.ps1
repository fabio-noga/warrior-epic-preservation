# Dot-sourced by the sandbox scripts. Two game instances run: the dedicated server (out\server.pid, minimized in the
# hall, hosts WEServerWorld via wehost.dll) and the client the player uses (out\client.pid). Scripts that click, patch,
# dump or trace "the game" mean the client.
function GameProcess([string]$Role = 'client') {
    $f = Join-Path $PSScriptRoot "out\$Role.pid"
    if (Test-Path $f) { return Get-Process -Id ([int](Get-Content $f)) -ErrorAction SilentlyContinue }
    Get-Process WEShell_TGI -ErrorAction SilentlyContinue | Select-Object -First 1   # single-instance runs
}
