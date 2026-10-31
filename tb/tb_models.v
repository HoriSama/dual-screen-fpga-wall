// Simulation-only behavioural stand-in for TD's EG_LOGIC_BRAM primitive.
// td's own model (D:\TD6.2\sim_release\eg4\eg_logic_bram.v) is encrypted and
// ModelSim ASE cannot open it, so the SIM needs this.  It is NOT synthesised and
// must never be added to the TD read_hdl list.
//
// Only the modes this project uses are implemented:
//   MODE "SP"  (single port, port A only)   REGMODE_A "NOREG" (async doa)
`timescale 1ns/1ps

module EG_LOGIC_BRAM #(
    parameter integer DATA_WIDTH_A = 8,
    parameter integer ADDR_WIDTH_A = 10,
    parameter integer DATA_DEPTH_A = 1024,
    parameter integer DATA_WIDTH_B = 8,
    parameter integer ADDR_WIDTH_B = 10,
    parameter integer DATA_DEPTH_B = 1024,
    parameter         MODE         = "SP",
    parameter         REGMODE_A    = "NOREG",
    parameter         REGMODE_B    = "NOREG",
    parameter         IMPLEMENT    = "9K",
    parameter         DEBUGGABLE   = "NO",
    parameter         PACKABLE     = "NO",
    parameter         INIT_FILE    = "NONE",
    parameter         FILL_ALL     = "NONE"
)(
    input  wire [DATA_WIDTH_A-1:0] dia,
    input  wire [DATA_WIDTH_B-1:0] dib,
    input  wire [ADDR_WIDTH_A-1:0] addra,
    input  wire [ADDR_WIDTH_B-1:0] addrb,
    input  wire                    cea,
    input  wire                    ceb,
    input  wire                    ocea,
    input  wire                    oceb,
    input  wire                    clka,
    input  wire                    clkb,
    input  wire                    wea,
    input  wire                    web,
    input  wire                    bea,
    input  wire                    beb,
    input  wire                    rsta,
    input  wire                    rstb,
    output wire [DATA_WIDTH_A-1:0] doa,
    output wire [DATA_WIDTH_B-1:0] dob
);
    reg [DATA_WIDTH_A-1:0] mem [0:DATA_DEPTH_A-1];
    reg [DATA_WIDTH_A-1:0] doa_r;
    reg [DATA_WIDTH_B-1:0] dob_r;

    always @(posedge clka) begin
        if (cea) begin
            if (wea) mem[addra] <= dia;
            else     doa_r <= mem[addra];
        end
    end

    always @(posedge clkb) begin
        if (ceb) dob_r <= mem[addrb];
    end

    // The address is registered inside the block even in the "NOREG" (no OUTPUT
    // register) mode, so the data is one cycle behind the address.  Modelling
    // doa as purely combinational here is what hid a two-cycle latency bug that
    // the board's self-check then reported as 255 mismatching words.
    assign doa = doa_r;
    assign dob = dob_r;
endmodule
