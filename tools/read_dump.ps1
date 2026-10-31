# Read the sector-0 dump that wall_sd_dump streams on the node's UART pin.
#
#   powershell -ExecutionPolicy Bypass -File tools\read_dump.ps1              # all ports
#   powershell -ExecutionPolicy Bypass -File tools\read_dump.ps1 -Port COM6   # just node A
#   powershell -ExecutionPolicy Bypass -File tools\read_dump.ps1 -Seconds 4 -All
#
# Frame on the wire (115200 8N1), repeated every ~160 ms once a read completed:
#
#   'S' 'D' 0x80 0x00  | 128 bytes | ('W' 'L' ... 34-byte status frame interleaved)
#
# Frames 1..N are identical (the capture is latched once, then re-sent), so the
# default prints one frame and -All prints every distinct one.
#
# The payload is the card's LBA 0 (the FAT32 boot sector / BPB) when the probe
# address is 32'd0, or the CID when SD_PROBE_ADDR is 32'hFFFF_FFFF.  Both are
# recognised below.  READ THE BYTES, never a decoded string: SerialPort
# .ReadExisting() maps every byte >= 0x80 to '?' (see docs/02_bringup_log.md 16).
param(
    [string]$Port = '',
    [int]$Seconds = 2,
    [switch]$All
)

if (-not $Port) {
    $Ports = [System.IO.Ports.SerialPort]::GetPortNames() | Sort-Object
} else {
    $Ports = @($Port)
}
if (-not $Ports) { Write-Host "no serial ports found"; exit 1 }

function Show-Hex {
    param([byte[]]$p, [int]$n)
    for ($i = 0; $i -lt $n; $i += 16) {
        $row = $p[$i..([Math]::Min($i + 15, $n - 1))]
        $hex = ($row | ForEach-Object { $_.ToString('X2') }) -join ' '
        $asc = -join ($row | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
        "  {0:X3}  {1,-47}  |{2}|" -f $i, $hex, $asc
    }
}

function Decode-Payload {
    param([byte[]]$p)
    $nz = ($p | Where-Object { $_ -ne 0 }).Count
    "  nonzero bytes: $nz / 128"
    if ($nz -eq 0) {
        "  -> all 0x00.  The card answered the read (sd_vcnt=0xFF, read_end=1) but every"
        "     byte of this block is zero: unformatted / never-written card.  The byte path"
        "     itself is proven good by the CID probe (docs/02_bringup_log.md 19)."
        return
    }
    # FAT/NTFS/exFAT boot sector?
    if ($p[0] -eq 0xEB -or $p[0] -eq 0xE9) {
        $bps  = ([int]$p[11] -shl 8) -bor [int]$p[12]
        $spc  = $p[13]
        $rsv  = ([int]$p[14] -shl 8) -bor [int]$p[15]
        $nfat = $p[16]
        $root = ([int]$p[17] -shl 8) -bor [int]$p[18]
        $fatsz = ([int]$p[36] -shl 24) -bor ([int]$p[37] -shl 16) -bor ([int]$p[38] -shl 8) -bor [int]$p[39]
        $rootc = ([int]$p[44] -shl 24) -bor ([int]$p[45] -shl 16) -bor ([int]$p[46] -shl 8) -bor [int]$p[47]
        "  -> boot sector.  OEM=[" + (-join ($p[3..10] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })) + "]"
        "     bytes/sector=$bps sectors/cluster=$spc reserved=$rsv nfats=$nfat fat32_size=$fatsz"
        "     FAT32 root_cluster=$rootc   (fat32 if fat32_size != 0; FAT16 root_entries=$root)"
        if ($fatsz -ne 0) { "     => FAT32, ready for the W2 loader" }
        elseif ($root -ne 0) { "     => FAT12/16, the loader wants FAT32" }
        else { "     => neither FAT32 nor FAT16 signature here - check for exFAT/NTFS" }
        return
    }
    # CID layout (16 bytes): MID, OID(2), PNM(5 ASCII), PRV, PSN(4), MDT(2), CRC7
    $pnm = -join ($p[3..7] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    $oid = -join ($p[1..2] | ForEach-Object { if ($_ -ge 32 -and $_ -lt 127) { [char]$_ } else { '.' } })
    "  -> looks like a CID (probe address 32'hFFFF_FFFF):"
    "     MID=0x{0:X2} OID=[{1}] PNM=[{2}] PRV={3}.{4} PSN=0x{5:X8}" -f `
        $p[0], $oid, $pnm, ($p[8] -shr 4), ($p[8] -band 0xF), `
        (([int]$p[9] -shl 24) -bor ([int]$p[10] -shl 16) -bor ([int]$p[11] -shl 8) -bor [int]$p[12])
    "     data CRC (bytes 16..17): {0:X2} {1:X2}   (CRC-16/XMODEM over bytes 0..15)" -f $p[16], $p[17]
}

foreach ($p in $Ports) {
    $sp = New-Object System.IO.Ports.SerialPort($p, 115200,
              [System.IO.Ports.Parity]::None, 8, [System.IO.Ports.StopBits]::One)
    $sp.ReadTimeout = 200
    $ms = New-Object System.IO.MemoryStream
    try {
        $sp.Open()
        $sp.DiscardInBuffer()
        $chunk = New-Object byte[] 4096
        $deadline = (Get-Date).AddSeconds($Seconds)
        while ((Get-Date) -lt $deadline) {
            try { $n = $sp.Read($chunk, 0, 4096); if ($n -gt 0) { $ms.Write($chunk, 0, $n) } } catch {}
        }
    } catch {
        Write-Host "=== $p : cannot open ($($_.Exception.Message))"
        continue
    } finally { $sp.Close() }

    $b = $ms.ToArray()
    Write-Host "=== $p : captured $($b.Length) bytes"
    $seen = @{}
    $shown = 0
    for ($i = 0; $i -lt $b.Length - 131; $i++) {
        if ($b[$i] -eq 0x53 -and $b[$i + 1] -eq 0x44 -and $b[$i + 2] -eq 0x80 -and $b[$i + 3] -eq 0x00) {
            $pay = [byte[]]$b[($i + 4)..($i + 131)]
            $key = ($pay | ForEach-Object { $_.ToString('X2') }) -join ''
            if ($seen.ContainsKey($key) -and -not $All) { continue }
            $seen[$key] = $true
            $shown++
            Write-Host "--- dump frame #$shown at byte offset $i"
            Show-Hex $pay 128
            Decode-Payload $pay
            $i += 131
            if (-not $All -and $shown -ge 1) { break }
        }
    }
    if ($shown -eq 0) {
        "  no dump frame (53 44 80 00 ...) in $($b.Length) bytes."
        "  Either the probe has not completed a read (check tools\read_status.ps1:"
        "  sd state=3, bytes=255, read_end=1) or this port belongs to the other node."
    }
}
