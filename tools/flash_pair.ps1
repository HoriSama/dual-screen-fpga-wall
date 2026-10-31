# =============================================================================
# flash_pair.ps1 -- program both wall nodes over JTAG and PROVE which board got
# which bitstream, without looking at the screens.
#
#   powershell -ExecutionPolicy Bypass -File tools\flash_pair.ps1
#   powershell -ExecutionPolicy Bypass -File tools\flash_pair.ps1 -VerifyOnly
#   powershell -ExecutionPolicy Bypass -File tools\flash_pair.ps1 -CableA 0 -CableB 1
#
# Why this exists: TD's `download -cable N` numbering follows USB enumeration,
# so "0 = A" is NOT guaranteed across replugs -- and two `download` commands in
# ONE TD invocation both go to the first cable (learned the hard way: both
# boards ended up as node B, link down).
#
# So: one TD invocation per board, then read each board's 115200 status frame
# ("WL" + node byte) and report which physical board carries A and B.  The A
# board is the one with the TF card, i.e. the one whose loader reports a phase
# or bank_ok -- the script calls that out explicitly.
# =============================================================================
param(
    [string]$ABit = "C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall/build/td_A/WALL_A.bit",
    [string]$BBit = "C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall/build/td_B/WALL_B.bit",
    [int]$CableA = 0,
    [int]$CableB = 1,
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Continue"
$td = "D:/TD6.2/bin/run.exe"

function FlashOne([string]$bit, [int]$cable) {
    if (-not (Test-Path $bit)) { Write-Host "MISSING bit: $bit"; return $false }
    $tcl = "if {[catch {download -bit $bit -cable $cable} r]} { puts {FLASH_FAIL} } else { puts {FLASH_OK} }`r`nexit"
    $f = Join-Path $env:TEMP "flash_one.tcl"
    $tcl | Out-File -Encoding ascii $f
    $log = Join-Path $env:TEMP "flash_one.log"
    cmd /c "`"$td`" `"$f`" > `"$log`" 2>&1" | Out-Null
    $ok = (Get-Content $log | Select-String -Pattern "FLASH_OK").Count -gt 0
    Write-Host ("  {0,-14} -> cable {1} : {2}" -f (Split-Path $bit -Leaf), $cable, $(if ($ok) { "OK" } else { "FAILED (see $log)" }))
    return $ok
}

# ---- read one status frame from a COM port ---------------------------------
function ReadNode([string]$port) {
    try {
        $sp = New-Object System.IO.Ports.SerialPort $port, 115200, 'None', 8, 'One'
        $sp.ReadTimeout = 600
        $sp.Open()
        Start-Sleep -Milliseconds 150
        $sp.DiscardInBuffer()
        Start-Sleep -Milliseconds 900
        $n = $sp.BytesToRead
        $buf = New-Object byte[] $n
        if ($n -gt 0) { [void]$sp.Read($buf, 0, $n) }
        $sp.Close()
        for ($i = 0; $i -lt ($buf.Count - 33); $i++) {
            if ($buf[$i] -eq 0x57 -and $buf[$i+1] -eq 0x4C -and $buf[$i+31] -eq 0x5A) {
                $b = $buf[$i..($i+33)]
                $fl = $b[3]
                return [pscustomobject]@{
                    Port    = $port
                    Node    = [char]$b[2]
                    Link    = ($fl -band 1)
                    Sync    = (($fl -shr 1) -band 1)
                    SdFlags = $b[12]
                    Phase   = $b[20]
                    SdErr   = $b[23]
                }
            }
        }
        return [pscustomobject]@{ Port = $port; Node = '?'; Link = 0; Sync = 0; SdFlags = 0; Phase = 0; SdErr = 0 }
    } catch {
        return [pscustomobject]@{ Port = $port; Node = '!'; Link = 0; Sync = 0; SdFlags = 0; Phase = 0; SdErr = 0 }
    }
}

if (-not $VerifyOnly) {
    Write-Host "== programming (one TD invocation per board)"
    $okA = FlashOne $ABit $CableA
    $okB = FlashOne $BBit $CableB
    Start-Sleep -Seconds 3
    if (-not ($okA -and $okB)) { Write-Host "== at least one download FAILED" }
}

Write-Host "== reading the status UART of every board"
$ports = [System.IO.Ports.SerialPort]::GetPortNames()
$nodes = @()
foreach ($p in $ports) {
    $r = ReadNode $p
    if ($r.Node -eq 'A' -or $r.Node -eq 'B') { $nodes += $r }
}

foreach ($r in $nodes) {
    $card = if ($r.Phase -ne 0 -or $r.SdFlags -ne 0) { "  (has the TF card)" } else { "" }
    Write-Host ("  {0} node={1} link={2} sync={3} sd_flags={4:X2} phase={5} err={6}{7}" -f
        $r.Port, $r.Node, $r.Link, $r.Sync, $r.SdFlags, $r.Phase, $r.SdErr, $card)
}

# ---- verdict ---------------------------------------------------------------
$nA = @($nodes | Where-Object { $_.Node -eq 'A' }).Count
$nB = @($nodes | Where-Object { $_.Node -eq 'B' }).Count
$cardNode = @($nodes | Where-Object { $_.Phase -ne 0 -or $_.SdFlags -ne 0 } | Select-Object -First 1)

if ($nodes.Count -lt 2) {
    Write-Host "== WARNING: only $($nodes.Count) board(s) answered -- check the USB cables"
} elseif ($nA -eq 2 -or $nB -eq 2) {
    Write-Host "== FAIL: both boards are node $($nodes[0].Node) -- a download went to the same cable twice"
} elseif ($cardNode -and $cardNode.Node -ne 'A') {
    Write-Host "== FAIL: the board with the TF card is running node $($cardNode.Node); A must be the card board"
    Write-Host "   fix: -CableA $CableB -CableB $CableA   (the two JTAG cables are numbered the other way round)"
} else {
    Write-Host "== OK: one board is A (card side) and the other B, link and genlock up"
}
