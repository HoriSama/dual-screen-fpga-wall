# Decode the wall status frames on every COM port (debug helper).
#   powershell -ExecutionPolicy Bypass -File tools\status_all.ps1
$ErrorActionPreference = "Continue"

function ReadFrame([string]$port) {
    try {
        $sp = New-Object System.IO.Ports.SerialPort $port, 115200, 'None', 8, 'One'
        $sp.ReadTimeout = 600
        $sp.Open(); Start-Sleep -Milliseconds 150; $sp.DiscardInBuffer()
        Start-Sleep -Milliseconds 900
        $n = $sp.BytesToRead
        $buf = New-Object byte[] $n
        if ($n -gt 0) { [void]$sp.Read($buf, 0, $n) }
        $sp.Close()
        for ($i = 0; $i -lt ($buf.Count - 33); $i++) {
            if ($buf[$i] -eq 0x57 -and $buf[$i+1] -eq 0x4C -and $buf[$i+31] -eq 0x5A) {
                $b = $buf[$i..($i+33)]
                return [pscustomobject]@{
                    Port = $port; Node = [char]$b[2]
                    Link = ($b[3] -band 1); Sync = (($b[3] -shr 1) -band 1); Frozen = (($b[3] -shr 2) -band 1)
                    Sel = $b[4]; Gx = ("{0:X3}" -f (($b[5] -shl 8) -bor $b[6]))
                    Ok = ("{0:X4}" -f (($b[7] -shl 8) -bor $b[8])); Er = ("{0:X4}" -f (($b[9] -shl 8) -bor $b[10]))
                    B11 = $b[11]; SdFlags = $b[12]; Video = $b[13]
                    ImgChk = $b[19]; Phase = $b[20]
                    ErLo = $b[28]; ErHi = $b[29]; Phase29CarCyc = ($b[29] -band 3)
                    SdErr = $b[23]; W = (($b[24] -shl 8) -bor $b[25]); H = (($b[26] -shl 8) -bor $b[27])
                }
            }
        }
    } catch { }
    return $null
}

foreach ($p in [System.IO.Ports.SerialPort]::GetPortNames()) {
    $f = ReadFrame $p
    if ($f) {
        "{0} node={1} link={2} sync={3} frozen={4} sel={5} gx={6} w={7} h={8}" -f `
            $f.Port, $f.Node, $f.Link, $f.Sync, $f.Frozen, $f.Sel, $f.Gx, $f.W, $f.H
        "     ok={0} er={1} sd_flags={2:X2} phase={3} sd_err={4} video={5:X2} imgchk={6} b11={7} car_cyc={8} sdram_err_lo={9:X2}" -f `
            $f.Ok, $f.Er, $f.SdFlags, $f.Phase, $f.SdErr, $f.Video, $f.ImgChk, $f.B11, $f.Phase29CarCyc, $f.ErLo
    }
}
