// SPDX-License-Identifier: MIT
// Isolated P04 frontend: burst arbitration plus 32-bit controller adaptation.
// All ports share clk. Does not include the SDRAM controller, PHY or CDC.
// Not instantiated by Pocket/core_top.v; integration is still outstanding.
`default_nettype none

module psx_mem_frontend #(
    parameter integer N = 6,
    parameter integer URGENT_MAX = 4,
    parameter integer TAGW = 3
) (
    input  wire                      clk,
    input  wire                      rst,
    input  wire [N-1:0]               p_req_valid,
    output wire [N-1:0]               p_req_ready,
    input  wire [N-1:0]               p_req_write,
    input  wire [N-1:0][24:0]         p_req_addr,
    input  wire [N-1:0][3:0]          p_req_len,
    input  wire [N-1:0][127:0]        p_req_wdata,
    input  wire [N-1:0][15:0]         p_req_mask,
    input  wire [N-1:0]               p_req_urgent,
    output wire [N-1:0]               p_rsp_valid,
    input  wire [N-1:0]               p_rsp_ready,
    output wire [N-1:0][127:0]        p_rsp_rdata,
    output wire [N-1:0]               p_rsp_error,

    output wire                      m_req_valid,
    input  wire                      m_req_ready,
    output wire                      m_req_we,
    output wire [23:0]               m_req_addr,
    output wire [31:0]               m_req_wdata,
    output wire [3:0]                m_req_be,
    output wire [TAGW-1:0]           m_req_tag,
    input  wire                      m_rd_valid,
    input  wire [31:0]               m_rd_data,
    input  wire [TAGW-1:0]           m_rd_tag,
    // [0]: fabric response protocol; [1]: adapter read/tag protocol.
    output wire [1:0]                protocol_fault
);
    wire b_req_valid, b_req_ready, b_req_write;
    wire [24:0] b_req_addr;
    wire [3:0] b_req_len;
    wire [127:0] b_req_wdata;
    wire [15:0] b_req_mask;
    wire b_rsp_valid, b_rsp_ready, b_rsp_error;
    wire [127:0] b_rsp_rdata;

    psx_mem_fabric #(.N(N), .URGENT_MAX(URGENT_MAX)) fabric (
        .clk(clk), .rst(rst),
        .p_req_valid(p_req_valid), .p_req_ready(p_req_ready),
        .p_req_write(p_req_write), .p_req_addr(p_req_addr),
        .p_req_len(p_req_len), .p_req_wdata(p_req_wdata),
        .p_req_mask(p_req_mask), .p_req_urgent(p_req_urgent),
        .p_rsp_valid(p_rsp_valid), .p_rsp_ready(p_rsp_ready),
        .p_rsp_rdata(p_rsp_rdata), .p_rsp_error(p_rsp_error),
        .b_req_valid(b_req_valid), .b_req_ready(b_req_ready),
        .b_req_write(b_req_write), .b_req_addr(b_req_addr),
        .b_req_len(b_req_len), .b_req_wdata(b_req_wdata), .b_req_mask(b_req_mask),
        .b_rsp_valid(b_rsp_valid), .b_rsp_ready(b_rsp_ready),
        .b_rsp_rdata(b_rsp_rdata), .b_rsp_error(b_rsp_error),
        .protocol_fault(protocol_fault[0])
    );

    psx_mem_word_adapter #(.TAGW(TAGW)) adapter (
        .clk(clk), .rst(rst),
        .req_valid(b_req_valid), .req_ready(b_req_ready),
        .req_write(b_req_write), .req_addr(b_req_addr),
        .req_len(b_req_len), .req_wdata(b_req_wdata), .req_mask(b_req_mask),
        .rsp_valid(b_rsp_valid), .rsp_ready(b_rsp_ready),
        .rsp_rdata(b_rsp_rdata), .rsp_error(b_rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready),
        .m_req_we(m_req_we), .m_req_addr(m_req_addr),
        .m_req_wdata(m_req_wdata), .m_req_be(m_req_be), .m_req_tag(m_req_tag),
        .m_rd_valid(m_rd_valid), .m_rd_data(m_rd_data), .m_rd_tag(m_rd_tag),
        .protocol_fault(protocol_fault[1])
    );
endmodule
`default_nettype wire
