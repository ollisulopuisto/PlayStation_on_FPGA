`timescale 1ns/1ps
module tb_cache_boundaries;
  reg clk=0, reset=0;
  always #5 clk=~clk;
  reg [20:0] ia=0;
  reg [127:0] id=0;
  reg ir=0, iw=0, il=0, ic=0, ica=0;
  wire ih, ib;
  wire [31:0] iq;
  Cache_IR ci(.m_clock(clk),.p_reset(reset),.adrs(ia),.din(id),
    .read(ir),.write(iw),.write_line(il),.clear(ic),.clear_all(ica),
    .hit(ih),.doing(ib),.dout(iq));
  reg [18:0] ta=0;
  reg tr=0, disabled=0, ma=0;
  reg [63:0] md=0;
  wire th,tb,ack,mr;
  wire [15:0] tq;
  wire [18:0] maddr;
  wire [2:0] burst;
  Cache_Texture ct(.m_clock(clk),.p_reset(reset),.adrs(ta),.read(tr),
    .sw_texcache_off(disabled),.vram_ack(ma),.vram_dout(md),
    .hit(th),.doing(tb),.ack(ack),.dout(tq),.vram_read_req(mr),
    .vram_adrs(maddr),.vram_burst(burst));
  integer checks=0;

  function automatic [31:0] iwant(input [20:0] address);
    iwant=32'h6da42b19 ^ address;
  endfunction
  function automatic [15:0] twant(input [18:0] address);
    twant=16'hc317 ^ address[15:0] ^ {13'b0,address[18:16]};
  endfunction
  task automatic wait_clear;
    integer n;
    begin
      n=0;
      while(ib!==0 && n<270) begin @(negedge clk); n=n+1; end
      if(ib!==0) $fatal(1,"IR whole clear exceeded bound");
    end
  endtask
  task automatic wait_tex_clear;
    integer n;
    begin
      n=0;
      while(tb!==0 && n<270) begin @(negedge clk); n=n+1; end
      if(tb!==0) $fatal(1,"texture whole clear exceeded bound");
    end
  endtask
  task automatic iprobe(input [20:0] address,input bit expected_hit);
    begin
      @(negedge clk); ia=address; ir=1;
      @(posedge clk); #1;
      if(ih!==expected_hit) $fatal(1,"IR boundary hit address=%h expected=%b actual=%b",address,expected_hit,ih);
      if(expected_hit && iq!==iwant(address)) $fatal(1,"IR boundary data address=%h expected=%h actual=%h",address,iwant(address),iq);
      checks=checks+1;
      @(negedge clk); ir=0;
    end
  endtask
  task automatic tmiss(input [18:0] address,input integer latency);
    reg [63:0] response;
    integer k;
    begin
      @(negedge clk); ta=address; tr=1;
      @(posedge clk); #1; tr=0; #1;
      if(th!==0 || ack!==0 || mr!==1 || maddr!==address || burst!==(4-{1'b0,address[1:0]}))
        $fatal(1,"texture index-255 miss setup addr=%h hit=%b ack=%b req=%b ext=%h burst=%d",address,th,ack,mr,maddr,burst);
      for(k=0;k<4;k=k+1) response[k*16+:16]=twant(address+k);
      // Keep the response pending well beyond the short stalls in the base cache bench.
      for(k=0;k<latency;k=k+1) begin
        @(negedge clk);
        if(mr!==1 || maddr!==address || burst!==(4-{1'b0,address[1:0]}))
          $fatal(1,"texture request changed during long stall cycle=%0d",k);
      end
      md=response; ma=1; #1;
      if(ack!==1 || th!==1 || tq!==twant(address))
        $fatal(1,"texture long refill mismatch addr=%h ack=%b hit=%b data=%h expected=%h",address,ack,th,tq,twant(address));
      checks=checks+1;
      @(negedge clk); ma=0;
      @(negedge clk);
      if(tb!==0 || mr!==0) $fatal(1,"texture long transaction did not finish");
    end
  endtask
  task automatic thit(input [18:0] address);
    begin
      @(negedge clk); ta=address; tr=1;
      @(posedge clk); #1; tr=0;
      if(th!==1 || ack!==1 || mr!==0 || tq!==twant(address))
        $fatal(1,"texture index-255 hit addr=%h hit=%b ack=%b req=%b data=%h expected=%h",address,th,ack,mr,tq,twant(address));
      checks=checks+1;
      @(negedge clk);
    end
  endtask
  task automatic clear_ir_all;
    begin
      @(negedge clk); ica=1;
      @(negedge clk); ica=0;
      wait_clear();
    end
  endtask

  reg [20:0] base, other;
  reg [18:0] tex;
  integer n;
  initial begin
    // Initial reset plus the texture cache's automatic 256-line initialization.
    @(negedge clk); reset=1;
    repeat(2) @(negedge clk);
    reset=0; ica=1;
    @(negedge clk); ica=0;
    wait_clear(); wait_tex_clear();

    // One word writes preserve the tag and leave other words invalid. The same tag
    // is used throughout because single-word write replacement behavior is undefined.
    base=21'h012340; other=base+4;
    @(negedge clk); ia=base; id[31:0]=iwant(base); iw=1;
    @(negedge clk); iw=0;
    iprobe(base,1); iprobe(other,0);
    // Targeted clear invalidates only the selected offset under the same tag.
    @(negedge clk); ia=base; ic=1;
    @(negedge clk); ic=0;
    iprobe(base,0);

    // Several full clears run back-to-back without reset; each must invalidate a
    // previously written word and complete within the source's 256-cycle sweep.
    for(n=0;n<3;n=n+1) begin
      @(negedge clk); ia=base; id[31:0]=iwant(base); iw=1;
      @(negedge clk); iw=0;
      iprobe(base,1);
      clear_ir_all();
      iprobe(base,0);
    end

    // Texture index 255: address bits [9:2] select the final line.
    tex=19'h001ff<<2;
    tmiss(tex+2,40);
    thit(tex+2);
    $display("PASS cache boundaries checks=%0d",checks);
    $finish;
  end
  initial begin #1000000; $fatal(1,"cache boundary timeout"); end
endmodule
