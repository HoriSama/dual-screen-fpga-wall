//=============================================================================
// wall_music.v -- play MUSIC.WAV out of SDRAM at 48 kHz
//
// Two clock domains meet here:
//
//   clk25   the pixel/loader domain: wall_tf_load writes words in, the 48 kHz
//           audio tick and the HDMI audio port live here
//   clk150  the SDRAM client domain (sdram_arbiter -> cached adapter)
//
// The data rate is tiny (one 32-bit word per 20.8 us, 192 kB/s), so instead of a
// dual-clock FIFO this uses a two-phase toggle mailbox in each direction:
//
//   write: clk25 latches addr/data, flips wreq; clk150 sees it, does one write,
//          flips wack; clk25 frees the slot.  One word in flight at a time.
//   read : clk25 latches the frame address, flips rreq; clk150 does one read,
//          flips rack with the data held; clk25 latches it into left/right.
//
// Both buses are held stable for the whole handshake, so no data FIFO is needed
// and the only crossings are the toggles (two flip-flops each).
//
// One SDRAM word is one stereo frame: left in [15:0], right in [31:16].
// Playback loops back to frame 0 after `frames`, which the loader latched.
//=============================================================================
`timescale 1ns/1ps

module wall_music (
    // ---- 25 MHz domain ----------------------------------------------------
    input  wire        clk25,
    input  wire        rst25,
    input  wire        ld_vld,          // loader word in
    input  wire [20:0] ld_addr,
    input  wire [31:0] ld_data,
    output wire        ld_rdy,
    input  wire        tick,            // 48 kHz strobe
    input  wire [20:0] frames,          // 0 = nothing loaded
    output reg  [23:0] left,
    output reg  [23:0] right,
    output reg         out_vld,         // 1 cycle per frame
    output wire        playing,
    output reg  [7:0]  rd_cnt,       // completed SDRAM reads (debug)

    // ---- 150 MHz SDRAM client --------------------------------------------
    input  wire        clk150,
    input  wire        rst150,
    output reg         wr_valid,
    output reg  [20:0] wr_addr,
    output reg  [31:0] wr_data,
    input  wire        wr_ready,
    output reg         rd_valid,
    output reg  [20:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rvalid,
    input  wire [31:0] rdata
);
    assign playing = (frames != 21'd0);

    // crossings, declared up front so Verilog does not infer 1-bit nets
    reg         wack_tgl;               // clk150 -> clk25
    wire        rack_tgl;               // clk150 -> clk25
    wire [31:0] rdata_hold;             // clk150 -> clk25

    // ======================================================================
    // 25 MHz side: loader mailbox + frame sequencer
    // ======================================================================
    reg        w_busy;
    reg        wreq_tgl, wack_sync1, wack_sync2;
    reg [20:0] w_addr_r;
    reg [31:0] w_data_r;

    assign ld_rdy = !w_busy;

    reg        r_busy;
    reg        rreq_tgl, rack_sync1, rack_sync2;
    reg [20:0] r_want;
    reg [20:0] ptr;
    reg [31:0] rdata_sync1, rdata_sync2;

    always @(posedge clk25) begin
        if (rst25) begin
            w_busy <= 1'b0; wreq_tgl <= 1'b0;
            wack_sync1 <= 1'b0; wack_sync2 <= 1'b0;
            w_addr_r <= 21'd0; w_data_r <= 32'd0;

            r_busy <= 1'b0; rreq_tgl <= 1'b0;
            rack_sync1 <= 1'b0; rack_sync2 <= 1'b0;
            r_want <= 21'd0; ptr <= 21'd0;
            rdata_sync1 <= 32'd0; rdata_sync2 <= 32'd0;
            left <= 24'd0; right <= 24'd0; out_vld <= 1'b0;
        end else begin
            wack_sync1 <= wack_tgl;
            wack_sync2 <= wack_sync1;
            rack_sync1 <= rack_tgl;
            rack_sync2 <= rack_sync1;
            rdata_sync1 <= rdata_hold;
            rdata_sync2 <= rdata_sync1;

            // ---- loader word ------------------------------------------
            if (w_busy && (wack_sync2 == wreq_tgl)) w_busy <= 1'b0;
            if (ld_vld && !w_busy) begin
                w_addr_r <= ld_addr;
                w_data_r <= ld_data;
                w_busy   <= 1'b1;
                wreq_tgl <= ~wreq_tgl;
            end

            // ---- one frame every 48 kHz -------------------------------
            out_vld <= 1'b0;
            if (r_busy && (rack_sync2 == rreq_tgl)) begin
                left    <= {{8{rdata_sync2[15]}}, rdata_sync2[15:0]};
                right   <= {{8{rdata_sync2[31]}}, rdata_sync2[31:16]};
                out_vld <= 1'b1;
                r_busy  <= 1'b0;
                ptr     <= (ptr + 21'd1 == frames) ? 21'd0 : (ptr + 21'd1);
            end else if (tick && playing && !r_busy) begin
                r_want   <= ptr;
                r_busy   <= 1'b1;
                rreq_tgl <= ~rreq_tgl;
            end
        end
    end

    // ======================================================================
    // 150 MHz side: serve the mailbox with one SDRAM transaction
    // ======================================================================
    reg        wreq_s1, wreq_s2;
    reg        w_pend;
    reg [20:0] w_addr_q;
    reg [31:0] w_data_q;

    reg        rreq_s1, rreq_s2, rack_tgl_r;
    reg        r_pend;
    reg [20:0] r_addr_q;
    reg [31:0] rdata_hold_r;

    assign rack_tgl   = rack_tgl_r;
    assign rdata_hold = rdata_hold_r;

    always @(posedge clk150) begin
        if (rst150) begin
            wreq_s1 <= 1'b0; wreq_s2 <= 1'b0; wack_tgl <= 1'b0;
            w_pend <= 1'b0; w_addr_q <= 21'd0; w_data_q <= 32'd0;
            wr_valid <= 1'b0; wr_addr <= 21'd0; wr_data <= 32'd0;

            rreq_s1 <= 1'b0; rreq_s2 <= 1'b0; rack_tgl_r <= 1'b0;
            r_pend <= 1'b0; r_addr_q <= 21'd0; rdata_hold_r <= 32'd0;
            rd_valid <= 1'b0; rd_addr <= 21'd0; rd_cnt <= 8'd0;
        end else begin
            wreq_s1 <= wreq_tgl;
            wreq_s2 <= wreq_s1;
            rreq_s1 <= rreq_tgl;
            rreq_s2 <= rreq_s1;

            // ---- write ------------------------------------------------
            if (!w_pend && (wreq_s2 != wack_tgl)) begin
                w_addr_q <= w_addr_r;      // stable until the ack
                w_data_q <= w_data_r;
                w_pend   <= 1'b1;
                wr_valid <= 1'b1;
                wr_addr  <= w_addr_r;
                wr_data  <= w_data_r;
            end
            if (w_pend && wr_valid && wr_ready) begin
                wr_valid <= 1'b0;
                w_pend   <= 1'b0;
                wack_tgl <= wreq_s2;
            end

            // ---- read -------------------------------------------------
            if (!r_pend && (rreq_s2 != rack_tgl_r)) begin
                r_addr_q <= r_want;
                r_pend   <= 1'b1;
                rd_valid <= 1'b1;
                rd_addr  <= r_want;
            end
            if (r_pend && rd_valid && rd_ready) begin
                rd_valid <= 1'b0;
            end
            if (r_pend && rvalid) begin
                rdata_hold_r <= rdata;
                rack_tgl_r   <= rreq_s2;
                r_pend       <= 1'b0;
                rd_cnt       <= rd_cnt + 8'd1;
            end
        end
    end
endmodule