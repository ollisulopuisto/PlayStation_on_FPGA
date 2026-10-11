// SPDX-License-Identifier: MIT
// Self-checking bench for psx_mem_frontend (fabric + word adapter).
// Reference model: 4096-halfword memory indexed {addr[24], addr[10:0]}; generated
// addresses stay in two non-aliasing regions (low, and the top of the 64 MiB aperture).
// Run: see docs/POCKET_IMPLEMENTATION.md. +seed=<n>, +cycles=<n> optional.
`timescale 1ns/1ps
module tb_psx_mem;
    parameter integer N = 6;
    parameter integer URGENT_MAX = 4;
    parameter integer TAGW = 3;
    integer CYCLES = 6000;           // per phase

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    // ---- DUT ports
    reg  [N-1:0]          req_valid = 0;
    wire [N-1:0]          req_ready;
    reg  [N-1:0]          req_write = 0;
    reg  [N-1:0][24:0]    req_addr = 0;
    reg  [N-1:0][3:0]     req_len = 0;
    reg  [N-1:0][127:0]   req_wdata = 0;
    reg  [N-1:0][15:0]    req_mask = 0;
    reg  [N-1:0]          req_urgent = 0;
    wire [N-1:0]          rsp_valid;
    reg  [N-1:0]          rsp_ready = 0;
    wire [N-1:0][127:0]   rsp_rdata;
    wire [N-1:0]          rsp_error;
    wire                  m_req_valid, m_req_we;
    reg                   m_req_ready = 0;
    wire [23:0]           m_req_addr;
    wire [31:0]           m_req_wdata;
    wire [3:0]            m_req_be;
    wire [TAGW-1:0]       m_req_tag;
    wire                  m_rd_valid;
    wire [31:0]           m_rd_data;
    wire [TAGW-1:0]       m_rd_tag;
    wire [1:0]            protocol_fault;

    psx_mem_frontend #(.N(N), .URGENT_MAX(URGENT_MAX), .TAGW(TAGW)) dut (
        .clk(clk), .rst(rst),
        .p_req_valid(req_valid), .p_req_ready(req_ready), .p_req_write(req_write),
        .p_req_addr(req_addr), .p_req_len(req_len), .p_req_wdata(req_wdata),
        .p_req_mask(req_mask), .p_req_urgent(req_urgent),
        .p_rsp_valid(rsp_valid), .p_rsp_ready(rsp_ready),
        .p_rsp_rdata(rsp_rdata), .p_rsp_error(rsp_error),
        .m_req_valid(m_req_valid), .m_req_ready(m_req_ready), .m_req_we(m_req_we),
        .m_req_addr(m_req_addr), .m_req_wdata(m_req_wdata), .m_req_be(m_req_be),
        .m_req_tag(m_req_tag), .m_rd_valid(m_rd_valid), .m_rd_data(m_rd_data),
        .m_rd_tag(m_rd_tag), .protocol_fault(protocol_fault));

    // ---- deterministic RNG
    reg [31:0] rng = 32'h1badf00d;
    function automatic [31:0] rnd(input integer dummy);
        begin
            rng = rng ^ (rng << 13);
            rng = rng ^ (rng >> 17);
            rng = rng ^ (rng << 5);
            rnd = rng;
        end
    endfunction

    // ---- phase knobs
    integer rdy_pct = 100, lat_max = 0, gap_max = 0, urg_pct = 0;
    integer rsp_pct [0:N-1];
    reg [N-1:0] urg_enable;
    reg run_traffic = 0, inject_rd = 0;
    reg [TAGW-1:0] inject_tag = 0;

    // ---- backend model (word memory, random ready and latency)
    reg [31:0] mem32 [0:2047];
    wire [10:0] w_idx = {m_req_addr[23], m_req_addr[9:0]};
    reg        pend_valid = 0;
    integer    pend_cnt = 0;
    reg [31:0] pend_data;
    reg [TAGW-1:0] pend_tag;
    integer    next_lat = 0;
    wire accept_rd = m_req_valid && m_req_ready && !m_req_we;
    wire imm_rd = accept_rd && (next_lat == 0);
    assign m_rd_valid = inject_rd || (pend_valid && pend_cnt == 0) || imm_rd;
    assign m_rd_data  = inject_rd ? 32'hdeadbeef : imm_rd ? mem32[w_idx] : pend_data;
    assign m_rd_tag   = inject_rd ? inject_tag : imm_rd ? m_req_tag : pend_tag;

    // ---- reference / scoreboard
    reg [15:0] ref_mem [0:4095];
    reg        exp_valid [0:N-1];
    reg        exp_err   [0:N-1];
    reg [127:0] exp_rdata [0:N-1];
    reg        hold_chk  [0:N-1];
    reg [127:0] hold_data [0:N-1];
    reg        hold_err  [0:N-1];
    integer    gap [0:N-1];
    integer    wait_cnt [0:N-1];
    integer    max_wait = 0, total_acc = 0, total_rsp = 0, errors = 0;
    integer    cov_len [1:8], cov_odd [0:1], cov_err = 0, cov_zero = 0, cov_swap = 0,
               cov_imm = 0, cov_stall = 0, cov_exp = 0, cov_top = 0, cov_rst = 0;
    integer    per_client_rsp [0:N-1];
    reg        prev_mv = 0, prev_mready = 0, prev_mwe;
    reg [23:0] prev_maddr; reg [31:0] prev_mwd; reg [3:0] prev_mbe;
    reg        prev_rst = 1;

    function automatic [11:0] hidx(input [24:0] a);
        hidx = {a[24], a[10:0]};
    endfunction

    task automatic fail(input [511:0] msg, input integer c);
        begin
            errors = errors + 1;
            if (errors < 20) $display("FAIL t=%0t client=%0d: %0s", $time, c, msg);
        end
    endtask

    task automatic sync_ref;
        integer i;
        begin
            for (i = 0; i < 4096; i = i + 1)
                ref_mem[i] = mem32[i >> 1] >> ((i & 1) * 16);
        end
    endtask

    task automatic gen_req(input integer c);
        integer kind, len, i;
        reg [24:0] a;
        reg [15:0] m;
        reg [127:0] d;
        begin
            kind = rnd(0) % 100;
            if (kind < 6) begin
                len = (rnd(0) % 2) ? 0 : 9 + rnd(0) % 7; a = rnd(0) % 2000;
            end else if (kind < 12) begin
                len = 2 + rnd(0) % 7; a = 25'h1FFFFFF;
            end else if (kind < 40) begin
                len = 1 + rnd(0) % 8; a = 26'h2000000 - len - rnd(0) % 16;
            end else begin
                len = 1 + rnd(0) % 8; a = rnd(0) % 2000;
            end
            m = rnd(0);
            case (rnd(0) % 10)
                0: m = 16'hffff;
                1: m = 16'h0000;
                2: m = ~((16'h1 << (2 * len)) - 16'h1);   // only bits outside length
                default: ;
            endcase
            d = {rnd(0), rnd(0), rnd(0), rnd(0)};
            req_valid[c]  <= 1'b1;
            req_write[c]  <= (rnd(0) % 100) < 45;
            req_addr[c]   <= a;
            req_len[c]    <= len;
            req_wdata[c]  <= d;
            req_mask[c]   <= m;
            req_urgent[c] <= urg_enable[c] && ((rnd(0) % 100) < urg_pct);
        end
    endtask

    // ---- one process: sample pre-edge values, update model, drive with NBAs
    integer c, i, j, acc_cnt, len_i;
    reg err_i;
    reg [24:0] a_i;
    reg [31:0] tmp;
    reg elig, wr_i;
    reg [15:0] m_i;
    reg [127:0] d_i;
    always @(posedge clk) begin
        // backend model ------------------------------------------------
        if (rst) begin
            pend_valid <= 0;
            m_req_ready <= 0;
            sync_ref;
        end else begin
            m_req_ready <= (rnd(0) % 100) < rdy_pct;
            if (pend_valid) begin
                if (pend_cnt == 0) pend_valid <= 0; else pend_cnt <= pend_cnt - 1;
            end
            if (accept_rd && pend_valid && pend_cnt != 0) fail("backend: overlapping reads", -1);
            if (m_req_valid && m_req_ready) begin
                if (m_req_addr[22:10] != {13{m_req_addr[23]}}) fail("addr out of test regions", -1);
                if (m_req_we) begin
                    if (m_req_be == 0) fail("write command with zero byte enable", -1);
                    tmp = mem32[w_idx];
                    for (j = 0; j < 4; j = j + 1)
                        if (m_req_be[j]) tmp[8*j +: 8] = m_req_wdata[8*j +: 8];
                    mem32[w_idx] <= tmp;
                end else if (next_lat != 0) begin
                    pend_valid <= 1; pend_cnt <= next_lat - 1;
                    pend_data <= mem32[w_idx]; pend_tag <= m_req_tag;
                end else cov_imm = cov_imm + 1;
                next_lat = (lat_max == 0) ? 0 : rnd(0) % (lat_max + 1);
            end
            if (m_req_valid && !m_req_ready) cov_stall = cov_stall + 1;
            if (prev_mv && !prev_mready && !prev_rst) begin   // stability under backpressure
                if (!m_req_valid || m_req_we !== prev_mwe || m_req_addr !== prev_maddr ||
                    m_req_be !== prev_mbe || (prev_mwe && prev_mbe != 0 && m_req_wdata !== prev_mwd))
                    fail("controller request not held stable", -1);
            end
        end
        prev_mv = m_req_valid; prev_mready = m_req_ready; prev_mwe = m_req_we;
        prev_maddr = m_req_addr; prev_mwd = m_req_wdata; prev_mbe = m_req_be;

        // clients ------------------------------------------------------
        if (rst) begin
            if (!prev_rst) cov_rst = cov_rst + 1;
            req_valid <= 0;
            for (c = 0; c < N; c = c + 1) begin
                exp_valid[c] = 0; hold_chk[c] = 0; gap[c] = 0; wait_cnt[c] = 0;
            end
            if (prev_rst && (rsp_valid != 0 || m_req_valid || req_ready != 0))
                fail("outputs active during reset", -1);
            if (req_ready != 0) fail("request accepted during reset", -1);
        end else begin
            if ($countones(req_ready) > 1) fail("multiple grants", -1);
            // responses first (consume frees slot for same-edge acceptance)
            for (c = 0; c < N; c = c + 1) begin
                if (hold_chk[c] && rsp_valid[c] && (rsp_rdata[c] !== hold_data[c] || rsp_error[c] !== hold_err[c]))
                    fail("response changed while stalled", c);
                if (hold_chk[c] && !rsp_valid[c]) fail("response dropped before consumed", c);
                hold_chk[c] = rsp_valid[c] && !rsp_ready[c];
                hold_data[c] = rsp_rdata[c]; hold_err[c] = rsp_error[c];
                if (rsp_valid[c] && !exp_valid[c]) fail("spurious/duplicate response", c);
                if (rsp_valid[c] && rsp_ready[c]) begin
                    if (exp_valid[c]) begin
                        if (rsp_error[c] !== exp_err[c]) fail("error flag mismatch", c);
                        else if (rsp_rdata[c] !== exp_rdata[c]) begin
                            fail("read data mismatch", c);
                            if (errors < 5) $display("  got %h\n  exp %h", rsp_rdata[c], exp_rdata[c]);
                        end
                    end
                    exp_valid[c] = 0;
                    total_rsp = total_rsp + 1;
                    per_client_rsp[c] = per_client_rsp[c] + 1;
                end
            end
            // acceptances and fairness
            acc_cnt = -1;
            for (c = 0; c < N; c = c + 1) if (req_ready[c]) begin
                acc_cnt = c;
                if (!req_valid[c]) fail("grant without request", c);
            end
            for (c = 0; c < N; c = c + 1) begin
                elig = req_valid[c] && (!rsp_valid[c] || rsp_ready[c]);
                if (!elig || c == acc_cnt) wait_cnt[c] = 0;
                else if (acc_cnt >= 0 && acc_cnt != c) begin
                    wait_cnt[c] = wait_cnt[c] + 1;
                    if (wait_cnt[c] > max_wait) max_wait = wait_cnt[c];
                    if (wait_cnt[c] > N * (URGENT_MAX + 1) - 1) fail("starvation bound exceeded", c);
                end
            end
            if (acc_cnt >= 0) begin
                c = acc_cnt;
                if (exp_valid[c]) fail("accepted while response pending", c);
                if (rsp_valid[c] && rsp_ready[c]) cov_swap = cov_swap + 1;
                len_i = req_len[c]; a_i = req_addr[c];
                m_i = req_mask[c]; d_i = req_wdata[c]; wr_i = req_write[c];
                err_i = (len_i == 0) || (len_i > 8) || (({1'b0, a_i} + len_i) > 26'h2000000);
                exp_valid[c] = 1; exp_err[c] = err_i; exp_rdata[c] = 0;
                total_acc = total_acc + 1;
                if (err_i) cov_err = cov_err + 1;
                else begin
                    cov_len[len_i] = cov_len[len_i] + 1; cov_odd[a_i[0]] = cov_odd[a_i[0]] + 1;
                    if (a_i[24]) cov_top = cov_top + 1;
                    if (wr_i) begin
                        if ((m_i & ((16'h1 << (2 * len_i)) - 16'h1)) == 0) cov_zero = cov_zero + 1;
                        for (i = 0; i < len_i; i = i + 1) begin
                            if (m_i[2*i])   ref_mem[hidx(a_i + i)][7:0]  = d_i[16*i +: 8];
                            if (m_i[2*i+1]) ref_mem[hidx(a_i + i)][15:8] = d_i[16*i+8 +: 8];
                        end
                    end else
                        for (i = 0; i < len_i; i = i + 1)
                            exp_rdata[c][16*i +: 16] = ref_mem[hidx(a_i + i)];
                end
                req_valid[c] <= 1'b0;
                gap[c] = (gap_max == 0) ? 0 : rnd(0) % (gap_max + 1);
            end
            // request stability (driver contract) and new requests
            for (c = 0; c < N; c = c + 1) begin
                if (!req_valid[c] || c == acc_cnt) begin
                    if (gap[c] > 0) gap[c] = gap[c] - 1;
                    else if (run_traffic) gen_req(c);
                end
            end
        end
        for (c = 0; c < N; c = c + 1)
            rsp_ready[c] <= (rnd(0) % 100) < rsp_pct[c];
        prev_rst = rst;
    end

    // ---- phases
    task automatic set_phase(input integer rdy, input integer lat, input integer gp,
                             input integer urg, input integer rsp, input [N-1:0] urgmask);
        integer k;
        begin
            rdy_pct = rdy; lat_max = lat; gap_max = gp; urg_pct = urg; urg_enable = urgmask;
            for (k = 0; k < N; k = k + 1) rsp_pct[k] = rsp;
        end
    endtask

    task automatic run_cycles(input integer n, input integer reset_storm);
        integer k, r;
        begin
            run_traffic = 1;
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                if (reset_storm != 0 && (rnd(0) % 150) == 0) begin
                    rst <= 1;
                    r = 1 + rnd(0) % 4;
                    repeat (r) @(posedge clk);
                    rst <= 0;
                end
            end
            run_traffic = 0;
        end
    endtask

    function automatic any_exp(input integer dummy);
        integer q;
        begin
            any_exp = 0;
            for (q = 0; q < N; q = q + 1) if (exp_valid[q]) any_exp = 1;
        end
    endfunction
    task automatic drain;
        integer k, t;
        begin
            set_phase(100, 0, 0, 0, 100, 0);
            rdy_pct = 70; lat_max = 2;
            repeat (2) @(posedge clk);   // run_traffic is cleared racing the driver's last edge
            t = 0;
            while ((req_valid != 0 || rsp_valid != 0 || m_req_valid || pend_valid || any_exp(0)) && t < 2000) begin
                @(posedge clk); t = t + 1;
            end
            repeat (3) @(posedge clk);
            if (t >= 2000) fail("drain timeout (hang)", -1);
            for (k = 0; k < N; k = k + 1) if (exp_valid[k]) fail("response missing after drain", k);
        end
    endtask

    integer seed_arg, cyc_arg, k, ph;
    initial begin
        if ($value$plusargs("seed=%d", seed_arg)) rng = seed_arg * 32'h9e3779b1 + 1;
        if ($value$plusargs("cycles=%d", cyc_arg)) CYCLES = cyc_arg;
        for (k = 1; k <= 8; k = k + 1) cov_len[k] = 0;
        cov_odd[0] = 0; cov_odd[1] = 0;
        for (k = 0; k < N; k = k + 1) per_client_rsp[k] = 0;
        for (k = 0; k < 2048; k = k + 1) mem32[k] = rnd(0);
        sync_ref;
        urg_enable = 0;
        set_phase(100, 0, 0, 0, 100, 0);
        repeat (4) @(posedge clk);
        rst <= 0;
        @(posedge clk);

        // 1: full speed, no stalls
        set_phase(100, 0, 0, 0, 100, 0);          run_cycles(CYCLES, 0); drain;
        // 2: moderate stalls, variable latency
        set_phase(50, 3, 3, 0, 50, 0);            run_cycles(CYCLES, 0); drain;
        // 3: heavy backend stall, long latency, random urgency
        set_phase(20, 7, 1, 70, 30, {N{1'b1}});  run_cycles(CYCLES, 0); drain;
        // 4: one client never consumes its response (2%); others must progress
        set_phase(80, 2, 0, 0, 100, 0); rsp_pct[0] = 2;
        for (k = 0; k < N; k = k + 1) per_client_rsp[k] = 0;
        run_cycles(CYCLES, 0);
        if (N > 1) begin
            j = 0; for (k = 1; k < N; k = k + 1) j = j + per_client_rsp[k];
            $display("phase4: client0 rsp=%0d others rsp=%0d", per_client_rsp[0], j);
            if (j == 0) fail("other clients starved by stalled response", 0);
        end
        drain;
        // 5: urgent saturation, client 0 never urgent
        set_phase(100, 0, 0, 100, 100, {N{1'b1}} & ~1);  run_cycles(CYCLES, 0); drain;
        // 6: resets at random times under mixed load
        set_phase(60, 4, 1, 40, 60, {N{1'b1}});  run_cycles(CYCLES * 2, 1); drain;
        // 7: final fast mix after resets
        set_phase(100, 0, 0, 30, 100, {N{1'b1}}); run_cycles(CYCLES, 0); drain;

        if (protocol_fault !== 2'b00) fail("protocol_fault set during legal traffic", -1);
        if (total_acc !== total_rsp + 0 && cov_rst == 0) fail("accept/response count mismatch", -1);

        // fault injection: unexpected read result while idle must set sticky fault
        @(posedge clk); inject_rd <= 1; inject_tag <= 0; @(posedge clk); inject_rd <= 0;
        repeat (2) @(posedge clk);
        if (protocol_fault[1] !== 1'b1) fail("unexpected read result not flagged", -1);
        rst <= 1; repeat (2) @(posedge clk); rst <= 0; @(posedge clk);
        if (protocol_fault !== 2'b00) fail("reset did not clear protocol_fault", -1);

        $display("coverage: acc=%0d rsp=%0d err=%0d zero-eff-mask-writes=%0d top-region=%0d consume+accept=%0d",
                 total_acc, total_rsp, cov_err, cov_zero, cov_top, cov_swap);
        $display("  len1..8: %0d %0d %0d %0d %0d %0d %0d %0d  even=%0d odd=%0d imm-read=%0d backend-stall-cycles=%0d resets=%0d",
                 cov_len[1], cov_len[2], cov_len[3], cov_len[4], cov_len[5], cov_len[6], cov_len[7], cov_len[8],
                 cov_odd[0], cov_odd[1], cov_imm, cov_stall, cov_rst);
        $display("max selections waited by an eligible client: %0d (bound %0d)", max_wait, N * (URGENT_MAX + 1) - 1);
        if (errors == 0) $display("PASS"); else $display("FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #200000000;
        $display("FAIL: global timeout");
        $finish;
    end
endmodule
