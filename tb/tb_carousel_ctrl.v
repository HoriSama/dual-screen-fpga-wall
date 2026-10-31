//=============================================================================
// tb_carousel_ctrl.v -- wall_carousel envelope, step-at-black and auto toggle
//
// Three full 256-frame cycles with the PRODUCTION parameters (224 hold, 16 fade
// out, 16 fade in) plus a manual-mode pass:
//   * gain follows the envelope exactly (255 .. 0 .. 255);
//   * the phase only ever steps while the gain is 0 (the switch must be unseen);
//   * the phase steps exactly once per 256-frame cycle;
//   * auto off -> gain snaps back to 255 and `step` advances at once;
//   * auto on again -> the envelope restarts from hold.
//
//   vsim -c -do "run -all; quit -f" tb_carousel_ctrl
//=============================================================================
`timescale 1ns/1ps

module tb_carousel_ctrl;
    localparam integer HOLD = 224;
    localparam integer FADE = 16;
    localparam integer CYC  = HOLD + 2*FADE;      // 256
    localparam integer STEP = 255 / (FADE - 1);   // 17

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1, frame = 1'b0, toggle = 1'b0, step = 1'b0;
    wire [1:0] cyc;
    wire auto_on;
    wire [7:0] gain;

    wall_carousel #(.HOLD_FRAMES(HOLD), .FADE_FRAMES(FADE)) u_dut (
        .clk(clk), .rst(rst), .frame(frame), .toggle(toggle), .step(step),
        .cyc(cyc), .auto_on(auto_on), .gain(gain));

    integer errors = 0, checked = 0, p, i, cyc_changes, last_cyc;
    reg [7:0] gain_exp;
    reg [1:0] cyc_before;

    task do_frame;
        begin
            @(posedge clk);          // update
            frame = 1'b1;
            @(posedge clk);
            frame = 1'b0;
            #1;
        end
    endtask

    // expected envelope for phase-in-cycle p
    function [7:0] env;
        input integer p_in;
        begin
            if (p_in < HOLD)                       env = 8'd255;
            else if (p_in < HOLD + FADE)           env = 8'd255 - (p_in - HOLD) * STEP;
            else                                   env = (p_in - HOLD - FADE) * STEP;
        end
    endfunction

    initial begin
        repeat (2) @(posedge clk);
        rst = 1'b0;
        @(posedge clk);
        #1;

        // ---- reset state ---------------------------------------------------
        if (gain !== 8'hFF || cyc !== 2'd0 || auto_on !== 1'b1) begin
            $display("RESET FAIL: gain=%0d cyc=%0d auto=%0d", gain, cyc, auto_on);
            errors = errors + 1;
        end

        // ---- 3 full cycles in auto mode ------------------------------------
        cyc_changes = 0;
        last_cyc    = cyc;
        for (i = 0; i < 3*CYC; i = i + 1) begin
            p        = i % CYC;
            gain_exp = env(p);
            cyc_before = cyc;
            do_frame;
            if (gain !== gain_exp) begin
                if (errors < 8)
                    $display("  frame %0d (p=%0d): gain %0d want %0d", i, p, gain, gain_exp);
                errors = errors + 1;
            end
            if (cyc !== cyc_before) begin
                cyc_changes = cyc_changes + 1;
                if (gain !== 8'd0) begin
                    if (errors < 8)
                        $display("  frame %0d: phase stepped at gain %0d (must be 0)", i, gain);
                    errors = errors + 1;
                end
            end
            last_cyc = cyc;
            checked  = checked + 1;
        end
        if (cyc_changes != 3) begin
            $display("CYCLE COUNT FAIL: %0d phase steps in 3 cycles", cyc_changes);
            errors = errors + 1;
        end
        $display("auto: %0d frames checked, %0d phase steps, gain at step = 0",
                 checked, cyc_changes);

        // ---- manual mode ---------------------------------------------------
        @(posedge clk); #1 toggle = 1'b1;     // request auto off
        do_frame;                              // consumed at the frame boundary
        toggle = 1'b0;
        if (auto_on !== 1'b0) begin
            $display("TOGGLE FAIL: auto_on did not clear");
            errors = errors + 1;
        end
        // a few frames: gain must be 255 and the phase must not move on its own
        cyc_before = cyc;
        repeat (40) do_frame;
        if (gain !== 8'hFF) begin
            $display("MANUAL FAIL: gain %0d (want 255)", gain);
            errors = errors + 1;
        end
        if (cyc !== cyc_before) begin
            $display("MANUAL FAIL: phase moved without a step request");
            errors = errors + 1;
        end
        // one manual step lands immediately
        @(posedge clk); #1 step = 1'b1;
        do_frame;
        step = 1'b0;
        if (cyc !== (cyc_before + 2'd1)) begin
            $display("STEP FAIL: cyc %0d want %0d", cyc, cyc_before + 2'd1);
            errors = errors + 1;
        end else begin
            $display("manual: gain stays 255, one step request = one phase step");
        end

        // ---- back to auto: envelope restarts from hold ---------------------
        @(posedge clk); #1 toggle = 1'b1;
        do_frame;
        toggle = 1'b0;
        if (auto_on !== 1'b1) begin
            $display("TOGGLE FAIL: auto_on did not set");
            errors = errors + 1;
        end
        for (i = 0; i < HOLD + 2; i = i + 1) begin
            gain_exp = env(i % CYC);
            do_frame;
            if (gain !== gain_exp) begin
                $display("  resume frame %0d: gain %0d want %0d", i, gain, gain_exp);
                errors = errors + 1;
            end
        end

        if (errors == 0) $display("TB_CAROUSEL_CTRL PASS");
        else             $display("TB_CAROUSEL_CTRL FAIL (%0d)", errors);
        $finish;
    end
endmodule
