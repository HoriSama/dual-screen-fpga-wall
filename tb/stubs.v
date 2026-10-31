// Simulation-only behavioural stand-ins for the two hard-IP wrappers.
// They are NOT synthesised and must never be added to the TD project.
`timescale 1ns/1ps

module p1_hdmi_pll_50m_25_125 (
    input  wire refclk_50m,
    input  wire reset,
    output wire lock,
    output wire pixel_clk,
    output wire serial_clk
);
    assign lock = 1'b1;
    reg pc = 1'b0;
    always @(posedge refclk_50m) pc <= ~pc;
    assign pixel_clk  = pc;      // 50 MHz / 2
    assign serial_clk = pc;
endmodule

module apug092_tx_wrapper #(
    parameter integer HACTIVE = 640,
    parameter integer HFP = 16,
    parameter integer HSA = 96,
    parameter integer HBP = 48,
    parameter integer VACTIVE = 480,
    parameter integer VFP = 10,
    parameter integer VSA = 2,
    parameter integer VBP = 33,
    parameter integer VIDEO_VIC = 1,
    parameter integer IIC_SCL_DIV = 250
)(
    input  wire        pixel_clk,
    input  wire        serial_clk,
    input  wire        rst,
    input  wire        edid_read_trig,
    output wire        edid_read_valid,
    output wire [7:0]  edid_read_data,
    input  wire        axis_user,
    input  wire        axis_valid,
    input  wire        axis_last,
    input  wire [23:0] axis_data,
    output wire        axis_ready,
    input  wire        audio_valid,
    input  wire [23:0] audio_left_data,
    input  wire [23:0] audio_right_data,
    input  wire        acr_valid,
    input  wire [19:0] acr_cts,
    input  wire [19:0] acr_n,
    output wire        video_locked,
    output wire        ddc_scl,
    inout  wire        ddc_sda,
    output wire        tmds_ch0_p,
    output wire        tmds_ch1_p,
    output wire        tmds_ch2_p,
    output wire        tmds_clk_p
);
    assign edid_read_valid = 1'b0;
    assign edid_read_data  = 8'd0;
    assign axis_ready      = 1'b1;
    assign video_locked    = 1'b1;
    assign ddc_scl         = 1'b1;
    assign tmds_ch0_p      = 1'b0;
    assign tmds_ch1_p      = 1'b0;
    assign tmds_ch2_p      = 1'b0;
    assign tmds_clk_p      = 1'b0;
endmodule

// --- SDRAM-side stubs for simulation only (TD uses the real vendor IP) ---
module clk_pll (
    input  wire refclk,
    input  wire reset,
    output wire extlock,
    output wire clk0_out,
    output wire clk1_out,
    output wire clk2_out
);
    reg [2:0] div = 3'd0;
    reg c1 = 1'b0;
    always @(posedge refclk) begin
        div <= div + 3'd1;
        if (div == 3'd2) c1 <= ~c1;      // 6x the pixel clock
    end
    assign extlock = 1'b1;
    assign clk0_out = refclk;
    assign clk1_out = c1;
    assign clk2_out = ~c1;
endmodule

module apug011_core_wrapper (
    input  wire        Sdr_clk,
    input  wire        Sdr_clk_sft,
    input  wire        rst_n,
    output wire        Sdr_init_done,
    output wire        Sdr_init_ref_vld,
    output wire        Sdr_busy,
    output wire        App_ref_req,
    input  wire        App_wr_en,
    input  wire [20:0] App_wr_addr,
    input  wire [3:0]  App_wr_dm,
    input  wire [31:0] App_wr_din,
    input  wire        App_rd_en,
    input  wire [20:0] App_rd_addr,
    input  wire        Sdr_rd_en,
    output wire [31:0] Sdr_rd_dout,
    output wire        SDRAM_CLK,
    output wire        SDR_RAS,
    output wire        SDR_CAS,
    output wire        SDR_WE,
    output wire [1:0]  SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0]  SDR_DM,
    inout  wire [31:0] SDR_DQ
);
    assign Sdr_init_done    = 1'b1;
    assign Sdr_init_ref_vld = 1'b0;
    assign Sdr_busy         = 1'b0;
    assign App_ref_req      = 1'b0;
    assign Sdr_rd_dout      = 32'd0;
    assign SDRAM_CLK = 1'b0;
    assign SDR_RAS   = 1'b1;
    assign SDR_CAS   = 1'b1;
    assign SDR_WE    = 1'b1;
    assign SDR_BA    = 2'b00;
    assign SDR_ADDR  = 11'd0;
    assign SDR_DM    = 4'hF;
endmodule

module EG_PHY_SDRAM_2M_32 (
    input  wire        clk,
    input  wire        ras_n,
    input  wire        cas_n,
    input  wire        we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    inout  wire [31:0] dq,
    input  wire        cs_n,
    input  wire        dm0,
    input  wire        dm1,
    input  wire        dm2,
    input  wire        dm3,
    input  wire        cke
);
endmodule
