# =============================================================================
# build.ps1 -- build (and optionally flash) the two wall node bitstreams
#
#   powershell -ExecutionPolicy Bypass -File build.ps1
#   powershell -ExecutionPolicy Bypass -File build.ps1 -Role a -Flash
#
# Uses the plain TD command flow (run.exe + tcl), the same flow that already
# produced the murmur_d1 bitstreams on this machine.  Output goes to
# wall/build/td_<A|B>/ so everything stays inside the workspace.
# =============================================================================
param(
    [ValidateSet("a", "b", "both", "demo")] [string]$Role = "both",
    [switch]$Flash,      # configure the FPGA over JTAG (volatile: lost at power-off)
    [switch]$Persist,    # program the configuration flash (survives power-off)
    [switch]$AreaOnly,   # stop after optimize_gate and write per-module area.rpt (~2 min)
    # Which JTAG pod carries which node.  TD's `-cable N` follows USB enumeration,
    # so these swap whenever the pods are replugged (2026-10-30 they were A=1/B=0,
    # 2026-10-31 they are A=0/B=1).  Always confirm with
    #   powershell -File tools\flash_pair.ps1 -VerifyOnly     ("has the TF card" = A)
    # before using -Persist / -Flash: getting them backwards writes A's image to the
    # B board and both boxes come up as the same node.
    [int]$CableA = 0,
    [int]$CableB = 1
)

$ErrorActionPreference = "Continue"
$wall = "C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall"
$hdmi = "C:/Users/japsa/Documents/deepseek-harness/default-workspace/fpga_hdmi/build_src"
$td   = "D:/TD6.2/bin/run.exe"

$common = @(
    "$wall/rtl/sd/spi_master.v",
    "$wall/rtl/sd/sd_card_cmd.v",
    "$wall/rtl/sd/sd_card_sec_read_write.v",
    "$wall/rtl/sd/sd_card_top.v",
    "$wall/rtl/wall_img_rom.v",
    "$wall/rtl/wall_sd_dump.v",
    "$wall/rtl/wall_tf_load.v",
    "$wall/rtl/wall_zoom_calc.v",
    "$wall/rtl/wall_clock.v",
    "$wall/rtl/wall_carousel.v",
    "$wall/rtl/wall_picadj.v",
    "$wall/rtl/wall_img_push.v",
    "$wall/rtl/wall_img_recv.v",
    "$hdmi/src/framebuf/framebuffer_writer.v",
    "$hdmi/src/storage/m2_official_spi_master.v",
    "$hdmi/src/framebuf/p1_media_framebuffer_loader.v",
    "$hdmi/src/storage/m1a_protocol.vh",
    "$hdmi/src/storage/sd_spi.v",
    "$hdmi/src/storage/sd_reader.v",
    "$hdmi/src/storage/fat32_scan.v",
    "$hdmi/src/storage/m1a_fat32_catalog.v",
    "$hdmi/src/storage/m1a_catalog_table.v",
    "$hdmi/src/storage/bmp_parser.v",
    "$hdmi/src/storage/bmp_pixel_stream.v",
    "$hdmi/src/storage/fat32_file_reader.v",
    "$hdmi/src/storage/m2_tf_sector_provider.v",
    "$hdmi/src/storage/m2_real_media_service.v",    "$hdmi/src/vendor/anlogic/apug011/include/global_def.v",    "$wall/rtl/wall_font_rom.v",
    "$wall/rtl/wall_font_cn.v",
    "$wall/rtl/wall_marquee.v",
    "$wall/rtl/wall_raster.v",
    "$wall/rtl/wall_audio.v",
    "$wall/rtl/wall_music.v",
    "$wall/rtl/wall_scope.v",
    "$wall/rtl/wall_hud.v",
    "$wall/rtl/wall_scene.v",
    "$wall/rtl/wall_pic_line.v",
    "$wall/rtl/wall_pic_prefetch.v",
    "$wall/rtl/wall_state.v",
    "$wall/rtl/wall_input.v",
    "$wall/rtl/wall_album_seq.v",
    "$wall/rtl/wall_link.v",
    "$wall/rtl/wall_uart_tx.v",
    "$wall/rtl/wall_status_tx.v",
    "$wall/rtl/wall_hdmi_supervisor.v",
    "$wall/rtl/wall_autodrag.v",
    "$wall/rtl/wall_top.v",
    "$wall/rtl/wall_demo_a.v",
    "$wall/rtl/wall_sdram_test.v",
    "$hdmi/src/framebuf/sdram_arbiter.v",
    "$hdmi/src/framebuf/p1_sdram_cached_adapter.v",
    "$hdmi/src/top/apug011_core_wrapper.v",
    "$hdmi/src/vendor/anlogic/apug011/clk_pll.v",
    "$hdmi/src/vendor/anlogic/apug011/enc_file/sdr_as_ram.enc.v",
    "$hdmi/src/vendor/anlogic/apug011/enc_file/sdr_init_ref.enc.v",
    "$hdmi/src/vendor/anlogic/apug011/enc_file/sdr_wrrd.enc.v",
    "$hdmi/src/vendor/anlogic/apug092/hdmi_1_4b_transmitter_core_wrapper.enc.v",
    "$hdmi/src/vendor/anlogic/apug092/lane_lvds_10_1.v",
    "$hdmi/src/vendor/anlogic/apug092/hdmi_phy_warpper.v",
    "$hdmi/src/top/apug092_core_wrapper.v",
    "$hdmi/src/top/apug092_tx_wrapper.v",
    "$hdmi/src/top/p1_hdmi_pll_50m_25_125.v"
)

