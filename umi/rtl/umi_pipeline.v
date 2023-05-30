/*******************************************************************************
 * Function:  UMI Pipeline Stage
 * Author:    Andreas Olofsson
 * License:
 *
 * Documentation:
 *
 * -This module create a single cycle umi pipeline.
 *
 * -The "umi_in_ready" output is ommitted to amke it clear that the ready signal
 * must be broadcasted externally.
 *
 * -We don't reset the packet
 *
 ******************************************************************************/
module umi_pipeline
  #(parameter CW  = 32,
    parameter AW  = 64,
    parameter UW  = 256
    )
   (// clock, reset
    input 		clk,
    input 		nreset,
    // Incoming UMI request
    input 		umi_in_valid,
    input [CW-1:0] 	umi_in_cmd,
    input [AW-1:0] 	umi_in_dst_addr,
    input [AW-1:0] 	umi_in_src_addr,
    input [UW-1:0] 	umi_in_payload,
    // Outgoing UMI response
    output reg 		umi_out_valid,
    output reg [CW-1:0] umi_out_cmd,
    output reg [AW-1:0] umi_out_dst_addr,
    output reg [AW-1:0] umi_out_src_addr,
    output reg [UW-1:0] umi_out_payload,
    input 		umi_out_ready
    );

   // valid
   always @ (posedge clk or negedge nreset)
     if(!nreset)
       umi_out_valid <= 'b0;
     else if (umi_out_ready)
       umi_out_valid <= umi_in_valid;

   // packet
   always @ (posedge clk)
     if (umi_out_ready & umi_in_valid)
       begin
          umi_out_cmd[CW-1:0]      <= umi_in_cmd[CW-1:0];
          umi_out_dst_addr[AW-1:0] <= umi_in_dst_addr[AW-1:0];
          umi_out_src_addr[AW-1:0] <= umi_in_src_addr[AW-1:0];
          umi_out_payload[UW-1:0]  <= umi_in_payload[UW-1:0];
       end

endmodule
