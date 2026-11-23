//
// pocket_gamepad_ctrl.sv
//
// Controller conditioning and shoulder toggle logic for Analogue Pocket PS1 core.
//
`timescale 1ns / 1ps
`default_nettype none

module pocket_gamepad_ctrl #(
    // At 50 MHz: 7,500,000 cycles = 150 ms hold threshold, 4,000,000 cycles = 80 ms tap pulse
    parameter int HOLD_CYCLES  = 7500000,
    parameter int PULSE_CYCLES = 4000000
) (
    input  wire        clk,
    input  wire        reset_n,
    input  wire [15:0] key_in,
    output wire [15:0] key_out,
    output reg  [1:0]  mode_l,
    output reg  [1:0]  mode_r
);

    // Raw button inputs
    wire raw_up     = key_in[0];
    wire raw_down   = key_in[1];
    wire raw_left   = key_in[2];
    wire raw_right  = key_in[3];
    wire raw_a      = key_in[4];
    wire raw_b      = key_in[5];
    wire raw_x      = key_in[6];
    wire raw_y      = key_in[7];
    wire raw_l      = key_in[8];
    wire raw_r      = key_in[9];
    wire raw_l2     = key_in[10]; // external dock trigger
    wire raw_r2     = key_in[11]; // external dock trigger
    wire raw_l3     = key_in[12];
    wire raw_r3     = key_in[13];
    wire raw_select = key_in[14];
    wire raw_start  = key_in[15];

    // Delayed inputs for edge detection
    reg raw_l_d, raw_r_d, raw_select_d;
    wire chord_l = raw_select & raw_l;
    wire chord_r = raw_select & raw_r;
    reg chord_l_d, chord_r_d;

    // Select suppression and pulse management
    reg select_consumed;
    reg [31:0] hold_cnt;
    reg [31:0] pulse_cnt;
    reg select_held_active;

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mode_l             <= 2'b00;
            mode_r             <= 2'b00;
            raw_l_d            <= 1'b0;
            raw_r_d            <= 1'b0;
            raw_select_d       <= 1'b0;
            chord_l_d          <= 1'b0;
            chord_r_d          <= 1'b0;
            select_consumed    <= 1'b0;
            hold_cnt           <= 32'd0;
            pulse_cnt          <= 32'd0;
            select_held_active <= 1'b0;
        end else begin
            raw_l_d      <= raw_l;
            raw_r_d      <= raw_r;
            raw_select_d <= raw_select;
            chord_l_d    <= chord_l;
            chord_r_d    <= chord_r;

            // Mode R toggle: rising edge of chord_r (Select + R)
            if (chord_r && !chord_r_d) begin
                select_consumed <= 1'b1;
                pulse_cnt       <= 32'd0;
                if (mode_r == 2'b10)
                    mode_r <= 2'b00;
                else
                    mode_r <= mode_r + 2'b01;
            end

            // Mode L toggle: rising edge of chord_l (Select + L)
            if (chord_l && !chord_l_d) begin
                select_consumed <= 1'b1;
                pulse_cnt       <= 32'd0;
                if (mode_l == 2'b10)
                    mode_l <= 2'b00;
                else
                    mode_l <= mode_l + 2'b01;
            end

            // Select button state machine
            if (raw_select) begin
                if (!raw_select_d) begin
                    // Fresh press of select; drop any residue tap pulse so it
                    // cannot leak into a chord that follows a tap
                    hold_cnt           <= 32'd0;
                    pulse_cnt          <= 32'd0;
                    select_held_active <= 1'b0;
                    // If L or R was already held down, mark consumed immediately
                    select_consumed    <= raw_l | raw_r;
                end else if (!select_consumed) begin
                    if (hold_cnt < HOLD_CYCLES) begin
                        hold_cnt <= hold_cnt + 32'd1;
                    end else begin
                        select_held_active <= 1'b1;
                    end
                end
            end else begin
                // Select released
                select_held_active <= 1'b0;
                hold_cnt           <= 32'd0;
                if (raw_select_d) begin
                    // On falling edge of select: emit pulse if tapped alone and not consumed
                    if (!select_consumed && (hold_cnt < HOLD_CYCLES)) begin
                        pulse_cnt <= PULSE_CYCLES;
                    end
                    select_consumed <= 1'b0;
                end else if (pulse_cnt > 32'd0) begin
                    pulse_cnt <= pulse_cnt - 32'd1;
                end
            end
        end
    end

    // Shoulder outputs based on active mode
    wire out_l1 = (mode_l == 2'b00 || mode_l == 2'b10) ? raw_l : 1'b0;
    wire out_l2 = ((mode_l == 2'b01 || mode_l == 2'b10) ? raw_l : 1'b0) | raw_l2;

    wire out_r1 = (mode_r == 2'b00 || mode_r == 2'b10) ? raw_r : 1'b0;
    wire out_r2 = ((mode_r == 2'b01 || mode_r == 2'b10) ? raw_r : 1'b0) | raw_r2;

    wire out_select = select_held_active | (pulse_cnt > 32'd0);

    assign key_out = {
        raw_start,     // [15]
        out_select,    // [14]
        raw_r3,        // [13]
        raw_l3,        // [12]
        out_r2,        // [11]
        out_l2,        // [10]
        out_r1,        // [9]
        out_l1,        // [8]
        raw_y,         // [7]
        raw_x,         // [6]
        raw_b,         // [5]
        raw_a,         // [4]
        raw_right,     // [3]
        raw_left,      // [2]
        raw_down,      // [1]
        raw_up         // [0]
    };

endmodule
`default_nettype wire
