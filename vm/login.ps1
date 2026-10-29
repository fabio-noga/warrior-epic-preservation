# Unattended login for auto.cmd: type a / a into the shell until the stub logs the AS login (or give up).
$log = Join-Path $PSScriptRoot 'out\stub.log'
$start = (Get-Item $log -ErrorAction SilentlyContinue).Length
$w = New-Object -ComObject WScript.Shell
for ($i = 1; $i -le 8; $i++) {
    $fs = [IO.File]::Open($log, 'Open', 'Read', 'ReadWrite')
    $fs.Seek($start, 'Begin') | Out-Null
    $new = (New-Object IO.StreamReader($fs)).ReadToEnd(); $fs.Close()
    if ($new -match 'AS login') { "login done after $($i - 1) attempt(s)"; exit 0 }
    if ($w.AppActivate('WARRIOR EPIC')) { Start-Sleep 1; $w.SendKeys('a{TAB}a{ENTER}'); "attempt ${i}: typed" } else { "attempt ${i}: window not found" }
    Start-Sleep 6
}
'gave up'
