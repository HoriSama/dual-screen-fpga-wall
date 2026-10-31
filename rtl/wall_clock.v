//=============================================================================
// wall_clock.v -- wall clock shown in the HUD ("TIME mm ss")
//
// `tick` is one pulse per displayed frame (60 Hz), so 60 ticks = 1 s:
//   sec: 00..59, then wraps and carries into min
//   min: 00..99, then wraps to 00
//
// The counters are BCD ({tens, units} nibbles) on purpose: wall_hud feeds each
// nibble straight into hexch(), so a BINARY counter would read out as hex
// ("TIME 0C 22" instead of "TIME 12 34").  Kept in its own module so the carry
// chain can be simulated for a full 100-minute wrap (tb_clock) without pulling
// in the raster, the PLLs or the SDRAM.
//
// C10-R1: the next-state logic is COMBINATIONAL and each 8-bit counter gets ONE
// full-width non-blocking assignment.  The first version assigned the two BCD
// nibbles separately (sec[3:0] <= ... in one branch, sec[7:4] <= ... in another),
// which ModelSim handles fine and tb_clock passes, but on the board the display
// started at "40 40" -- the 4.7.x synthesiser merged the slices of the same
// register.  Whole-register assignments cannot be mis-partitioned like that.
//=============================================================================
`timescale 1ns/1ps

module wall_clock #(
    parameter integer FRAMES_PER_SEC = 60
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        tick,      // 1 = one displayed frame elapsed
    output reg  [7:0]  sec = 8'h00,   // BCD 00..59
    output reg  [7:0]  min = 8'h00    // BCD 00..99
);
    // Declaration initialisers, not just the reset: on this board the POR reset
    // does not reach these registers when the FPGA is reconfigured over JTAG, so
    // without an init value the counter starts from whatever the config left in
    // the flops (observed on 2026-10-31: the TIME line began at 41:28, which was
    // simply the board's uptime).  TD honours declaration initialisers -- it is
    // the same form wall_top already uses for its nibble counter.
    reg [5:0] fdiv = 6'd0;        // frames within the current second

    wire sec_tick = (fdiv == FRAMES_PER_SEC - 1);

    // ---- next state: one full-width value per counter ----------------------
    reg [7:0] sec_nxt, min_nxt;
    always @(*) begin
        sec_nxt = sec;
        min_nxt = min;
        if (sec_tick) begin
            if (sec[3:0] != 4'd9) begin
                sec_nxt = {sec[7:4], sec[3:0] + 4'd1};
            end else if (sec[7:4] != 4'd5) begin
                sec_nxt = {sec[7:4] + 4'd1, 4'd0};
            end else begin
                // 59 -> 00 and carry into the minutes
                sec_nxt = 8'h00;
                if (min[3:0] != 4'd9) begin
                    min_nxt = {min[7:4], min[3:0] + 4'd1};
                end else if (min[7:4] != 4'd9) begin
                    min_nxt = {min[7:4] + 4'd1, 4'd0};
                end else begin
                    min_nxt = 8'h00;
                end
            end
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            fdiv <= 6'd0;
            sec  <= 8'h00;
            min  <= 8'h00;
        end else if (tick) begin
            fdiv <= sec_tick ? 6'd0 : (fdiv + 6'd1);
            if (sec_tick) begin
                sec <= sec_nxt;
                min <= min_nxt;
            end
        end
    end
endmodule
