param([string]$Port = "COM7", [int]$Seconds = 3)
# Read the wall status frames and show the two repurposed counter bytes:
#   byte 11 (sd_sec)  = counter[7:0]
#   byte 19 (music)   = counter[15:8]
# On node A that counter is wall_img_push's "blocks sent since reset";
# on node B it is wall_img_recv's "blocks received since reset".
$sp = New-Object System.IO.Ports.SerialPort($Port, 115200,
          [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
$sp.ReadTimeout = 200
$ms = New-Object System.IO.MemoryStream
$sp.Open(); $sp.DiscardInBuffer()
$chunk = New-Object byte[] 4096
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
    try { $n = $sp.Read($chunk, 0, 4096); if ($n -gt 0) { $ms.Write($chunk, 0, $n) } } catch {}
}
$sp.Close()
$b = $ms.ToArray()
$i = 0; $frames = 0; $rows = @()
while ($i + 33 -lt $b.Length) {
    if ($b[$i] -eq 0x57 -and $b[$i+1] -eq 0x4C -and $b[$i+31] -eq 0x5A -and $b[$i+32] -eq 0x0D -and $b[$i+33] -eq 0x0A) {
        $f = $b[$i..($i+33)]
        $cnt = (([int]$f[19] -shl 8) -bor [int]$f[11])
        $fc  = (([int]$f[21] -shl 8) -bor [int]$f[22])
        $rows += ("blockcnt={0,5}  frame_cnt={1,5}  sdr=0x{2:X2}" -f $cnt, $fc, $f[30])
        $frames++
        $i += 34
    } else { $i++ }
}
$node = if ($frames -gt 0) { [char]$b[$i-34+2] } else { '?' }
Write-Output "=== $Port : $frames frames"
$rows | Select-Object -First 24 | ForEach-Object { "  $_" }
if ($rows.Count -ge 2) {
    Write-Output "  (first->last delta: $(([int]($rows[0] -split '=')[1].Split(' ')[0])) -> $(([int]($rows[-1] -split '=')[1].Split(' ')[0])))"
}
