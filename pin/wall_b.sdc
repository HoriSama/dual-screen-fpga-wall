# =============================================================================
# wall_b.sdc -- node B timing constraints
#
# Primary clocks:
#   clk      50 MHz board oscillator (HDMI PLL source; pixel 25 / serial 125
#            derived by TD from the EG_PHY_PLL instance)
#   link_clk forwarded 6.25 MHz nibble clock from node A
#
# The link domain and the pixel domain only exchange data through the
# double-buffered payload (toggle + stable payload) and the key/start toggles,
# so they are asynchronous to each other.
# =============================================================================
create_clock -name wall_clk50m  -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
create_clock -name wall_linkclk -period 160.000 -waveform {0.000 80.000} [get_ports {link_clk}]
derive_clocks

set_clock_groups -asynchronous \
    -group [get_clocks {wall_clk50m u_core/u_pll/u_pll.clkc[0]}] \
    -group [get_clocks {wall_linkclk}]

# Forwarded bundle from A: launched at A's falling edge, sampled 80 ns later.
set_max_delay 80.000 -from [get_ports {link_d[*] link_vld link_sync}]
# Return bundle to A: launched by this device, sampled mid-bit at A.
set_max_delay 80.000 -to   [get_ports {link_bd[*] link_bvld}]

set_false_path -from [get_ports {key_n[*]}]

# Asynchronous APUG092 reset release and EDID trigger (see wall_a.sdc).
set_false_path -from [get_clocks {wall_clk50m}] \
               -to   [get_clocks {u_core/u_pll/u_pll.clkc[1]}]

# The 50 MHz domain only meets the pixel domain through the reset release
# (asynchronous assert, two-flop synchronous release) and two-flop status
# synchronisers.  Nothing is a same-cycle data path.
set_false_path -from [get_clocks {wall_clk50m}] \
               -to   [get_clocks {u_core/u_pll/u_pll.clkc[0]}]
set_false_path -from [get_clocks {u_core/u_pll/u_pll.clkc[0]}] \
               -to   [get_clocks {wall_clk50m}]

# SDRAM 150 MHz domain: test results are captured once on a synchronised done
# edge; no same-cycle data path exists to the 50 MHz control domain.
set_false_path -from [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[1]}] -to [get_clocks {wall_clk50m}]
set_false_path -from [get_clocks {wall_clk50m}] -to [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[1]}]
# APUG011 hard-macro DQ half-cycle boundary.  Copied verbatim from the
# board-proven P1-05A / M2 constraint policy: TD models the fixed
# EG_PHY_SDRAM_2M_32 DQ boundary as ordinary 0deg/180deg register paths, which
# is not what the hard macro does.  These exceptions are deliberately limited to
# the two APUG011 phase-related PLL outputs; 150 MHz controller RTL stays timed.
set_false_path -from [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[2]}] -to [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[1]}]
set_false_path -from [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[1]}] -to [get_clocks {u_core/u_sdram_pll/pll_inst.clkc[2]}]