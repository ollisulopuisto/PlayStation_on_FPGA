`timescale 1ns/1ps
module tb_caches;
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

  function automatic [31:0] irword(input [20:0] address);
    irword=32'hc15a2300 ^ {11'b0,address};
  endfunction
  function automatic [15:0] texword(input [18:0] address);
    texword=16'hb531 ^ address[15:0] ^ {13'b0,address[18:16]};
  endfunction
  task automatic boot;
    @(negedge clk); ir=0; iw=0; il=0; ic=0; ica=0; tr=0; ma=0; reset=1;
    repeat(2) @(negedge clk);
    reset=0; ica=1;
    @(negedge clk); ica=0;
    // IR explicit clear and texture automatic reset clear both visit 256 lines.
    repeat(260) @(negedge clk);
    if(ib!==0 || tb!==0) $fatal(1,"cache initialization did not finish");
  endtask
  task automatic ifill(input [20:0] base,input integer off);
    @(negedge clk); ia=base+4*off;
    for(integer j=0;j<4;j=j+1) id[j*32+:32]=irword(base+4*(off+j));
    il=1;
    @(negedge clk); il=0;
  endtask
  task automatic iprobe(input [20:0] address,input bit expected_hit);
    @(negedge clk); ia=address; ir=1;
    @(posedge clk); #1;
    if(ih!==expected_hit) $fatal(1,"IR hit address=%h expected=%b actual=%b",address,expected_hit,ih);
    if(expected_hit && iq!==irword(address)) $fatal(1,"IR data address=%h expected=%h actual=%h",address,irword(address),iq);
    checks=checks+1;
    @(negedge clk); ir=0;
  endtask
  task automatic tfetch(input [18:0] address,input bit expected_hit);
    integer delay_count;
    reg [63:0] response;
    @(negedge clk); ta=address; tr=1;
    @(posedge clk); #1; tr=0; #1;
    if(expected_hit) begin
      if(th!==1 || ack!==1 || mr!==0 || tq!==texword(address))
        $fatal(1,"texture expected hit address=%h hit=%b ack=%b req=%b data=%h expected=%h",address,th,ack,mr,tq,texword(address));
      @(negedge clk);
    end else begin
      if(th!==0 || ack!==0) $fatal(1,"texture expected miss at %h",address);
      if(mr!==1 || maddr!==address || burst!==(4-{1'b0,address[1:0]}))
        $fatal(1,"texture miss request addr=%h actual=%h burst=%d",address,maddr,burst);
      for(integer j=0;j<4;j=j+1) response[j*16+:16]=texword(address+j);
      // Variable response latency; the held request must remain coherent.
      delay_count=2+address[3:0];
      repeat(delay_count) begin
        @(negedge clk);
        if(mr!==1 || maddr!==address || burst!==(4-{1'b0,address[1:0]}))
          $fatal(1,"texture request changed while waiting");
      end
      md=response; ma=1; #1;
      if(ack!==1 || th!==1 || tq!==texword(address)) $fatal(1,"texture refill response mismatch address=%h ack=%b hit=%b data=%h expected=%h",address,ack,th,tq,texword(address));
      @(negedge clk); ma=0;
    end
    // Let finish take effect and ensure no stale request survives.
    @(negedge clk);
    if(tb!==0 || mr!==0) $fatal(1,"texture transaction did not finish");
    checks=checks+1;
  endtask
  integer off, probe, index;
  reg [20:0] base;
  reg [18:0] tbase;
  initial begin
    boot();
    // All suffix offsets, every word, and independent lines including index 255.
    for(index=0;index<3;index=index+1) begin
      base=21'h012000 + (index==2 ? 255 : index)*16;
      for(off=0;off<4;off=off+1) begin
        ifill(base,off);
        for(probe=0;probe<4;probe=probe+1) iprobe(base+probe*4,probe>=off);
        // Same index, different tag must miss; refill invalidates the old tag.
        iprobe(base^21'h001000,0);
        ifill(base^21'h001000,off);
        for(probe=0;probe<4;probe=probe+1) begin
          iprobe(base+probe*4,0);
          iprobe((base^21'h001000)+probe*4,probe>=off);
        end
      end
    end
    // Explicit whole-cache clear invalidates previous data.
    @(negedge clk); ica=1;
    @(negedge clk); ica=0;
    repeat(260) @(negedge clk);
    for(probe=0;probe<4;probe=probe+1) iprobe((base^21'h001000)+probe*4,0);
    // Texture probing a missing prefix refills it; rebuild initial suffix
    // before each probe, so every valid/invalid expectation is independent.
    for(off=0;off<4;off=off+1) begin
      for(probe=0;probe<4;probe=probe+1) begin
        boot();
        tbase=19'h04800 + (off*4+probe)*4;
        tfetch(tbase+off,0);
        tfetch(tbase+probe,probe>=off);
        // Replacement aliases the index but must never reuse the old tag.
        tfetch((tbase^19'h00400)+off,0);
        tfetch((tbase^19'h00400)+off,1);
        tfetch(tbase+off,0);
      end
    end
    // Reset with a miss outstanding cancels the stage and re-clears RAM.
    @(negedge clk); ta=19'h1abcd; tr=1;
    @(negedge clk); tr=0;
    repeat(3) @(negedge clk);
    if(mr!==1) $fatal(1,"reset fixture did not reach outstanding miss");
    boot();
    tfetch(19'h1abcd,0);
    tfetch(19'h1abcd,1);
    $display("PASS caches checks=%0d",checks);
    $finish;
  end
  initial begin #2000000; $fatal(1,"cache timeout"); end
endmodule