$targets = @()
if ($Role -eq "a" -or $Role -eq "both") { $targets += [pscustomobject]@{ Tag = "A"; Top = "wall_node_a"; Adc = "$wall/pin/wall_node_a.adc"; Sdc = "$wall/pin/wall_a.sdc"; Cable = $CableA } }
if ($Role -eq "b" -or $Role -eq "both") { $targets += [pscustomobject]@{ Tag = "B"; Top = "wall_node_b"; Adc = "$wall/pin/wall_node_b.adc"; Sdc = "$wall/pin/wall_b.sdc"; Cable = $CableB } }
# Cable numbers follow TODAY'S bench enumeration (cable 1 = the board with the TF card = A).
# They are USB-enumeration dependent: after replugging, verify with
#   powershell -ExecutionPolicy Bypass -File tools\flash_pair.ps1 -VerifyOnly
# which reports each board's node byte and which one holds the card.
if ($Role -eq "demo") { $targets += [pscustomobject]@{ Tag = "DEMO_A"; Top = "wall_demo_a"; Adc = "$wall/pin/wall_node_a.adc"; Sdc = "$wall/pin/wall_a.sdc"; Cable = 1 } }

foreach ($t in $targets) {
    $out = "$wall/build/td_$($t.Tag)"
    New-Item -ItemType Directory -Force $out | Out-Null
    $files = ($common -join " ")
    $lines = @(
        "cd $out"
        "import_device eagle_s20.db -package EG4S20BG256"
        "read_hdl -file {$files} -top $($t.Top)"
        "read_adc $($t.Adc)"
        "read_sdc $($t.Sdc)"
        "optimize_rtl"
        "optimize_gate"
        "report_area -file area.rpt"
    )
    if (-not $AreaOnly) {
        $lines += @(
        "legalize_phy_inst"
        "place"
        "phys_opt -effort high -post_place"
        "route"
        # NB: no `phys_opt -post_route` on this TD version -- 6.2.168116 crashes
        # (coredump) in its "Abnormal Timing Path check" stage.  The post-place
        # pass alone is enough: it moved the 150 MHz SDRAM domain from -0.170 ns
        # to +0.168 ns by replicating that fanout-40 control net.
        "update_timing -mode final"
        "report_timing_summary -file final_timing.rpt"
        "bitgen -bit WALL_$($t.Tag).bit"
        )
    }
    $lines += @(
        "puts {=== WALL BUILD DONE ===}"
        "exit"
    )
    $tcl = Join-Path $env:TEMP "build_wall_$($t.Tag).tcl"
    ($lines -join "`r`n") | Out-File -Encoding ascii $tcl
    Write-Host "== building node $($t.Tag) -> $out"
    $log = Join-Path $out "build.log"
    $bit = Join-Path $out "WALL_$($t.Tag).bit"
    # TD's Tcl eats backslashes as escapes: hand it forward slashes only.
    $bitTd = $bit.Replace('\', '/')
    $before = if (Test-Path $bit) { (Get-Item $bit).LastWriteTime } else { [datetime]::MinValue }
    # cmd redirection is required: PowerShell's *> does not capture run.exe output.
    cmd /c "`"$td`" `"$tcl`" > `"$log`" 2>&1" | Out-Null
    $errs = Get-Content $log | Select-String -Pattern "ERROR"
    if ($errs) {
        $errs | Select-Object -First 5 | ForEach-Object { "   $_" }
    }
    # ---- implicit-net check ------------------------------------------------
    # An undeclared name silently becomes a 1-bit wire: TD then ties the rest of
    # the port to 0 and the design still builds and flashes.  That is exactly how
    # both nodes once ran with a 1-bit-wide scene x (every pixel doubled, no HUD)
    # -- the log said `undeclared symbol 'x_scene'` and nobody looked.
    # `undeclared symbol` (HDL-1007) and `Undriven net` (SYN-5013) are fatal.
    # HDL-5314 ("net X does not have a driver") also fires for nets that only
    # exist on one node (e.g. remote_press on the slave), so it is only a note.
    $notefy = Get-Content $log | Select-String -Pattern "does not have a driver" |
              Where-Object { $_.Line -match "/wall/rtl/" }
    if ($notefy) { $notefy | Select-Object -First 4 | ForEach-Object { "   note: " + $_.Line.Trim() } }
    $hollow = Get-Content $log | Select-String -Pattern "undeclared symbol|Undriven net" |
              Where-Object { $_.Line -match "/wall/rtl/" }
    if ($hollow) {
        Write-Host "== CHECK FAILED: implicit/undriven nets in our RTL:"
        $hollow | Select-Object -First 8 | ForEach-Object { "   " + $_.Line.Trim() }
        $errs = $hollow
    } else {
        Write-Host "== implicit-net check: clean"
    }
    $fresh = (Test-Path $bit) -and ((Get-Item $bit).LastWriteTime -gt $before)
    if ($fresh -and -not $errs) {
        $size = (Get-Item $bit).Length
        Write-Host "== OK $bit ($size bytes)"
    } elseif (-not $fresh) {
        Write-Host "== FAILED: bitstream was not regenerated (see $log)"
    } else {
        Write-Host "== FAILED: TD reported errors (see $log)"
    }
    if ($Flash -and (Test-Path $bit)) {
        $fl = @(
            "if {[catch {download -bit $bitTd -cable $($t.Cable)} r]} { puts {FLASH FAIL} } else { puts {FLASH OK} }"
            "exit"
        ) -join "`r`n"
        $ff = Join-Path $env:TEMP "flash_wall_$($t.Tag).tcl"
        $fl | Out-File -Encoding ascii $ff
        $flog = Join-Path $out "flash.log"
        & $td $ff *> $flog
        Get-Content $flog | Select-String -Pattern "Chip validation|FLASH OK|FLASH FAIL" | Select-Object -Last 5 |
            ForEach-Object { "   $_" }
    }

    # ---- version snapshot --------------------------------------------------
    # Every build drops a self-contained copy under build/release/<stamp>_<tag>:
    # all RTL, pin constraints, testbenches, the generated TD flow script, the
    # bitstream and the timing/area reports.  That is what keeps an old version
    # reproducible after rtl/ has moved on.
    if (Test-Path $bit) {
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $rel = Join-Path (Join-Path $wall 'build') ("release\" + $stamp + "_" + $t.Tag)
        New-Item -ItemType Directory -Force $rel | Out-Null
        Copy-Item (Join-Path $wall 'rtl') (Join-Path $rel 'rtl') -Recurse -Force
        Copy-Item (Join-Path $wall 'pin') (Join-Path $rel 'pin') -Recurse -Force
        Copy-Item (Join-Path $wall 'tb')  (Join-Path $rel 'tb')  -Recurse -Force
        Copy-Item $tcl (Join-Path $rel ("flow_" + $t.Tag + ".tcl")) -Force
        Copy-Item $bit (Join-Path $rel ("WALL_" + $t.Tag + ".bit")) -Force
        foreach ($r in @('final_timing.rpt','gate.qor','place.qor','build.log')) {
            $src = Join-Path $out $r
            if (Test-Path $src) { Copy-Item $src $rel -Force }
        }
        Write-Host "== snapshot -> $rel"
    }

    # ---- write the bitstream into the board's configuration flash -----------
    # The board carries a W25Q16 (16 Mbit / 2 MB) on the FPGA config pins; the
    # bitstream is 629,632 B, so it sits at flash offset 0 and the FPGA boots it
    # with no JTAG attached.  Flow (TD 6.2 has no single command for this):
    #   svfgen -scan_mode prog_spi  -> SVF with embedded TDO compare
    #   program_svf -cable N        -> play it (erase + write + verify, ~92 s)
    #   svfgen -scan_mode refresh   -> reload the FPGA from flash right away
    # `download -mode program_spi` looks tempting but its wrapper tries to run a
    # Tcl command named program_spi, which does not exist in the CLI.
    if ($Persist -and (Test-Path $bit)) {
        $svf_p = (Join-Path $out "fpga_flash_prog.svf").Replace('\', '/')
        $svf_v = (Join-Path $out "fpga_flash_verify.svf").Replace('\', '/')
        $svf_r = (Join-Path $out "fpga_flash_refresh.svf").Replace('\', '/')
        $lines = @(
            "if {[catch {svfgen -chip EG4S20BG256 -scan_mode prog_spi -flash W25Q16JV -flashsize 16 -bit $bitTd -svf $svf_p} r]} { puts {SVFGEN-FAIL} } else { puts {SVFGEN-OK} }"
            "if {[catch {program_svf -cable $($t.Cable) -svf $svf_p} r]} { puts {PROG-FAIL} } else { puts {PROG-OK} }"
            "if {[catch {svfgen -chip EG4S20BG256 -scan_mode verify_spi -flash W25Q16JV -flashsize 16 -bit $bitTd -svf $svf_v} r]} { puts {VERGEN-FAIL} } else { puts {VERGEN-OK} }"
            "if {[catch {program_svf -cable $($t.Cable) -svf $svf_v} r]} { puts {VERIFY-FAIL} } else { puts {VERIFY-OK} }"
            "if {[catch {svfgen -chip EG4S20BG256 -scan_mode refresh -svf $svf_r} r]} { puts {REFGEN-FAIL} } else { puts {REFGEN-OK} }"
            "if {[catch {program_svf -cable $($t.Cable) -svf $svf_r} r]} { puts {REFRESH-FAIL} } else { puts {REFRESH-OK} }"
            "exit"
        ) -join "`r`n"
        $pf = Join-Path $env:TEMP "persist_wall_$($t.Tag).tcl"
        $lines | Out-File -Encoding ascii $pf
        $plog = Join-Path $out "flash_persist.log"
        cmd /c "`"$td`" `"$pf`" > `"$plog`" 2>&1" | Out-Null
        Write-Host "== programming configuration flash ($($t.Tag)) -- this takes ~2 min"
        Get-Content $plog | Select-String -Pattern "SVFGEN-|PROG-|VERGEN-|VERIFY-|REFGEN-|REFRESH-" |
            Select-Object -Last 8 | ForEach-Object { "   $_" }
    }
}