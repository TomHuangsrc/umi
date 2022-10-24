
module testbench();

   localparam N=4;
   localparam PERIOD_CLK = 10;

   reg [N-1:0] umi_in_valid;
   reg 	       nreset;
   reg 	       clk;

  // reset initialization
   initial
     begin
	#(1)
	nreset   = 1'b0;
	clk      = 1'b0;
	#(PERIOD_CLK * 10)
	nreset   = 1'b1;
     end // initial begin

   // clocks
   always
     #(PERIOD_CLK/2) clk = ~clk;


   always @ (posedge clk or negedge nreset)
     if(~nreset)
       umi_in_valid <='b0;
     else
       umi_in_valid <=umi_in_valid+1'b1;

     initial
       begin
          $dumpfile("waveform.vcd");
          $dumpvars();
	  #500
          $finish;
       end

   /*AUTOWIRE*/
   // Beginning of automatic wires (for undeclared instantiated-module outputs)
   wire [N-1:0]		umi_in_ready;		// From umi_arbiter of umi_arbiter.v
   wire [N-1:0]		umi_out_valid;		// From umi_arbiter of umi_arbiter.v
   // End of automatics

   umi_arbiter #(.N(N))
   umi_arbiter  (.mode			(2'b00),
		 .mask			({(N){1'b0}}),
		 /*AUTOINST*/
		 // Outputs
		 .umi_in_ready		(umi_in_ready[N-1:0]),
		 .umi_out_valid		(umi_out_valid[N-1:0]),
		 // Inputs
		 .clk			(clk),
		 .nreset		(nreset),
		 .umi_in_valid		(umi_in_valid[N-1:0]));


endmodule
// Local Variables:
// verilog-library-directories:("." "../rtl")
// End:
