# =============================================================================
# persist_pair.ps1 -- write BOTH bitstreams into the boards' configuration flash
#                     (W25Q16) so the pair boots without JTAG.
#
#   powershell -ExecutionPolicy Bypass -File tools\persist_pair.ps1
#   powershell -ExecutionPolicy Bypass -File tools\persist_pair.ps1 -CableA 1 -CableB 0
#
# Why not just `build.ps1 -Persist`:
#   * that rebuilds first (~4 min) even when the .bit files are already current;
#   * TD's `-cable N` numbering follows USB enumeration, so it must be checked
#     against the bench, not assumed.
#
# Flow per board (TD 6.2 has no single command for this):
#   svfgen -scan_mode prog_spi  -> play with program_svf  (erase + write + TDO compare, ~92 s)
#   svfgen -scan_mode verify_spi-> play again             (read the flash back, ~60 s)
#   svfgen -scan_mode refresh   -> play                   (reload the FPGA from flash)
#
# The board is reconfigured while this runs, so its HDMI output drops and comes
# back, and the UART goes quiet for a few seconds.  Do not power-cycle mid-way:
# an interrupted erase leaves the flash without a valid image (JTAG still works,
# so re-running this recovers it).
# =============================================================================
param(
    [int]$CableA = 0,          # cable carrying node A (the board with the TF card)
    [int]$CableB = 1,
    [string]$BitA = "",
    [string]$BitB = "",
    [string]$Only = "both"     # both | a | b
)

$ErrorActionPreference = "Stop"
$wall = Split-Path $PSScriptRoot -Parent
$td   = "D:/TD6.2/bin/run.exe"
if (-not (Test-Path $td)) { Write-Host "== TD not found at $td"; exit 1 }

if (-not $BitA) { $BitA = Join-Path $wall "build/td_A/WALL_A.bit" }
if (-not $BitB) { $BitB = Join-Path $wall "build/td_B/WALL_B.bit" }

function PersistOne {
    param([string]$Tag, [string]$Bit, [int]$Cable)
    $bit = $Bit.Replace('\', '/')
    if (-not (Test-Path $Bit)) { Write-Host "   [$Tag] missing $Bit"; return $false }
    $out   = Split-Path $Bit -Parent
    $svfP  = (Join-Path $out "fpga_flash_prog.svf").Replace('\', '/')
    $svfV  = (Join-Path $out "fpga_flash_verify.svf").Replace('\', '/')
    $svfR  = (Join-Path $out "fpga_flash_refresh.svf").Replace('\', '/')
    $lines = @(
        "if {[catch {svfgen -chip EG4S20BG256 -scan_mode prog_spi  -flash W25Q16JV -flashsize 16 -bit $bit -svf $svfP} r]} { puts {SVFGEN-FAIL} } else { puts {SVFGEN-OK} }"
        "if {[catch {program_svf -cable $Cable -svf $svfP} r]} { puts {PROG-FAIL} } else { puts {PROG-OK} }"
        "if {[catch {svfgen -chip EG4S20BG256 -scan_mode verify_spi -flash W25Q16JV -flashsize 16 -bit $bit -svf $svfV} r]} { puts {VERGEN-FAIL} } else { puts {VERGEN-OK} }"
        "if {[catch {program_svf -cable $Cable -svf $svfV} r]} { puts {VERIFY-FAIL} } else { puts {VERIFY-OK} }"
        "if {[catch {svfgen -chip EG4S20BG256 -scan_mode refresh    -svf $svfR} r]} { puts {REFGEN-FAIL} } else { puts {REFGEN-OK} }"
        "if {[catch {program_svf -cable $Cable -svf $svfR} r]} { puts {REFRESH-FAIL} } else { puts {REFRESH-OK} }"
        "exit"
    ) -join "`r`n"
    $pf   = Join-Path $env:TEMP "persist_wall_$Tag.tcl"
    $plog = Join-Path $out "flash_persist.log"
    $lines | Out-File -Encoding ascii $pf
    Write-Host "== [$Tag] programming configuration flash on cable $Cable ... (~3 min, do not unplug)"
    cmd /c "`"$td`" `"$pf`" > `"$plog`" 2>&1" | Out-Null
    $marks = Get-Content $plog | Select-String -Pattern "SVFGEN-|PROG-|VERGEN-|VERIFY-|REFGEN-|REFRESH-"
    $marks | Select-Object -Last 8 | ForEach-Object { "   $($_.Line.Trim())" }
    $ok = (($marks | Select-String -Pattern "PROG-OK").Count -gt 0) -and
          (($marks | Select-String -Pattern "VERIFY-OK").Count -gt 0) -and
          (($marks | Select-String -Pattern "REFRESH-OK").Count -gt 0)
    if ($ok) { Write-Host "   [$Tag] flash OK (written, read-back verified, FPGA reloaded)" }
    else     { Write-Host "   [$Tag] FAILED -- see $plog" }
    return $ok
}

$doA = ($Only -eq "both" -or $Only -eq "a")
$doB = ($Only -eq "both" -or $Only -eq "b")
$okA = $true; $okB = $true

if ($doA) { $okA = PersistOne -Tag "A" -Bit $BitA -Cable $CableA }
if ($doB) { $okB = PersistOne -Tag "B" -Bit $BitB -Cable $CableB }

Start-Sleep -Seconds 6
Write-Host "== reading the pair back over UART"
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "probe_flash.ps1")

if (-not ($okA -and $okB)) { Write-Host "== at least one board FAILED"; exit 1 }
Write-Host "== both configuration flashes written and verified"
