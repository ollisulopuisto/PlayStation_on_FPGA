from pathlib import Path
import subprocess, sys, tempfile
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import sflc
root=Path(__file__).resolve().parents[3]
print(subprocess.run(['iverilog','-V'],capture_output=True,text=True).stdout,flush=True)
source=sflc.translate(root/'tools/sflc/tests/generators.sflp',register_banks=True)
print('GENERATED SOURCE\n'+source,flush=True)
bench="""`timescale 1ns/1ps
module tb;
reg clk=0, rst=0, load=0, wr=0;
reg [1:0] addr=0;
reg [7:0] a=0;
reg [3:0] bits=0;
wire [7:0] q0,q1,q2,q3,local_count;
wire [2:0] first; wire [3:0] mask;
p27 d(.p_reset(rst),.m_clock(clk),.load(load),.wr(wr),.addr(addr),.a(a),.bits(bits),
.q0(q0),.q1(q1),.q2(q2),.q3(q3),.first(first),.mask(mask),.local_count(local_count));
initial begin
#1;
$display("BEFORE RESET cells=%h %h %h %h outputs=%h %h %h %h",d.cells[0],d.cells[1],d.cells[2],d.cells[3],q0,q1,q2,q3);
rst=1; #1;
$display("RESET cells=%h %h %h %h outputs=%h %h %h %h",d.cells[0],d.cells[1],d.cells[2],d.cells[3],q0,q1,q2,q3);
rst=0; load=1; a=8'h20; #1; clk=1; #1;
$display("LOADED cells=%h %h %h %h outputs=%h %h %h %h",d.cells[0],d.cells[1],d.cells[2],d.cells[3],q0,q1,q2,q3);
$finish;
end
endmodule
"""
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)
 for label,rtl in [('original',source),('no_clocked_banks','\n'.join(x for x in source.splitlines() if not x.startswith('  always @(posedge m_clock) if'))),('wide_indices',source.replace("cells[1'd0]","cells[2'd0]").replace("cells[1'd1]","cells[2'd1]"))]:
  (p/'dut.sv').write_text(rtl); (p/'tb.sv').write_text(bench)
  subprocess.run(['iverilog','-g2012','-s','tb','-o',str(p/'out'),str(p/'dut.sv'),str(p/'tb.sv')],check=True)
  print('VARIANT '+label,flush=True)
  subprocess.run(['vvp',str(p/'out')],check=True)

fullbench=(root/'tools/sflc/tests/tb_generators.sv').read_text()
fullbench=fullbench.replace('check_outputs("initial asynchronous reset");', '$display("INITIAL clk=%b rst=%b load=%b wr=%b cells=%h %h %h %h q=%h %h %h %h",clk,reset,load,wr,dut.cells[0],dut.cells[1],dut.cells[2],dut.cells[3],q0,q1,q2,q3); check_outputs("initial asynchronous reset");')
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp)
 for label,tb in [('full',fullbench),('static_tasks',fullbench.replace('task automatic','task'))]:
  (p/'dut.sv').write_text(source); (p/'tb.sv').write_text(tb)
  subprocess.run(['iverilog','-g2012','-s','tb_generators','-o',str(p/'out'),str(p/'dut.sv'),str(p/'tb.sv')],check=True)
  print('FULL VARIANT '+label,flush=True)
  result=subprocess.run(['vvp',str(p/'out')])
  print('FULL EXIT '+str(result.returncode),flush=True)
