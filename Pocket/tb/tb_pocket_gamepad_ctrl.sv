//
// Testbench for pocket_gamepad_ctrl
//
`timescale 1ns / 1ps
`default_nettype none

module tb_pocket_gamepad_ctrl;

    reg clk;
    reg reset_n;
    reg [15:0] key_in;
    wire [15:0] key_out;
    wire [1:0] mode_l;
    wire [1:0] mode_r;

    // Use fast timing parameters for testbench
    localparam int HOLD_CYCLES  = 10;
    localparam int PULSE_CYCLES = 5;

    pocket_gamepad_ctrl #(
        .HOLD_CYCLES(HOLD_CYCLES),
        .PULSE_CYCLES(PULSE_CYCLES)
    ) dut (
        .clk(clk),
        .reset_n(reset_n),
        .key_in(key_in),
        .key_out(key_out),
        .mode_l(mode_l),
        .mode_r(mode_r)
    );

    // 50 MHz clock: period = 20ns
    always #10 clk = ~clk;

    int errors = 0;

    task check(input string desc, input bit cond);
        if (!cond) begin
            $display("FAIL [t=%0t]: %s", $time, desc);
            errors++;
        end else begin
            $display("OK   [t=%0t]: %s", $time, desc);
        end
    endtask

    task cycle(input int n = 1);
        repeat (n) @(posedge clk);
        #1;
    endtask

    initial begin
        clk = 0;
        reset_n = 0;
        key_in = 16'h0000;
        errors = 0;

        cycle(5);
        reset_n = 1;
        cycle(2);

        // 1. Initial state checks
        check("Initial mode_l is 2'b00 (Tier 1)", mode_l == 2'b00);
        check("Initial mode_r is 2'b00 (Tier 1)", mode_r == 2'b00);
        check("Initial key_out is 0", key_out == 16'h0000);

        // 2. Direct button passthrough (D-pad, Face buttons, Start)
        key_in[0] = 1; // Up
        key_in[4] = 1; // A
        key_in[15] = 1; // Start
        cycle(2);
        check("Passthrough Up, A, Start", key_out[0] == 1 && key_out[4] == 1 && key_out[15] == 1);
        key_in = 16'h0000;
        cycle(2);

        // 3. Tier 1 (Default): Press R -> R1 only
        key_in[9] = 1; // R
        cycle(2);
        check("Tier 1: R gives R1=1, R2=0", key_out[9] == 1 && key_out[11] == 0);
        key_in[9] = 0;
        cycle(2);

        // 4. Cycle R: Select + R -> switches to Tier 2 (R2)
        key_in[14] = 1; // Select
        cycle(2);
        key_in[9] = 1;  // R
        cycle(2);
        check("After Select+R, mode_r is 2'b01 (Tier 2)", mode_r == 2'b01);
        check("Select is suppressed during chord", key_out[14] == 0);
        check("R2 is asserted while held in Tier 2", key_out[11] == 1 && key_out[9] == 0);
        key_in[9] = 0;
        key_in[14] = 0;
        cycle(10);
        check("Select remains suppressed after chord release", key_out[14] == 0);

        // Test Tier 2 alone: Press R -> R2 only
        key_in[9] = 1;
        cycle(2);
        check("Tier 2: R alone gives R1=0, R2=1", key_out[9] == 0 && key_out[11] == 1);
        key_in[9] = 0;
        cycle(2);

        // 5. Cycle R again: Select + R -> switches to Tier 3 (Dual: R1+R2)
        key_in[14] = 1; // Select
        key_in[9] = 1;  // R
        cycle(2);
        check("After second Select+R, mode_r is 2'b10 (Dual)", mode_r == 2'b10);
        key_in[9] = 0;
        key_in[14] = 0;
        cycle(10);

        // Test Tier 3 alone: Press R -> Both R1 and R2 simultaneously!
        key_in[9] = 1;
        cycle(2);
        check("Tier 3 Dual: R alone gives R1=1 AND R2=1 simultaneously", key_out[9] == 1 && key_out[11] == 1);
        key_in[9] = 0;
        cycle(2);

        // 6. Cycle R back to Tier 1
        key_in[14] = 1;
        key_in[9] = 1;
        cycle(2);
        check("After third Select+R, mode_r wraps to 2'b00 (Tier 1)", mode_r == 2'b00);
        key_in[9] = 0;
        key_in[14] = 0;
        cycle(10);

        key_in[9] = 1;
        cycle(2);
        check("Tier 1 again: R gives R1=1, R2=0", key_out[9] == 1 && key_out[11] == 0);
        key_in[9] = 0;
        cycle(2);

        // 7. Cycle L independently: L1 -> L2 -> Dual -> L1
        check("L starts in mode_l=2'b00", mode_l == 2'b00);
        // Toggle L to Tier 2
        key_in[14] = 1; key_in[8] = 1; cycle(2);
        key_in[8] = 0; key_in[14] = 0; cycle(10);
        check("L cycled to Tier 2 (mode_l=2'b01)", mode_l == 2'b01);
        key_in[8] = 1; cycle(2);
        check("Tier 2: L gives L1=0, L2=1", key_out[8] == 0 && key_out[10] == 1);
        key_in[8] = 0; cycle(2);

        // Toggle L to Tier 3 (Dual)
        key_in[14] = 1; key_in[8] = 1; cycle(2);
        key_in[8] = 0; key_in[14] = 0; cycle(10);
        check("L cycled to Tier 3 Dual (mode_l=2'b10)", mode_l == 2'b10);
        key_in[8] = 1; cycle(2);
        check("Tier 3 Dual: L gives L1=1 AND L2=1 simultaneously", key_out[8] == 1 && key_out[10] == 1);
        key_in[8] = 0; cycle(2);

        // Toggle L back to Tier 1
        key_in[14] = 1; key_in[8] = 1; cycle(2);
        key_in[8] = 0; key_in[14] = 0; cycle(10);
        check("L cycled back to Tier 1 (mode_l=2'b00)", mode_l == 2'b00);

        // 8. Standalone Select tap: Select pressed and released without L/R
        key_in[14] = 1;
        cycle(3); // Less than HOLD_CYCLES (10)
        check("Select not yet emitted while held within tap window", key_out[14] == 0);
        key_in[14] = 0;
        cycle(1);
        check("Select pulse emitted on tap release", key_out[14] == 1);
        cycle(PULSE_CYCLES);
        cycle(1);
        check("Select pulse terminates after PULSE_CYCLES", key_out[14] == 0);

        // 9. Standalone Select hold: Select held longer than HOLD_CYCLES
        key_in[14] = 1;
        cycle(HOLD_CYCLES + 2);
        check("Select emitted continuously after HOLD_CYCLES threshold", key_out[14] == 1);
        cycle(5);
        check("Select still emitted while held", key_out[14] == 1);
        key_in[14] = 0;
        cycle(2);
        check("Select deasserts after hold release", key_out[14] == 0);

        // 10. External controller (dock) L2/R2 passthrough
        key_in[10] = 1; // External L2
        key_in[11] = 1; // External R2
        cycle(2);
        check("External L2/R2 pass through directly", key_out[10] == 1 && key_out[11] == 1);
        key_in[10] = 0; key_in[11] = 0;
        cycle(2);

        if (errors == 0) begin
            $display("PASS tb_pocket_gamepad_ctrl: all tests passed!");
            $finish(0);
        end else begin
            $display("FAIL tb_pocket_gamepad_ctrl: %0d error(s)", errors);
            $finish(1);
        end
    end

endmodule
`default_nettype wire
