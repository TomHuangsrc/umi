/*******************************************************************************
 * Function:  UMI Pipeline Stage
 * Author:    Andreas Olofsson
 *
 * Copyright (c) 2023 Zero ASIC Corporation
 * This code is licensed under Apache License 2.0 (see LICENSE for details)
 *
 * Documentation:
 *
 * -This module create a single cycle umi pipeline.
 *
 * -The "umi_in_ready" output is omitted to make it clear that the ready signal
 * must be broadcasted externally.
 *
 * -We don't reset the packet
 *
 ******************************************************************************/
module umi_pipeline
  #(parameter CW  = 32,
    parameter AW  = 64,
    parameter DW  = 256
    )
   (// clock, reset
    input               clk,
    input               nreset,
    // Incoming UMI request
    input               umi_in_valid,
    input [CW-1:0]      umi_in_cmd,
    input [AW-1:0]      umi_in_dstaddr,
    input [AW-1:0]      umi_in_srcaddr,
    input [DW-1:0]      umi_in_data,
    // Outgoing UMI response
    output reg          umi_out_valid,
    output reg [CW-1:0] umi_out_cmd,
    output reg [AW-1:0] umi_out_dstaddr,
    output reg [AW-1:0] umi_out_srcaddr,
    output reg [DW-1:0] umi_out_data,
    input               umi_out_ready
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
          umi_out_cmd[CW-1:0]     <= umi_in_cmd[CW-1:0];
          umi_out_dstaddr[AW-1:0] <= umi_in_dstaddr[AW-1:0];
          umi_out_srcaddr[AW-1:0] <= umi_in_srcaddr[AW-1:0];
          umi_out_data[DW-1:0]    <= umi_in_data[DW-1:0];
       end

endmodule
