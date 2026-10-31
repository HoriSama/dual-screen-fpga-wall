# =============================================================================
# wall_a.sdc -- node A timing constraints
#
# Only the 50 MHz board oscillator is a primary clock.  The HDMI PLL
# (25 MHz pixel / 125 MHz serial) is derived by TD from the instantiated
# EG_PHY_PLL, exactly as in the board-proven P1-05A / M2 builds.
#
# The peer->A bundle (link_bd, link_bvld) is launched by node B's forwarded
# link clock and is captured by A's pixel domain mid-bit, i.e. it is a
# bundled-data transfer, not a synchronous path.
# =============================================================================
create_clock -name wall_clk50m -period 20.000 -waveform {0.000 10.000} [get_ports {clk}]
derive_clocks

set_max_delay 60.000 -from [get_ports {link_bd[*] link_bvld}]
set_max_delay 60.000 -to   [get_ports {link_clk link_sync link_vld link_d[*]}]

# Keys are asynchronous mechanical inputs; the long debounce counter is the
# only consumer, so nothing here needs a setup relationship.
set_false_path -from [get_ports {key_n[*]}]

# The only 50 MHz -> 125 MHz crossings are the APUG092 asynchronous reset
# release (recovery/removal) and the one-shot EDID trigger.  Both are
# asynchronous requests by construction; the vendor transmitter core samples
# them as such.  This mirrors the board-proven P1-05A/M2 constraint policy.
set_false_path -from [get_clocks {wall_clk50m}] \
               -to   [get_clocks {u_core/u_pll/u_pll.clkc[1]}]

# 50 MHz <-> pixel: reset release plus two-flop status synchronisers only.
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