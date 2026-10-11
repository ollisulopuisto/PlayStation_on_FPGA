`timescale 1ns/1ps
module tb_widths;
  reg [7:0] a=0,b=0;
  wire carry;
  wire [7:0] low,reversed,negative,shifted;
  wire [15:0] signed_a,signed_part,sign_constant;
  wire [3:0] choose;
  widths dut(.m_clock(1'b0),.p_reset(1'b0),.*);
  integer sum,sa,sp,rev,neg,shift,sel;
  initial begin
    for(integer i=0;i<256;i=i+1) begin
      for(integer j=0;j<256;j=j+1) begin
        a=i; b=j;
        sum=i+j;
        sa=(i<128)?i:i-256;
        sp=(i>>2)&31; if(sp>=16) sp=sp-32;
        rev=0;for(integer bitno=0;bitno<8;bitno=bitno+1) rev=rev*2+((i>>bitno)&1);
        neg=(256-i)&255;
        shift=(j>=8)?0:i/(1<<j);
        sel=(i%2)?9:((i&2)?5:0);
        #1;
        if(carry!==(sum>=256) || low!==sum[7:0] || reversed!==rev[7:0] ||
           signed_a!==sa[15:0] || signed_part!==sp[15:0] || negative!==neg[7:0] ||
           shifted!==shift[7:0] || sign_constant!==16'hfff8 || choose!==sel[3:0])
           $fatal(1,"width arithmetic mismatch a=%h b=%h",a,b);
      end
    end
    $display("PASS widths vectors=65536");$finish;
  end
endmodule
