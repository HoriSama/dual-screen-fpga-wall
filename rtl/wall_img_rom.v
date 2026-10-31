// Generated: 4 image banks in one EG_LOGIC_BRAM single-port ROM.
// ADDRESS MAP: addr[14:13] = window id, addr[12:0] = (cy/3)*96 + (cx/3) clamped.
`timescale 1ns/1ps
module wall_img_rom (
    input  wire        clk,
    input  wire [14:0] addr,
    output reg  [11:0] dout
);
    wire [11:0] doa;
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(12), .ADDR_WIDTH_A(15), .DATA_DEPTH_A(32768),
        .DATA_WIDTH_B(12), .ADDR_WIDTH_B(15), .DATA_DEPTH_B(32768),
        .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("C:/Users/japsa/Documents/deepseek-harness/default-workspace/wall/rtl/wall_img.mif"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(12'd0), .dib(12'd0), .addra(addr), .addrb(15'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clk), .clkb(1'b0), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(doa), .dob()
    );
    always @(posedge clk) dout <= doa;
endmodule
