//=============================================================================
// tb_status3.v -- end-to-end check of the 34-byte status frame.
//
// Feeds wall_status_tx with known values, receives the serial stream with a
// behavioural 8N1 receiver, and dumps every byte as hex.  tools/parse_status.py
// then decodes the dump; the expected values are listed in the $display header
// so the comparison needs no extra bookkeeping.
//
//   vsim -c -do "run -all; quit -f" tb_status3
//=============================================================================
`timescale 1ns/1ps

module tb_status3;

    reg clk = 1'b0, rst = 1'b1;
    always #10 clk = ~clk;              // 50 MHz

    wire tx;

    // Distinctive values: every field has a different bit pattern and several
    // of them set bits 6..7, which is where a truncated / shifted byte mux
    // would show up.
    localparam [15:0] OK_C  = 16'h0E3F;
    localparam [15:0] ER_C  = 16'h0059;
    localparam [15:0] FCNT  = 16'h1234;
    localparam [15:0] SERR  = 16'h00D8;
    localparam [11:0] GX_C  = 12'h0AB;
    localparam [11:0] SGX_C = 12'h0CD;
    localparam [9:0]  WW_C  = 10'd300;   // 0x12C
    localparam [9:0]  WH_C  = 10'd210;   // 0x0D2  <- the value the board shows as 0x3F

    wall_status_tx #(.TICK_CYC(2000), .NODE_CH(8'h41)) u (
        .clk(clk), .rst(rst),
        .link_ok(1'b1), .sync_ok(1'b1), .frozen(1'b0), .dragging(1'b0),
        .owner(1'b0), .sel(2'd1),
        .gx(GX_C), .stage_gx(SGX_C), .rst_cnt(8'd7),
        .key_pressed(4'd0), .remote_press(4'd0),
        .frame_cnt(FCNT), .sd_state(4'd3), .sd_b0(8'hEB),
        .win_w(WW_C), .win_h(WH_C),
        .sdram_done(1'b1), .sdram_failed(1'b0), .sdram_errors(SERR),
        .pll_rst_cnt(8'd2), .ok_cnt(OK_C), .err_cnt(ER_C),
        .sd_vcnt(8'hA5), .sd_flags(8'h07),
        .video_locked(1'b1), .video_ready(1'b1), .sup_state(2'd2), .rec_cnt(8'd5),
        .uart_tx(tx)
    );

    // --- behavioural 8N1 receiver ------------------------------------------
    localparam integer BIT_NS = 434 * 20;      // DIV * clk period
    integer n = 0;
    reg [7:0] rb;
    integer i;

    always begin
        @(negedge tx);                          // start bit
        #(BIT_NS + BIT_NS / 2);                 // middle of bit 0
        for (i = 0; i < 8; i = i + 1) begin
            rb[i] = tx;
            #(BIT_NS);
        end
        // rb now holds the byte; wait out the stop bit
        #(BIT_NS / 2);
        $write("%02X ", rb);
        n = n + 1;
        if (n % 34 == 0) $write("\n");
        if (n == 68) begin
            $display("");
            $finish;
        end
    end

    initial begin
        $display("EXPECT: 57 4C 41 03 01 00 AB 0E 3F 00 59 A5 07 23 05 02 00 CD 07 00 03 12 34 EB 01 2C 00 D2 D8 00 01 5A 0D 0A");
        #(200 * 20) rst = 1'b0;
    end

endmodule
