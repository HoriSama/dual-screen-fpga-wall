# =============================================================================
# dump_root.ps1 -- collect the 512-byte root-directory dump that the board
# streams one byte per status frame (byte 11, index in bytes 24/25).
#
# Usage:  .\dump_root.ps1 -Port COM7 -Seconds 70
#
# 512 frames at 100 ms = ~52 s, so give it a bit more.  The result is printed as
# FAT32 directory entries: name, attribute, first cluster and size, which is
# exactly what wall_tf_load's scan sees.
# =============================================================================
param(
    [string]$Port = 'COM7',
    [int]$Seconds = 70,
    [string]$Out = ''
)

$ErrorActionPreference = 'Stop'
$bytes = New-Object byte[] 512
$seen  = New-Object bool[] 512

$sp = New-Object System.IO.Ports.SerialPort($Port, 115200,
        [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 300
$sp.Open()

$deadline = (Get-Date).AddSeconds($Seconds)
$buf = New-Object System.Collections.Generic.List[byte]
$frames = 0
try {
    while ((Get-Date) -lt $deadline -and -not ($seen -notcontains $false)) {
        try { $b = $sp.ReadByte() } catch { continue }
        $buf.Add([byte]$b)
        # look for the frame: 'W' 'L' 'A'|'B' ... 34 bytes, ends with 0x0D 0x0A
        while ($buf.Count -ge 34) {
            if ($buf[0] -eq 0x57 -and $buf[1] -eq 0x4C -and ($buf[2] -eq 0x41 -or $buf[2] -eq 0x42)) {
                if ($buf[32] -eq 0x0D -and $buf[33] -eq 0x0A) {
                    $f = $buf.GetRange(0, 34).ToArray()
                    $idx = $f[24] -bor (($f[25] -band 1) -shl 8)
                    if ($idx -lt 512) {
                        $bytes[$idx] = $f[11]
                        $seen[$idx] = $true
                        $frames++
                    }
                    $buf.RemoveRange(0, 34)
                } else { $buf.RemoveAt(0) }
            } else { $buf.RemoveAt(0) }
        }
    }
} finally { $sp.Close() }

$got = ($seen | Where-Object { $_ }).Count
Write-Host "collected $got / 512 bytes ($frames frames)"

if ($Out) {
    [System.IO.File]::WriteAllBytes($Out, $bytes)
    Write-Host "raw bytes -> $Out"
}

# pretty-print as FAT32 short entries
Write-Host ""
Write-Host ("{0,-3} {1,-14} {2,-6} {3,-12} {4,10}  {5}" -f '#', 'name', 'attr', 'first clu', 'size', 'note')
for ($i = 0; $i -lt 16; $i++) {
    $o = $i * 32
    $e = $bytes[$o..($o + 31)]
    if ($e[0] -eq 0x00) { Write-Host ("{0,-3} <end of directory>" -f $i); break }
    if ($e[0] -eq 0xE5) { Write-Host ("{0,-3} <deleted>" -f $i); continue }
    $name = ([System.Text.Encoding]::ASCII.GetString($e, 0, 8)).TrimEnd() + '.' +
            ([System.Text.Encoding]::ASCII.GetString($e, 8, 3)).TrimEnd()
    $attr = $e[11]
    $clu  = ([int]$e[26] -bor ([int]$e[27] -shl 8) -bor ([int]$e[20] -shl 16) -bor ([int]$e[21] -shl 24))
    $size = [System.BitConverter]::ToUInt32($e, 28)
    $note = ''
    if (($attr -band 0x3F) -eq 0x0F) { $note = 'VFAT long-name entry (skipped)' }
    elseif ($attr -band 0x10)        { $note = 'directory (skipped)' }
    elseif ($attr -band 0x08)        { $note = 'volume label (skipped)' }
    elseif (($attr -band 0x3F) -ne 0x00 -and ($attr -band 0x20) -eq 0) { $note = 'attr=' + $attr }
    Write-Host ("{0,-3} {1,-14} 0x{2:X2}   {3,-12} {4,10}  {5}" -f $i, $name, $attr, $clu, $size, $note)
}
