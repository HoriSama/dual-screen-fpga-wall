//=============================================================================
// wall_sdram_test.v -- power-on read/write self-test of the APUG011 SDRAM
//
// Writes 1024 words of a known pattern through the arbiter and reads them back.
// `errors` and `done` are latched and published on the status UART, so the
// SDRAM path can be validated on hardware without a logic analyzer.
//
// The addresses sit at word 0x001000+ so they never collide with the image
// library slots that W2 will use (4 x 307200 words starting at 0).
//=============================================================================
`timescale 1ns/1ps

module wall_sdram_test #(
    // Parked past the four image-library slots (0 .. 0x12BFFF), see
    // docs/03_w2_media_plan.md section 6.1.
    parameter integer BASE  = 21'h1E0000,
    parameter integer COUNT = 1024
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    // write port into sdram_arbiter
    output reg         wr_valid,
    output reg  [20:0] wr_addr,
    output reg  [31:0] wr_data,
    input  wire        wr_ready,
    // read port into sdram_arbiter
    output reg         rd_valid,
    output reg  [20:0] rd_addr,
    input  wire        rd_ready,
    input  wire        rvalid,
    input  wire [31:0] rdata,
    // results
    output reg         done,
    output reg         failed,
    output reg  [15:0] errors,
    output reg  [15:0] checked
);
    localparam [2:0] S_IDLE = 3'd0, S_WR = 3'd1, S_WR_DRAIN = 3'd2,
                     S_RD = 3'd3, S_RD_WAIT = 3'd4, S_DONE = 3'd5;

    reg [2:0]  st;
    reg [10:0] idx;
    reg [7:0]  drain;

    function [31:0] pattern;
        input [10:0] a;
        begin
            pattern = 32'hC0DE_0000 + {21'd0, a};
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st       <= S_IDLE;
            idx      <= 11'd0;
            drain    <= 8'd0;
            wr_valid <= 1'b0;
            rd_valid <= 1'b0;
            wr_addr  <= 21'd0;
            wr_data  <= 32'd0;
            rd_addr  <= 21'd0;
            done     <= 1'b0;
            failed   <= 1'b0;
            errors   <= 16'd0;
            checked  <= 16'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    if (start) begin
                        idx      <= 11'd0;
                        errors   <= 16'd0;
                        checked  <= 16'd0;
                        failed   <= 1'b0;
                        wr_valid <= 1'b1;
                        wr_addr  <= BASE[20:0];
                        wr_data  <= pattern(11'd0);
                        st       <= S_WR;
                    end
                end

                S_WR: begin
                    if (wr_ready) begin
                        if (idx == COUNT - 1) begin
                            wr_valid <= 1'b0;
                            drain    <= 8'd0;
                            st       <= S_WR_DRAIN;
                        end else begin
                            idx     <= idx + 11'd1;
                            wr_addr <= BASE[20:0] + idx + 11'd1;
                            wr_data <= pattern(idx + 11'd1);
                        end
                    end
                end

                // Give the arbiter/adapter time to retire the last write before
                // turning the port around (the adapter has one outstanding slot).
                S_WR_DRAIN: begin
                    if (drain == 8'd63) begin
                        idx     <= 11'd0;
                        rd_addr <= BASE[20:0];
                        st      <= S_RD;
                    end else begin
                        drain <= drain + 8'd1;
                    end
                end

                S_RD: begin
                    rd_valid <= 1'b1;
                    rd_addr  <= BASE[20:0] + idx;
                    if (rd_ready) begin
                        rd_valid <= 1'b0;
                        st       <= S_RD_WAIT;
                    end
                end

                S_RD_WAIT: begin
                    if (rvalid) begin
                        checked <= checked + 16'd1;
                        if (rdata != pattern(idx)) begin
                            if (errors != 16'hFFFF) errors <= errors + 16'd1;
                            failed <= 1'b1;
                        end
                        if (idx == COUNT - 1) begin
                            st <= S_DONE;
                        end else begin
                            idx <= idx + 11'd1;
                            st  <= S_RD;
                        end
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    st   <= S_DONE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
