# Screenshot of the sandbox desktop into out\ (used by auto.cmd).
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$b = [Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object Drawing.Bitmap $b.Width, $b.Height
[Drawing.Graphics]::FromImage($bmp).CopyFromScreen($b.Location, [Drawing.Point]::Empty, $b.Size)
$bmp.Save((Join-Path $PSScriptRoot ("out\screen_{0:HHmmss}.png" -f (Get-Date))))
