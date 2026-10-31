# Decode the wall node status UARTs (CH340, 115200 8N1, 34-byte frames).
#
#   powershell -ExecutionPolicy Bypass -File tools\read_status.ps1
#   powershell -ExecutionPolicy Bypass -File tools\read_status.ps1 -Seconds 3 -Ports COM6
#   powershell -ExecutionPolicy Bypass -File tools\read_status.ps1 -Raw         # hex dump
#   powershell -ExecutionPolicy Bypass -File tools\read_status.ps1 -Save ..\.tmp\raw-%port%.bin
#
# The byte map lives in rtl/wall_status_tx.v, next to the code that emits it.
# Capture always starts mid-stream, so the parser resynchronises on 'W','L' and
# only accepts a frame whose byte 31 is 'Z' and whose last two bytes are CR LF.
#
# READ THE BYTES, NEVER THE DECODED STRING: SerialPort.ReadExisting() decodes
# with SerialPort.Encoding (ASCII by default) and silently replaces every byte
# >= 0x80 with '?' (0x3F).  That single mistake made win_h=210 (0xD2) read back
# as 63 and sd_vcnt (0xFF) read back as 0x3F for a whole debugging round.
param(
    [int]$Seconds = 2,
    [string[]]$Ports = @(),
    [switch]$Raw,
    [string]$Save = ''
)

if (-not $Ports -or $Ports.Count -eq 0) {
    $Ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
}
if (-not $Ports) { Write-Host "no serial ports found"; exit 1 }

function Decode-Frame {
    param([byte[]]$f)
    # NOTE: PowerShell does not widen the left operand of -shl, so [byte]0x01
    # -shl 8 is 0.  Every multi-byte assembly below casts through [int].
    $u16 = { param($a) ([int]$f[$a] -shl 8) -bor [int]$f[$a + 1] }
    $node  = [char]$f[2]
    $flags = $f[3]
    $sel   = $f[4]
    $gx    = & $u16 5
    $ok    = & $u16 7
    $er    = & $u16 9
    $sdv   = $f[11]                     # TF loader: bytes of the sector in flight
    $sdfl  = $f[12]                     # {bank_ok, found}
    $sup   = ($f[13] -shr 4) -band 3
    $vl    = $f[13] -band 1
    $vr    = ($f[13] -shr 1) -band 1
    $rec   = $f[14]
    $pllc  = $f[15]
    $sgx   = & $u16 16
    $rstc  = $f[18]
    $sds   = $f[20] -band 0x0F         # TF loader phase
    $fcnt  = & $u16 21
    $b0    = $f[23]                     # TF loader error code
    $bank  = ($sdfl -shr 4) -band 0x0F
    $fnd   = $sdfl -band 0x0F
    $ww    = & $u16 24
    $wh    = & $u16 26
    $serr  = & $u16 28
    $sdr   = $f[30]
    $imgck = $f[19]
    $imgdn = ($f[30] -shr 2) -band 1
    $rawst = $f[20]
    $entc  = $f[11]
    $ent4  = [System.Text.Encoding]::ASCII.GetString($f[24..27])

    "  node={0} link={1} sync={2} frozen={3} drag={4} sel={5} gx=0x{6:X3} staged=0x{7:X3} win={8}x{9}" -f `
        $node, ($flags -band 1), (($flags -shr 1) -band 1), (($flags -shr 2) -band 1), (($flags -shr 3) -band 1), `
        $sel, $gx, $sgx, $ww, $wh
    "  link_frames_ok={0} link_frames_err={1} frame_cnt={2}" -f $ok, $er, $fcnt
    # C10-R1: bytes 15/18 now carry the wall clock (BCD), not the PLL/rest counters
    "  wallclock : TIME {0}{1}:{2}{3}   (byte15=0x{4:X2} byte18=0x{5:X2})" -f `
        (($pllc -shr 4) -band 15), ($pllc -band 15), `
        (($rstc -shr 4) -band 15), ($rstc -band 15), $pllc, $rstc
    "  video: locked={0} ready={1} sup_state={2} rec_cnt={3}" -f $vl, $vr, $sup, $rec
    "  sdram : done={0} failed={1} errors={2}" -f `
        ($sdr -band 1), (($sdr -shr 1) -band 1), $serr
    # byte 30: bit0 sdram_done, bit1 sdram_failed, bit2 img_chk_done,
    #          bit3 music_ok, bit4 found[4] (slot 4 seen), bit5 bank_ok[4]
    "  music : ok={0}  (byte19 moved to the album line below)  slot4: found={1} done={2}" -f `
        (($sdr -shr 3) -band 1), (($sdr -shr 4) -band 1), (($sdr -shr 5) -band 1)
    # C9/C9-R3: byte 19 = {1'b0, starved mask[3:0], album page[1:0], hi_ready}
    $mask = ($imgck -shr 3) -band 15
    $maskb = ([Convert]::ToString($mask, 2)).PadLeft(4, '0')
    "  album : page={0} (CAM{1})  hi_ready={2}  starved-mask={3} (w3..w0)  (byte19=0x{4:X2})" -f `
        (($imgck -shr 1) -band 3), ((($imgck -shr 1) -band 3) + 1), ($imgck -band 1), `
        $maskb, $imgck
    "  picture: (byte30 bit2 is always 0 since W3; picture RAM check removed)"
    # C9-R2/R3: byte 11 is the loader's sector-byte counter while loading and the
    # WORST frame's late-fill count over the last 4 s once phase == 6.
    "  linebuf: worst frame / 4 s = {0}   (0 = read port keeps up; see byte19 mask)" -f $entc
    "  tf    : phase={0}  raw_state={1}   entry#4 name='{2}'" -f $sds, $rawst, $ent4
    "          err={0}  found={1:x4}  bank_ok={2:x4}  sector_bytes={3}" -f $b0, $fnd, $bank, $sdv
}

