//=============================================================================
// wall_demo_a.v -- node A with the synthetic drag enabled
//
// Same pins and flow as wall_node_a.  It instantiates wall_core directly (and
// as u_core) so the timing-constraint clock names in pin/wall_a.sdc keep
// matching; the only behavioural difference is AUTODRAG=1, which drags the
// selected window across the seam by itself so a host can verify the
// distributed table through the two status UARTs.
//
// Build:  -top wall_demo_a   with pin/wall_node_a.adc and pin/wall_a.sdc
//=============================================================================
`timescale 1ns/1ps

module wall_demo_a (
    input  wire clk,
    input  wire [3:0] key_n,
    input  wire [3:0] sw_n,
    output wire [3:0] led,
    output wire uart_tx,
    output wire HDMI_D0_P,
    output wire HDMI_D1_P,
    output wire HDMI_D2_P,
    output wire HDMI_CLK_P,
    output wire HDMI_DDC_SCL,
    inout  wire HDMI_DDC_SDA,
    output wire link_clk,
    output wire link_sync,
    output wire link_vld,
    output wire [3:0] link_d,
    input  wire link_bvld,
    input  wire [3:0] link_bd
);
    wall_core #(.IS_MASTER(1), .NODE_ID(0), .AUTODRAG(1)) u_core (
        .clk50(clk), .key_n(key_n), .sw_n(sw_n), .led(led), .uart_tx(uart_tx),
        .HDMI_D0_P(HDMI_D0_P), .HDMI_D1_P(HDMI_D1_P),
        .HDMI_D2_P(HDMI_D2_P), .HDMI_CLK_P(HDMI_CLK_P),
        .HDMI_DDC_SCL(HDMI_DDC_SCL), .HDMI_DDC_SDA(HDMI_DDC_SDA),
        .o_link_clk(link_clk), .o_link_sync(link_sync),
        .o_link_vld(link_vld), .o_link_d(link_d),
        .i_link_bvld(link_bvld), .i_link_bd(link_bd),
        .i_link_clk(1'b0), .i_link_sync(1'b0), .i_link_vld(1'b0), .i_link_d(4'h0),
        .o_link_bvld(), .o_link_bd()
    );
endmodule
