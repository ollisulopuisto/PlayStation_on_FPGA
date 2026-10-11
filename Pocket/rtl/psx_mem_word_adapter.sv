// SPDX-License-Identifier: MIT
// Convert 1..8 packed halfwords into 1..5 aligned 32-bit controller commands.
// No CDC or SDRAM timing here. A controller write handshake MUST guarantee
// ordering/visibility to subsequent reads. See docs/POCKET_MEMORY_CONTRACT.md.
`default_nettype none

module psx_mem_word_adapter #(
    parameter integer TAGW = 3
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             req_valid,
    output wire             req_ready,
    input  wire             req_write,
    input  wire [24:0]       req_addr,
    input  wire [3:0]        req_len,
    input  wire [127:0]      req_wdata,
    input  wire [15:0]       req_mask,
    output wire             rsp_valid,
    input  wire             rsp_ready,
    output wire [127:0]      rsp_rdata,
    output logic            rsp_error,

    output wire             m_req_valid,
    input  wire             m_req_ready,
    output wire             m_req_we,
    output wire [23:0]       m_req_addr,
    output wire [31:0]       m_req_wdata,
    output wire [3:0]        m_req_be,
    output wire [TAGW-1:0]   m_req_tag,
    // Unbackpressured controller read result, as in MIRLO's sdr_ctrl.
    input  wire             m_rd_valid,
    input  wire [31:0]       m_rd_data,
    input  wire [TAGW-1:0]   m_rd_tag,
    output logic            protocol_fault
);
    typedef enum logic [1:0] {IDLE, SEND_WORD, WAIT_READ, RESPOND} state_t;
    state_t state;
    logic write_q, odd_q;
    logic [23:0] address_q;
    logic [2:0] word_index, last_word;
    logic [159:0] write_shift, read_words;
    logic [19:0] mask_shift;
    logic [127:0] read_mask;
    wire [25:0] end_address = {1'b0, req_addr} + 26'(req_len);
    wire invalid_request = req_len == 0 || req_len > 8 ||
                           end_address > 26'h2000000;
    logic [15:0] bounded_mask;
    logic [127:0] incoming_read_mask;
    // Fixed halfword shifts keep the alignment mux small.
    wire [127:0] packed_read = odd_q ? read_words[143:16] : read_words[127:0];
    wire expecting_read = state == WAIT_READ ||
                          (state == SEND_WORD && !write_q && m_req_ready);

    always_comb begin
        bounded_mask = '0;
        incoming_read_mask = '0;
        for (integer b = 0; b < 16; b = b + 1) begin
            if (b < 2 * int'(req_len)) begin
                bounded_mask[b] = req_mask[b];
                incoming_read_mask[b*8 +: 8] = 8'hff;
            end
        end
    end

    assign req_ready = !rst && state == IDLE;
    assign rsp_valid = !rst && state == RESPOND;
    assign rsp_rdata = packed_read & read_mask;
    assign m_req_valid = !rst && state == SEND_WORD &&
                         (!write_q || mask_shift[3:0] != 0);
    assign m_req_we = write_q;
    assign m_req_addr = address_q;
    assign m_req_wdata = write_shift[31:0];
    assign m_req_be = write_q ? mask_shift[3:0] : 4'b0000;
    assign m_req_tag = '0; // Only one read outstanding in this adapter.

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            write_q <= 1'b0;
            odd_q <= 1'b0;
            address_q <= '0;
            word_index <= '0;
            last_word <= '0;
            write_shift <= '0;
            read_words <= '0;
            mask_shift <= '0;
            read_mask <= '0;
            rsp_error <= 1'b0;
            protocol_fault <= 1'b0;
        end else begin
            if (m_rd_valid && (!expecting_read || m_rd_tag != 0))
                protocol_fault <= 1'b1;
            case (state)
                IDLE: if (req_valid) begin
                    write_q <= req_write;
                    odd_q <= req_addr[0];
                    address_q <= req_addr[24:1];
                    word_index <= '0;
                    // ceil((len + odd)/2) - 1, evaluated before narrowing.
                    last_word <= 3'((int'(req_len) + int'(req_addr[0]) - 1) >> 1);
                    write_shift <= req_addr[0] ? {16'b0, req_wdata, 16'b0} :
                                                               {32'b0, req_wdata};
                    mask_shift <= req_addr[0] ? {2'b0, bounded_mask, 2'b0} :
                                                               {4'b0, bounded_mask};
                    read_mask <= incoming_read_mask;
                    read_words <= '0;
                    rsp_error <= invalid_request;
                    if (invalid_request || (req_write && bounded_mask == 0))
                        state <= RESPOND;
                    else state <= SEND_WORD;
                end
                SEND_WORD: begin
                    if (write_q) begin
                        if (mask_shift[3:0] == 0 || m_req_ready) begin
                            if (word_index == last_word) state <= RESPOND;
                            else begin
                                word_index <= word_index + 1'b1;
                                address_q <= address_q + 1'b1;
                                write_shift <= {32'b0, write_shift[159:32]};
                                mask_shift <= {4'b0, mask_shift[19:4]};
                            end
                        end
                    end else if (m_req_ready) state <= WAIT_READ;
                end
                WAIT_READ: ;
                RESPOND: if (rsp_ready) state <= IDLE;
                default: state <= IDLE;
            endcase
            // Includes a read result coincident with command acceptance.
            // Wrong-tag results are flagged and ignored, not reassigned.
            if (m_rd_valid && expecting_read && m_rd_tag == 0) begin
                read_words[int'(word_index)*32 +: 32] <= m_rd_data;
                if (word_index == last_word) state <= RESPOND;
                else begin
                    word_index <= word_index + 1'b1;
                    address_q <= address_q + 1'b1;
                    state <= SEND_WORD;
                end
            end
        end
    end
endmodule
`default_nettype wire
