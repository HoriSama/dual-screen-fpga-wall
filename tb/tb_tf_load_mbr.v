//=============================================================================
// tb_tf_load_mbr.v -- the same loader test, but the volume sits behind an MBR
// partition table starting at LBA 32, and LBA 0 has no boot code at all.
//
// That is the layout the real A-board card turned out to have
// (docs/02_bringup_log.md 20): every earlier round looked only at LBA 0 and
// concluded "blank card", when in fact LBA 0 was a partition table.
//
// Run from wall/:
//   vsim -c -do "run -all; quit -f" tb_tf_load_mbr
//=============================================================================
`timescale 1ns/1ps

module tb_tf_load_mbr;
    // 32 sector MBR stub + the 7258-sector volume (C9: four 640x480 BMPs)
    tb_tf_load #(.IMAGE("tb/fat32_mbr.hex"), .NSEC(8192)) u_tb ();
endmodule
