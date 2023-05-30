/*******************************************************************************
 * Function:  UMI NxN Crossbar
 * Author:    Andreas Olofsson
 * License:   (c) 2023 Zero ASIC Corporation
 *
 * Documentation:
 *
 * The input request vector is a concatenated onenot vectors of inputs
 * requesting outputs ports per the order below.
 *
 * [0]     = input 0   requesting output 0
 * [1]     = input 1   requesting output 0
 * [2]     = input 2   requesting output 0
 * [N-1]   = input N-1 requesting output 0
 * [N]     = input 0   requesting output 1
 * [N+1]   = input 1   requesting output 1
 * [N+2]   = input 2   requesting output 1
 * [2*N-1] = input N-1 requesting output 1
 * ...
 *
 ******************************************************************************/
module umi_crossbar
  #(parameter TARGET = "DEFAULT", // implementation target
    parameter DW = 256,           // UMI width
    parameter CW = 32,
    parameter AW = 64,
    parameter N = 2               // Total UMI ports
    )
   (// controls
    input              clk,
    input              nreset,
    input [1:0]        mode, // arbiter mode (0=fixed)
    input [N*N-1:0]    mask, // arbiter mode (0=fixed)
    // Incoming UMI
    input [N*N-1:0]    umi_in_request,
    input [N*CW-1:0]   umi_in_cmd,
    input [N*AW-1:0]   umi_in_dstaddr,
    input [N*AW-1:0]   umi_in_srcaddr,
    input [N*DW-1:0]   umi_in_data,
    output reg [N-1:0] umi_in_ready,
    // Outgoing UMI
    output [N-1:0]     umi_out_valid,
    output [N*CW-1:0]  umi_out_cmd,
    output [N*AW-1:0]  umi_out_dstaddr,
    output [N*AW-1:0]  umi_out_srcaddr,
    output [N*DW-1:0]  umi_out_data,
    input [N-1:0]      umi_out_ready
    );

   wire [N*N-1:0]    grants;
   wire [N*N-1:0]    ready;
   wire [N*N-1:0]    umi_out_sel;
   genvar 	     i;

   //##############################
   // Arbiters for all outputs
   //##############################

   for (i=0;i<N;i=i+1)
     begin
	umi_arbiter #(.TARGET(TARGET),
		      .N(N))
	umi_arbiter (// Outputs
		     .grants   (grants[N*i+:N]),
		     // Inputs
		     .clk      (clk),
		     .nreset   (nreset),
		     .mode     (mode[1:0]),
		     .mask     (mask[N*i+:N]),
		     .requests (umi_in_request[N*i+:N]));

	assign umi_out_valid[i] = |grants[N*i+:N];
     end // for (i=0;i<N;i=i+1)

   // masking final select to help synthesis pruning
   // TODO: check in syn if this is strictly needed

   assign umi_out_sel[N*N-1:0] = grants[N*N-1:0] & ~mask[N*N-1:0];

   //##############################
   // Ready
   //##############################

   assign ready[N*N-1:0] = ~umi_in_request[N*N-1:0] |
			   ({N{umi_out_ready}} &
			    umi_in_request[N*N-1:0] &
			    grants[N*N-1:0]);

   integer j,k;
   always @*
     begin
	umi_in_ready[N-1:0] = {N{1'b1}};
	for (j=0;j<N;j=j+1)
	  for (k=0;k<N;k=k+1)
	    umi_in_ready[j] = umi_in_ready[j] & ready[j+k*N];
     end

   //##############################
   // Mux on all outputs
   //##############################

   for(i=0;i<N;i=i+1)
     begin: ivmux
	la_vmux #(.N(N),
		  .W(DW))
	la_data_vmux(// Outputs
		     .out (umi_out_data[i*DW+:DW]),
		     // Inputs
		     .sel (umi_out_sel[i*N+:N]),
		     .in  (umi_in_data[N*DW-1:0]));

	la_vmux #(.N(N),
		  .W(AW))
	la_src_vmux(// Outputs
		    .out (umi_out_srcaddr[i*AW+:AW]),
		    // Inputs
		    .sel (umi_out_sel[i*N+:N]),
		    .in  (umi_in_srcaddr[N*AW-1:0]));

	la_vmux #(.N(N),
		  .W(AW))
	la_dst_vmux(// Outputs
		    .out (umi_out_dstaddr[i*AW+:AW]),
		    // Inputs
		    .sel (umi_out_sel[i*N+:N]),
		    .in  (umi_in_dstaddr[N*AW-1:0]));

	la_vmux #(.N(N),
		  .W(CW))
	la_cmd_vmux(// Outputs
		    .out (umi_out_cmd[i*CW+:CW]),
		    // Inputs
		    .sel (umi_out_sel[i*N+:N]),
		    .in  (umi_in_cmd[N*CW-1:0]));
     end

endmodule // umi_crossbar
