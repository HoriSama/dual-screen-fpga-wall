//=============================================================================
// tb_sd_dump.v -- feed 128 known bytes into wall_sd_dump, receive the dump.
// Expected stream: 53 44 80 00, then 00..7F.
//   vsim -c -do "run -all; quit -f" tb_sd_dump
//=============================================================================
`timescale 1ns/1ps

module tb_sd_dump;
    reg clk = 1'b0, rst = 1'b1;
    always #20 clk = ~clk;              // 25 MHz

    reg        vld = 1'b0;
    reg  [7:0] dat = 8'd0;
    reg        endp = 1'b0;
    wire       active, tx;

    wall_sd_dump #(.NBYTES(128), .GAP_CYC(2000)) dut (
        .clk(clk), .rst(rst),
        .sd_valid(vld), .sd_data(dat), .sd_end(endp),
        .active(active), .tx(tx)
    );

    // 8N1 receiver at DIV = 217 -> 8680 ns per bit
    localparam integer BIT_NS = 217 * 40;
    integer   n = 0, i;
    reg [7:0] rb;

    always begin
        @(negedge tx);
        #(BIT_NS + BIT_NS / 2);
        for (i = 0; i < 8; i = i + 1) begin
            rb[i] = tx;
            #(BIT_NS);
        end
        // The dump sends bytes back to back, so come back to @(negedge tx)
        // a quarter bit into the stop bit -- waiting the whole stop bit would
        // land exactly on the next start edge and miss every second byte.
        #(BIT_NS / 4);
        $write("%02X ", rb);
        n = n + 1;
        if (n % 16 == 0) $write("\n");
        if (n == 132) begin
            $display("\nTB_SD_DUMP DONE (%0d bytes)", n);
            $finish;
        end
    end

    integer k;
    initial begin
        #(100 * 40) rst = 1'b0;
        #(100 * 40);
        for (k = 0; k < 128; k = k + 1) begin
            @(posedge clk);
            vld <= 1'b1;
            dat <= k[7:0];
        end
        @(posedge clk);
        vld  <= 1'b0;
        endp <= 1'b1;
        @(posedge clk);
        endp <= 1'b0;
        #20_000_000;
        $display("TIMEOUT: only %0d bytes", n);
        $finish;
    end
endmodule