foreach ($p in $Ports) {
    $ms = New-Object System.IO.MemoryStream
    $sp = New-Object System.IO.Ports.SerialPort($p, 115200,
              [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $sp.ReadTimeout = 200
    try {
        $sp.Open()
        $sp.DiscardInBuffer()
        $chunk = New-Object byte[] 1024
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try {
                $n = $sp.Read($chunk, 0, 1024)
                if ($n -gt 0) { $ms.Write($chunk, 0, $n) }
            } catch {}
        }
    } catch {
        Write-Host "=== $p : cannot open ($($_.Exception.Message))"
        continue
    } finally { $sp.Close() }

    $b = $ms.ToArray()
    if ($Save) {
        $file = $Save.Replace('%port%', $p)
        [System.IO.File]::WriteAllBytes($file, $b)
        Write-Host "  saved $($b.Length) bytes -> $file"
    }
    Write-Host "=== $p : $($b.Length) bytes"
    if ($Raw) {
        ($b | ForEach-Object { $_.ToString('X2') }) -join ' '
        continue
    }

    $frames = New-Object 'System.Collections.Generic.List[byte[]]'
    $i = 0
    while ($i + 33 -lt $b.Length) {
        if ($b[$i] -eq 0x57 -and $b[$i + 1] -eq 0x4C -and $b[$i + 31] -eq 0x5A `
                -and $b[$i + 32] -eq 0x0D -and $b[$i + 33] -eq 0x0A) {
            $frames.Add([byte[]]$b[$i..($i + 33)])
            $i += 34
        } else { $i++ }
    }
    if ($frames.Count -eq 0) {
        Write-Host "  (no valid frame in $($b.Length) bytes - rerun with -Raw)"
        continue
    }
    Write-Host "  ($($frames.Count) frames, showing the last one)"
    Decode-Frame $frames[$frames.Count - 1]
}
