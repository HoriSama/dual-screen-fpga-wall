//=============================================================================
// tb_sd_sector.v -- simulation-only "card" for the TF loader testbench.
//
// It is NOT an SPI card model.  It sits exactly where sd_card_top sits and
// speaks the same byte-stream interface, so tb_tf_load exercises wall_tf_load
// (FAT32 + BMP + sampling + bank writes) without simulating SPI at all:
//
//   req (one-cycle pulse) + lba  ->  512 x {valid, data}  ->  end (one cycle)
//
// The sector contents come from tb/fat32_img.hex, produced by
// tools/make_tb_fat32.py.  A few idle cycles are inserted before the first byte
// so the loader's request/timeout logic is exercised, not just its happy path.
//=============================================================================
`timescale 1ns/1ps

module tb_sd_sector #(
    parameter integer NSEC  = 444,
    parameter         IMAGE = "../tb/fat32_img.hex",
    parameter integer DELAY = 4            // clocks before the first byte
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        req,
    input  wire [31:0] lba,
    output reg         valid,
    output reg  [7:0]  data,
    output reg         end_o
);
    reg [7:0] mem [0:NSEC*512-1];

    integer i;
    initial begin
        for (i = 0; i < NSEC * 512; i = i + 1) mem[i] = 8'h00;
        $readmemh(IMAGE, mem);
    end

    localparam S_IDLE = 2'd0, S_WAIT = 2'd1, S_DATA = 2'd2, S_END = 2'd3;

    reg [1:0]  st;
    reg [8:0]  n;         // byte counter 0..511
    reg [3:0]  dly;
    reg [31:0] base;      // byte offset of the sector in mem

    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; valid <= 1'b0; data <= 8'd0; end_o <= 1'b0;
            n <= 9'd0; dly <= 4'd0; base <= 32'd0;
        end else begin
            valid <= 1'b0;
            end_o <= 1'b0;
            case (st)
                S_IDLE: if (req) begin
                    base <= (lba < NSEC) ? (lba << 9) : 32'd0;
                    n    <= 9'd0;
                    dly  <= DELAY[3:0];
                    st   <= S_WAIT;
                end
                S_WAIT: begin
                    if (dly == 4'd0) st <= S_DATA;
                    else             dly <= dly - 4'd1;
                end
                S_DATA: begin
                    valid <= 1'b1;
                    data  <= mem[base + n];
                    if (n == 9'd511) st <= S_END;
                    else             n  <= n + 9'd1;
                end
                S_END: begin
                    end_o <= 1'b1;
                    st    <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
