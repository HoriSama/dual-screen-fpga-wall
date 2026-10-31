//=============================================================================
// wall_uart_tx.v -- minimal 8N1 transmitter (50 MHz / 434 = 115200 baud)
//
// Lifted from the board-proven murmur_d1 uart_tx.v so the CH340 pin (D12)
// keeps exactly the timing that already worked on this hardware.
//=============================================================================
`timescale 1ns/1ps

module wall_uart_tx #(
    parameter integer DIV = 434
)(
    input  wire       clk,
    input  wire       go,
    input  wire [7:0] data,
    output reg        tx   = 1'b1,
    output reg        busy = 1'b0
);
    reg [15:0] cnt;
    reg [3:0]  bit;
    reg [9:0]  sh;
    reg        run = 1'b0;

    always @(posedge clk) begin
        if (!run) begin
            busy <= 1'b0;
            tx   <= 1'b1;
            cnt  <= 16'd0;
            if (go) begin
                sh   <= {1'b1, data, 1'b0};
                run  <= 1'b1;
                bit  <= 4'd0;
                tx   <= 1'b0;
                busy <= 1'b1;
            end
        end else begin
            if (cnt == DIV - 1) begin
                cnt <= 16'd0;
                if (bit == 4'd9) begin
                    run  <= 1'b0;
                    busy <= 1'b0;
                    tx   <= 1'b1;
                end else begin
                    bit <= bit + 4'd1;
                    tx  <= sh[1];
                    sh  <= {1'b1, sh[9:1]};
                end
            end else begin
                cnt <= cnt + 16'd1;
            end
        end
    end
endmodule
