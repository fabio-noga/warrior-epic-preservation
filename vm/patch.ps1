# Applies the logged exe patches to the IN-VM copy C:\WE\WEShell_TGI.exe (never the original). See CHANGES.md.
# Each patch checks the original bytes first; already-patched bytes are left alone.
param([string]$Exe = 'C:\WE\WEShell_TGI.exe')
$ErrorActionPreference = 'Stop'
$patches = @(
    # P1: skip the Solid State Networks updater step: "call 0x4efbc0" at VA 0x4eff21 -> "mov eax,1"
    @{ Name = 'P1 skip updater'; Offset = 0xef321; Old = 'e89afcffff'; New = 'b801000000' }
)
$b = [IO.File]::ReadAllBytes($Exe)
foreach ($p in $patches) {
    $old = [byte[]]($p.Old -split '(..)' -ne '' | % { [Convert]::ToByte($_, 16) })
    $new = [byte[]]($p.New -split '(..)' -ne '' | % { [Convert]::ToByte($_, 16) })
    $cur = $b[$p.Offset..($p.Offset + $old.Length - 1)]
    if (-not (Compare-Object $cur $new -SyncWindow 0)) { "$($p.Name): already applied"; continue }
    if (Compare-Object $cur $old -SyncWindow 0) { throw "$($p.Name): unexpected bytes at 0x$('{0:x}' -f $p.Offset), not patching" }
    $new.CopyTo($b, $p.Offset); "$($p.Name): applied"
}
[IO.File]::WriteAllBytes($Exe, $b)
