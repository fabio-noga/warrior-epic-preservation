# Unattended login: type a / a into one game instance (by role, see gamepid.ps1) until the stub logs a new AS login.
# The server instance only has to sit in the hall (not minimized: its frame loop runs the game server).
param([ValidateSet('server', 'client')][string]$Role = 'client')
. (Join-Path $PSScriptRoot 'gamepid.ps1')
# Logged in = wehost.dll logged "hooked window" for this pid (it hooks only once WEHallUI is loaded, i.e. in the hall).
# Without the DLL, fall back to a new "AS login" line in the stub log. (Watching only stub lines written after this
# script started missed logins that happened first, and kept typing into a window already in the hall.)
function LoggedIn($p) {
    $hl = Join-Path $PSScriptRoot "out\host_$Role.log"
    if ($p -and (Test-Path $hl)) {
        $mine = $false
        # the DLL keeps the log open for writing: read with FileShare.ReadWrite (ReadAllLines fails)
        $fs = [IO.File]::Open($hl, 'Open', 'Read', 'ReadWrite'); $text = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
        foreach ($l in ($text -split "`n")) {
            if ($l -match 'wehost loaded into pid (\d+)') { $mine = ([int]$Matches[1] -eq $p.Id) }
            elseif ($mine -and $l -match 'hooked window') { return $true }
        }
        return $false
    }
    $fs = [IO.File]::Open($stubLog, 'Open', 'Read', 'ReadWrite'); $fs.Seek($start, 'Begin') | Out-Null
    $new = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
    return $new -match 'AS login'
}
$stubLog = Join-Path $PSScriptRoot 'out\stub.log'
$start = (Get-Item $stubLog -ErrorAction SilentlyContinue).Length
$w = New-Object -ComObject WScript.Shell
for ($i = 1; $i -le 10; $i++) {
    $p = GameProcess $Role
    if (LoggedIn $p) {
        # The server instance is NOT minimized: a minimized game stops its frame loop, and the hosted world runs on it
        # (seen: START never processed, then the instance crashed). It stays open until the console server replaces it.
        "$Role login done after $($i - 1) attempt(s)"; exit 0
    }
    if ($p -and $w.AppActivate($p.Id)) { Start-Sleep 1; $w.SendKeys('a{TAB}a{ENTER}'); "$Role attempt ${i}: typed" } else { "$Role attempt ${i}: window not found" }
    Start-Sleep 6
}
"$Role gave up"
