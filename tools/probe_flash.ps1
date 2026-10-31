param([string]$Ports = 'COM7,COM8', [switch]$Flash)

$td = 'D:/TD6.2/bin/run.exe'
$aBit = 'C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall/build/td_A/WALL_A.bit'
$bBit = 'C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall/build/td_B/WALL_B.bit'

function Read-Frame([string]$port) {
    try {
        $sp = New-Object System.IO.Ports.SerialPort $port,115200,'None',8,'One'
        $sp.ReadTimeout = 900
        $sp.Open(); Start-Sleep -Milliseconds 150; $sp.DiscardInBuffer()
        Start-Sleep -Milliseconds 700
        $n = $sp.BytesToRead
        if ($n -le 0) { $sp.Close(); return $null }
        $buf = New-Object byte[] $n
        [void]$sp.Read($buf, 0, $n); $sp.Close()
        for ($i = 0; $i -lt ($buf.Count - 33); $i++) {
            if ($buf[$i] -eq 0x57 -and $buf[$i+1] -eq 0x4C -and $buf[$i+31] -eq 0x5A) {
                $b = $buf[($i)..($i+33)]
                return [pscustomobject]@{
                    Port = $port; Node = [char]$b[2]
                    Link = ($b[3] -band 1); Sync = (($b[3] -shr 1) -band 1)
                    Sel  = $b[4]
                    Gx   = (($b[5] -band 0x0F) -shl 8) -bor $b[6]
                    SdFlags = $b[12]; Phase = $b[20]
                    Frames = ([int]$b[21] -shl 8) -bor $b[22]
                    WinW = (($b[24] -band 0x03) -shl 8) -bor $b[25]
                    WinH = (($b[26] -band 0x03) -shl 8) -bor $b[27]
                }
            }
        }
    } catch { return $null }
    return $null
}

function Flash-One([string]$bit, [int]$cable) {
    $tcl = "if {[catch {download -bit $bit -cable $cable} r]} { puts {FLASH_FAIL} } else { puts {FLASH_OK} }`r`nexit"
    $f = Join-Path $env:TEMP "probe_flash.tcl"
    $tcl | Out-File -Encoding ascii $f
    $log = Join-Path $env:TEMP "probe_flash_$cable.log"
    cmd /c "`"$td`" `"$f`" > `"$log`" 2>&1" | Out-Null
    return ((Select-String -Path $log -Pattern 'FLASH_OK' -ErrorAction SilentlyContinue).Count -gt 0)
}

$list = $Ports.Split(',')
"=== BEFORE ==="
foreach ($p in $list) {
    $r = Read-Frame $p
    if ($r) { "  {0} node={1} link={2} sync={3} sd=0x{4:X2} phase={5} frames={6} gx=0x{7:X3} w={8} h={9}" -f $r.Port,$r.Node,$r.Link,$r.Sync,$r.SdFlags,$r.Phase,$r.Frames,$r.Gx,$r.WinW,$r.WinH }
    else    { "  $p : no frame" }
}

if ($Flash) {
    foreach ($cbl in 0,1) {
        $bit = if ($cbl -eq 0) { $aBit } else { $bBit }
        $ok = Flash-One $bit $cbl
        "=== cable $cbl <- $(Split-Path $bit -Leaf) : $(if($ok){'FLASH_OK'}else{'FLASH_FAIL'}) ==="
        Start-Sleep -Milliseconds 400
        foreach ($p in $list) {
            $r = Read-Frame $p
            if ($r) { "  {0} node={1} link={2} sd=0x{3:X2} phase={4} frames={5}" -f $r.Port,$r.Node,$r.Link,$r.SdFlags,$r.Phase,$r.Frames }
        }
    }
}
