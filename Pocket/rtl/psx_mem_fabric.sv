// SPDX-License-Identifier: MIT
// One backend transaction in flight; one reserved response slot per client.
// Address units, reset requirements and ordering: docs/POCKET_MEMORY_CONTRACT.md.
// This block is not yet connected to the legacy Pocket top.
`default_nettype none

module psx_mem_fabric #(
    parameter integer N = 6,
    parameter integer URGENT_MAX = 4
) (
    input  wire                      clk,
    input  wire                      rst,
    input  wire [N-1:0]               p_req_valid,
    output logic [N-1:0]              p_req_ready,
    input  wire [N-1:0]               p_req_write,
    input  wire [N-1:0][24:0]         p_req_addr,
    input  wire [N-1:0][3:0]          p_req_len,
    input  wire [N-1:0][127:0]        p_req_wdata,
    input  wire [N-1:0][15:0]         p_req_mask,
    input  wire [N-1:0]               p_req_urgent,
    output logic [N-1:0]              p_rsp_valid,
    input  wire [N-1:0]               p_rsp_ready,
    output logic [N-1:0][127:0]       p_rsp_rdata,
    output logic [N-1:0]              p_rsp_error,

    output wire                      b_req_valid,
    input  wire                      b_req_ready,
    output logic                     b_req_write,
    output logic [24:0]               b_req_addr,
    output logic [3:0]                b_req_len,
    output logic [127:0]              b_req_wdata,
    output logic [15:0]               b_req_mask,
    input  wire                      b_rsp_valid,
    output wire                      b_rsp_ready,
    input  wire [127:0]               b_rsp_rdata,
    input  wire                      b_rsp_error,
    // Sticky unexpected-response indication. Does not attempt unsafe recovery.
    output logic                     protocol_fault
);
    localparam integer IW = (N > 1) ? $clog2(N) : 1;
    localparam integer UW = (URGENT_MAX > 0) ? $clog2(URGENT_MAX + 1) : 1;
    typedef enum logic [1:0] {IDLE, ISSUE, WAIT_RESULT} state_t;
    state_t state;
    logic [IW-1:0] owner, fair_next, urgent_next;
    logic [UW-1:0] urgent_count;
    logic [N-1:0] eligible;
    logic fair_found, urgent_found, expedited;
    logic [IW-1:0] fair_pick, urgent_pick, pick;
    logic [25:0] end_address;
    logic bad_request;
    logic [15:0] bounded_mask;
    integer idx;

    function automatic [IW-1:0] successor(input [IW-1:0] port_id);
        successor = (port_id == IW'(N-1)) ? '0 : port_id + 1'b1;
    endfunction

    always_comb begin
        eligible = p_req_valid & (~p_rsp_valid | p_rsp_ready);
        fair_found = 1'b0;
        urgent_found = 1'b0;
        fair_pick = fair_next;
        urgent_pick = urgent_next;
        idx = 0;
        for (integer k = 0; k < N; k = k + 1) begin
            idx = int'(fair_next) + k;
            if (idx >= N) idx = idx - N;
            if (!fair_found && eligible[idx]) begin
                fair_found = 1'b1;
                fair_pick = IW'(idx);
            end
            idx = int'(urgent_next) + k;
            if (idx >= N) idx = idx - N;
            if (!urgent_found && eligible[idx] && p_req_urgent[idx]) begin
                urgent_found = 1'b1;
                urgent_pick = IW'(idx);
            end
        end
        expedited = urgent_found && (int'(urgent_count) < URGENT_MAX);
        pick = expedited ? urgent_pick : fair_pick;
        p_req_ready = '0;
        if (!rst && state == IDLE && fair_found) p_req_ready[pick] = 1'b1;

        // Exclusive end address: an exact end at 64 MiB is legal.
        end_address = {1'b0, p_req_addr[pick]} + 26'(p_req_len[pick]);
        bad_request = p_req_len[pick] == 0 || p_req_len[pick] > 8 ||
                      end_address > 26'h2000000;
        bounded_mask = '0;
        for (integer byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1)
            if (byte_lane < 2 * int'(p_req_len[pick]))
                bounded_mask[byte_lane] = (p_req_mask[pick] >> byte_lane) & 1'b1;
    end

    assign b_req_valid = !rst && state == ISSUE;
    // Allow completion on the same edge as backend request acceptance.
    assign b_rsp_ready = !rst && ((state == WAIT_RESULT) ||
                                 (state == ISSUE && b_req_ready));

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            owner <= '0;
            fair_next <= '0;
            urgent_next <= '0;
            urgent_count <= '0;
            p_rsp_valid <= '0;
            p_rsp_error <= '0;
            p_rsp_rdata <= '0;
            b_req_write <= 1'b0;
            b_req_addr <= '0;
            b_req_len <= '0;
            b_req_wdata <= '0;
            b_req_mask <= '0;
            protocol_fault <= 1'b0;
        end else begin
            p_rsp_valid <= p_rsp_valid & ~p_rsp_ready;
            if (b_rsp_valid && !b_rsp_ready) protocol_fault <= 1'b1;
            case (state)
                IDLE: if (fair_found) begin
                    if (expedited) begin
                        urgent_next <= successor(pick);
                        urgent_count <= urgent_count + 1'b1;
                    end else begin
                        fair_next <= successor(pick);
                        urgent_count <= '0;
                    end
                    if (bad_request || (p_req_write[pick] && bounded_mask == 0)) begin
                        p_rsp_valid[pick] <= 1'b1;
                        p_rsp_error[pick] <= bad_request;
                        p_rsp_rdata[pick] <= '0;
                    end else begin
                        owner <= pick;
                        b_req_write <= p_req_write[pick];
                        b_req_addr <= p_req_addr[pick];
                        b_req_len <= p_req_len[pick];
                        b_req_wdata <= p_req_wdata[pick];
                        b_req_mask <= bounded_mask;
                        state <= ISSUE;
                    end
                end
                ISSUE: if (b_req_ready) state <= WAIT_RESULT;
                WAIT_RESULT: ;
                default: state <= IDLE;
            endcase
            // Later assignments deliberately win over response consumption and
            // ISSUE -> WAIT_RESULT when completion is immediate.
            if (b_rsp_valid && b_rsp_ready) begin
                p_rsp_valid[owner] <= 1'b1;
                p_rsp_error[owner] <= b_rsp_error;
                p_rsp_rdata[owner] <= b_req_write ? 128'b0 : b_rsp_rdata;
                state <= IDLE;
            end
        end
    end
endmodule
`default_nettype wire
