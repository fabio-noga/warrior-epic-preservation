# Starts one game instance from C:\WE, records its pid in out\<role>.pid and injects wehost.dll (if built).
# The pid file is written before the injection: the DLL reads out\server.pid at load to pick its role.
# DebugConfig.cfg has "multishell true", which lets a second shell start (else the PS_WE_ mutex stops it).
param([ValidateSet('server', 'client')][string]$Role)
$p = Start-Process -FilePath 'C:\WE\WEShell_TGI.exe' -WorkingDirectory 'C:\WE' -PassThru
"$($p.Id)" | Set-Content (Join-Path $PSScriptRoot "out\$Role.pid")
"$(Get-Date -f HH:mm:ss) $Role started, pid $($p.Id)" | Out-File (Join-Path $PSScriptRoot 'out\launch.txt') -Append
if (Test-Path (Join-Path $PSScriptRoot 'wehost.dll')) {
    # LoadLibraryW must be resolved in a 32-bit PowerShell to match the game's kernel32 mapping
    Start-Process "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Minimized -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'inject.ps1'), '-ProcId', $p.Id)
}
