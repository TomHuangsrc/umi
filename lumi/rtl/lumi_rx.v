/******************************************************************************
 * Function:  Link UMI (LUMI) Rx block
 * Author:    Amir Volk
 * Copyright: 2023 Zero ASIC Corporation
 *
 * License: This file contains confidential and proprietary information of
 * Zero ASIC. This file may only be used in accordance with the terms and
 * conditions of a signed license agreement with Zero ASIC. All other use,
 * reproduction, or distribution of this software is strictly prohibited.
 *
 * Documentation:
 * - converts UMI signaling layer (cmd, addr, data) to multiplexed LUMI i/f
 *
 * Version history:
 * Version 1 - conver from CLINK to LUMI
 * Version 2 - reduce fifo sizes by diving into multiple fifo's
 *****************************************************************************/
module lumi_rx
  #(parameter TARGET = "DEFAULT", // implementation target
    // for development only (fixed )
    parameter IOW = 64,           // clink rx/tx width
    parameter DW = 256,           // umi data width
    parameter CW = 32,            // umi data width
    parameter AW = 64,            // address width
    parameter RXFIFOW = 8         // width of Rx fifo (in bits) - cannot be smaller than IOW!!!
    )
   (// local control
    input             clk,                // clock for sampling input data
    input             nreset,             // async active low reset
    input             csr_en,             // 1=enable outputs
    input [7:0]       csr_iowidth,        // pad bus width
    input             vss,                // common ground
    input             vdd,                // core supply
    input             vddio,              // io voltage
    // pad signals
    input             ioclk,                // clock for sampling input data
    input             ionreset,             // async active low reset
    input [IOW-1:0]   phy_rxdata,
    input             phy_rxvld,
    // Write/Response
    output [CW-1:0]   umi_resp_out_cmd,
    output [AW-1:0]   umi_resp_out_dstaddr,
    output [AW-1:0]   umi_resp_out_srcaddr,
    output [DW-1:0]   umi_resp_out_data,  // link data pads
    output            umi_resp_out_valid, // valid for fifo
    input             umi_resp_out_ready, // flow control from fifo
    // Read/Request
    output [CW-1:0]   umi_req_out_cmd,
    output [AW-1:0]   umi_req_out_dstaddr,
    output [AW-1:0]   umi_req_out_srcaddr,
    output [DW-1:0]   umi_req_out_data,   // link data pads
    output            umi_req_out_valid,  // valid for fifo
    input             umi_req_out_ready,  // flow control from fifo
    // Credit interface
    input [15:0]      csr_crdt_req_init,  // Initial value from clink_regs
    input [15:0]      csr_crdt_resp_init, // Initial value from clink_regs
    output [15:0]     loc_crdt_req,       // Realtime rx credits to be sent to the remote side
    output [15:0]     loc_crdt_resp,      // Realtime rx credits to be sent to the remote side
    output reg [15:0] rmt_crdt_req,       // Credit value from remote side (for Tx)
    output reg [15:0] rmt_crdt_resp       // Credit value from remote side (for Tx)
    );

   localparam FIFOW = RXFIFOW + 1;
   localparam ASYNCFIFODEPTH = 8;
   localparam NFIFO = IOW/RXFIFOW;
   localparam CRDTDEPTH = 1+((DW+AW+AW+CW)/RXFIFOW)/NFIFO;
   /* verilator lint_off WIDTHTRUNC */
   localparam [7:0] LOGFIFOWIDTH = $clog2(RXFIFOW/8);
   localparam [7:0] LOGNFIFO = $clog2(NFIFO);
   /* verilator lint_off WIDTHTRUNC */

   // local state
   reg [$clog2((DW+AW+AW+CW))-1:0] sopptr;
   reg [$clog2((DW+AW+AW+CW))-1:0] rxptr;
   reg [$clog2((DW+AW+AW+CW))-1:0] rxbytes_raw;
   wire [$clog2((DW+AW+AW+CW))-1:0] full_hdr_size;
   wire [$clog2((DW+AW+AW+CW))-1:0] rxbytes_to_rcv;
   reg [$clog2((DW+AW+AW+CW))-1:0]  rxbytes_keep;
   reg [$clog2((DW+AW+AW+CW))-1:0]  bytes_to_receive;
   reg                              rxvalid;
   reg                              rxvalid2;
   reg                              rxfec;
   reg [(DW+AW+AW+CW)-1:0]          shiftreg;
   wire [(DW+AW+AW+CW)-1:0]         shiftreg_in;
   reg [CW-1:0]                     lnk_shiftreg;
   reg [CW-1:0]                     lnk_fifo_dout_mask;
   reg [1:0]                        lnk_sop;
   wire [1:0]                       lnk_sop_next;
   reg                              transfer;
   reg [2:0]                        rxtype_next;
   reg [15:0]                       rx_crdt_req;
   reg [15:0]                       rx_crdt_resp;
   reg [1:0]                        fifo_sel_hold;
   wire [1:0]                       fifo_sel;
   wire [1:0]                       fifo_eop;
   wire [1:0]                       fifo_empty;
   wire                             lnk_fifo_empty;
   wire [1:0]                       fifo_wr;
   wire                             lnk_fifo_wr;
   wire [1:0]                       fifo_rd;
   wire                             lnk_fifo_rd;
   wire [NFIFO:0]                   fifo_mux_sel;
   wire [NFIFO-1:0]                 fifo_dout_sel;
   wire [NFIFO-1:0]                 fifo_dout_mask;
   wire [7:0]                       iow_mask;
   wire [7:0]                       iow_shift;
   wire [7:0]                       fifo_mux_mask;
   wire [NFIFO*8-1:0]               fifo_rd_shift;
   wire [NFIFO*8-1:0]               fifo_wr_shift;
   wire [IOW+NFIFO-1:0]             req_fifo_din;
   wire [NFIFO-1:0]                 req_fifo_wr;
   wire [NFIFO-1:0]                 req_fifo_rd;
   wire [NFIFO-1:0]                 req_fifo_empty;
   wire [NFIFO-1:0]                 req_fifo_full;
   wire [IOW+NFIFO-1:0]             req_fifo_dout;
   wire [IOW+NFIFO-1:0]             req_fifo_dout_muxed;
   wire [IOW+NFIFO-1:0]             resp_fifo_din;
   wire [NFIFO-1:0]                 resp_fifo_wr;
   wire [NFIFO-1:0]                 resp_fifo_rd;
   wire [NFIFO-1:0]                 resp_fifo_empty;
   wire [NFIFO-1:0]                 resp_fifo_full;
   wire [IOW+NFIFO-1:0]             resp_fifo_dout;
   wire [IOW+NFIFO-1:0]             resp_fifo_dout_muxed;
   wire [CW-1:0]                    lnk_fifo_din;
   wire [CW-1:0]                    lnk_fifo_dout;
   wire [IOW-1:0]                   fifo_data_muxed;
   wire [IOW-1:0]                   sync_fifo_dout;
   wire                             sync_fifo_wr;
   wire                             sync_fifo_rd;
   wire                             sync_fifo_empty;
   wire                             sync_fifo_full;

   // local wires
   wire [2:0]                       rxtype;
   // Amir - byterate is used later as shifterd 3 bits to the left so needs 3 more bits than the "pure" value
   wire [$clog2((DW+AW+AW+CW))-1:0] byterate;
   wire [10:0]                      iowidth;
   //   wire [$clog2(DW/8)-1:0] byterate;
   wire [$clog2((DW+AW+AW+CW))-1:0] sopptr_next;
   wire [$clog2((DW+AW+AW+CW))-1:0] rxptr_next;
   wire [$clog2((DW+AW+AW+CW))-1:0] datashift;
   wire [(DW+AW+AW+CW)-1:0]         writemask;
   reg [IOW-1:0]                    rxdata;
   reg [7:0]                        rxdata_d;
   wire [CW-1:0]                    umi_out_cmd;
   wire [AW-1:0]                    umi_out_dstaddr;
   wire [AW-1:0]                    umi_out_srcaddr;
   wire [DW-1:0]                    umi_out_data;
   wire                             umi_out_valid;

   wire                             rx_cmd_only;
   wire                             rx_no_data;
   wire                             cmd_only;
   wire                             fifo_cmd_only;
   wire                             no_data;
   wire [11:0]                      rxcmd_lenp1;
   wire [11:0]                      rxcmd_bytes;
   wire [11:0]                      cmd_lenp1;
   wire [11:0]                      cmd_bytes;

   wire [1:0]                       credit_req_in;

   wire [15:0]                      rxhdr;
   wire                             rxhdr_sample;

   /*AUTOWIRE*/
   // Beginning of automatic wires (for undeclared instantiated-module outputs)
   wire                 cmd_error;
   wire                 cmd_future0;
   wire                 cmd_future0_resp;
   wire                 cmd_future1_resp;
   wire                 cmd_invalid;
   wire [7:0]           cmd_len;
   wire                 cmd_link;
   wire                 cmd_link_resp;
   wire                 cmd_rdma;
   wire                 cmd_read;
   wire                 cmd_read_resp;
   wire                 cmd_request;
   wire                 cmd_response;
   wire [2:0]           cmd_size;
   wire                 cmd_user0;
   wire                 cmd_user0_resp;
   wire                 cmd_user1_resp;
   wire                 cmd_write;
   wire                 cmd_write_posted;
   wire                 cmd_write_resp;
   wire                 fifo_cmd_invalid;
   wire [23:0]          lnk_cmd_user;
   wire                 rxcmd_error;
   wire                 rxcmd_future0;
   wire                 rxcmd_future0_resp;
   wire                 rxcmd_future1_resp;
   wire                 rxcmd_invalid;
   wire [7:0]           rxcmd_len;
   wire                 rxcmd_link;
   wire                 rxcmd_link_resp;
   wire                 rxcmd_rdma;
   wire                 rxcmd_read;
   wire                 rxcmd_read_resp;
   wire                 rxcmd_request;
   wire                 rxcmd_response;
   wire [2:0]           rxcmd_size;
   wire                 rxcmd_user0;
   wire                 rxcmd_user0_resp;
   wire                 rxcmd_user1_resp;
   wire                 rxcmd_write;
   wire                 rxcmd_write_posted;
   wire                 rxcmd_write_resp;
   wire                 umi_out_ready;
   // End of automatics

   //########################################
   //# interface width calculation
   //########################################
   assign iowidth[10:0] = 11'h1 << csr_iowidth[7:0];

   // bytes per clock cycle
   // Updating to 128b DW. TODO: this will need to change later
   assign byterate[$clog2((DW+AW+AW+CW))-1:0] = {{($clog2(DW+AW+AW+CW)-8){1'b0}},iowidth[7:0]};

   //########################################
   //# Input Sampling
   //########################################

   // Detect valis signal
   always @ (posedge ioclk or negedge ionreset)
     if (~nreset)
       begin
          rxvalid  <= 1'b0;
          rxvalid2 <= 1'b0;
       end
     else
       begin
          rxvalid  <= phy_rxvld;
          rxvalid2 <= rxvalid;
       end

   // rising edge data sample
   always @ (posedge ioclk)
     rxdata[IOW-1:0] <= phy_rxdata[IOW-1:0];

   always @ (posedge ioclk or negedge ionreset)
     if (~nreset)
       rxdata_d[7:0] <= 'h0;
     else
       if (rxvalid)
         rxdata_d[7:0] <= rxdata[7:0];

   //########################################
   //# Input data tracking
   //########################################
   //
   // Input data is now separate before and after the input fifo
   // As a result need to understand data size and track (to generate SOP)

   // Handle 1B i/f width
   assign rxhdr[15:0] = (sopptr == 'h0) & (csr_iowidth == 8'h0) ? {8'h0,rxdata[7:0]}       : // dummy width of 4B
                        (sopptr == 'h1) & (csr_iowidth == 8'h0) ? {rxdata[7:0],rxdata_d[7:0]} :
                        rxdata[15:0];

   /*umi_unpack AUTO_TEMPLATE(
    .cmd_len    (rxcmd_len[]),
    .cmd_size   (rxcmd_size[]),
    .cmd.*      (),
    .packet_cmd ({{CW-16{1'b0}},rxhdr[15:0]}),
    );*/

   umi_unpack #(.CW(CW))
   rxdata_unpack(/*AUTOINST*/
                 // Outputs
                 .cmd_opcode            (),                      // Templated
                 .cmd_size              (rxcmd_size[2:0]),       // Templated
                 .cmd_len               (rxcmd_len[7:0]),        // Templated
                 .cmd_atype             (),                      // Templated
                 .cmd_qos               (),                      // Templated
                 .cmd_prot              (),                      // Templated
                 .cmd_eom               (),                      // Templated
                 .cmd_eof               (),                      // Templated
                 .cmd_ex                (),                      // Templated
                 .cmd_user              (),                      // Templated
                 .cmd_user_extended     (),                      // Templated
                 .cmd_err               (),                      // Templated
                 .cmd_hostid            (),                      // Templated
                 // Inputs
                 .packet_cmd            ({{CW-16{1'b0}},rxhdr[15:0]})); // Templated

   /*umi_decode AUTO_TEMPLATE(
    .command      ({{CW-16{1'b0}},rxhdr[15:0]}),
    .cmd_atomic.* (),
    .cmd_\(.*\)   (rxcmd_\1[]),
    );*/

   umi_decode #(.CW(CW))
   rxdata_decode (/*AUTOINST*/
                  // Outputs
                  .cmd_invalid          (rxcmd_invalid),         // Templated
                  .cmd_request          (rxcmd_request),         // Templated
                  .cmd_response         (rxcmd_response),        // Templated
                  .cmd_read             (rxcmd_read),            // Templated
                  .cmd_write            (rxcmd_write),           // Templated
                  .cmd_write_posted     (rxcmd_write_posted),    // Templated
                  .cmd_rdma             (rxcmd_rdma),            // Templated
                  .cmd_atomic           (),                      // Templated
                  .cmd_user0            (rxcmd_user0),           // Templated
                  .cmd_future0          (rxcmd_future0),         // Templated
                  .cmd_error            (rxcmd_error),           // Templated
                  .cmd_link             (rxcmd_link),            // Templated
                  .cmd_read_resp        (rxcmd_read_resp),       // Templated
                  .cmd_write_resp       (rxcmd_write_resp),      // Templated
                  .cmd_user0_resp       (rxcmd_user0_resp),      // Templated
                  .cmd_user1_resp       (rxcmd_user1_resp),      // Templated
                  .cmd_future0_resp     (rxcmd_future0_resp),    // Templated
                  .cmd_future1_resp     (rxcmd_future1_resp),    // Templated
                  .cmd_link_resp        (rxcmd_link_resp),       // Templated
                  .cmd_atomic_add       (),                      // Templated
                  .cmd_atomic_and       (),                      // Templated
                  .cmd_atomic_or        (),                      // Templated
                  .cmd_atomic_xor       (),                      // Templated
                  .cmd_atomic_max       (),                      // Templated
                  .cmd_atomic_min       (),                      // Templated
                  .cmd_atomic_maxu      (),                      // Templated
                  .cmd_atomic_minu      (),                      // Templated
                  .cmd_atomic_swap      (),                      // Templated
                  // Inputs
                  .command              ({{CW-16{1'b0}},rxhdr[15:0]})); // Templated

   // Second step - decode what format will be received
   assign rx_cmd_only  = rxcmd_invalid    |
                         rxcmd_link       |
                         rxcmd_link_resp  ;
   assign rx_no_data   = rxcmd_read       |
                         rxcmd_rdma       |
                         rxcmd_error      |
                         rxcmd_write_resp |
                         rxcmd_user0      |
                         rxcmd_future0    ;

   assign rxcmd_lenp1[11:0] = {4'h0,rxcmd_len[7:0]} + 1'b1;
   assign rxcmd_bytes[11:0] = rxcmd_lenp1[11:0] << rxcmd_size[2:0];

   assign full_hdr_size = (CW+AW+AW)/8;

   always @(*)
     case ({rx_cmd_only,rx_no_data})
       2'b10: rxbytes_raw = (CW)/8;
       2'b01: rxbytes_raw = (CW+AW+AW)/8;
       default: rxbytes_raw = full_hdr_size + rxcmd_bytes[8:0];
     endcase

   // support for 1B IOW (#bytes unknown in first cycle)
   assign rxhdr_sample = (sopptr == 'h0) |
                         (sopptr == 'h1) & (csr_iowidth == 8'h0);

   always @ (posedge ioclk or negedge ionreset)
     if (~nreset)
       rxbytes_keep <= 'h0;
     else
       if (rxhdr_sample & rxvalid)
         rxbytes_keep <= rxbytes_raw;

   assign rxbytes_to_rcv = rxhdr_sample & rxvalid ?
                           rxbytes_raw :
                           rxbytes_keep;

   // Valid register holds one bit per byte to transfer
   always @ (posedge ioclk or negedge ionreset)
     if (~nreset)
       sopptr <= 'b0;
     else if (rxvalid)
       sopptr <= sopptr_next;

   // Count by the number of bytes per cycle transfered
   // When reaching the end of the header need to re-align to the remaining bytes
   assign sopptr_next = ((sopptr + byterate) >= rxbytes_to_rcv) ?
                        0 :
                        sopptr + byterate;

   //########################################
   //# Credit management
   //########################################
   // credit counters store the number of bytes received
   // The default will be the FIFO depth but configuration can choose to use less
   // As we use separate credit and fifo for req/resp we need to decode the cmd
   // Since the data might come on a narror interface will only use the first byte

   // Sample packet type from the RX lines upon SOP
   always @(posedge ioclk or negedge ionreset)
     if (~nreset)
       rxtype_next[2:0] <= 3'b000;
     else
       if (rxhdr_sample & rxvalid)
         rxtype_next[2:0] <= {rxcmd_link, rxcmd_response & ~rxcmd_link, rxcmd_request & ~rxcmd_link};

   assign rxtype = rxhdr_sample & rxvalid ?
                   {rxcmd_link, rxcmd_response & ~rxcmd_link, rxcmd_request & ~rxcmd_link} :
                   rxtype_next;

   // credit counters - to be sent to the remote side
   always @(posedge ioclk or negedge ionreset)
     if (~nreset)
       begin
          rx_crdt_req[15:0]  <= 'h0;
          rx_crdt_resp[15:0] <= 'h0;
       end
     else
       if (~csr_en)
         begin
            rx_crdt_req[15:0]  <= csr_crdt_req_init[15:0];
            rx_crdt_resp[15:0] <= csr_crdt_resp_init[15:0];
         end
       else
         begin // TODO - sync between io clock (read signals) and register (clk)
            if (fifo_rd[0])
              rx_crdt_req[15:0]  <= rx_crdt_req[15:0]  + 1;
            if (fifo_rd[1])
              rx_crdt_resp[15:0] <= rx_crdt_resp[15:0] + 1;
         end

   assign loc_crdt_req  = rx_crdt_req;
   assign loc_crdt_resp = rx_crdt_resp;

   //########################################
   // Input fifo alignment
   //########################################
   // In order to support various iowidth without paying in area the input fifo
   // need to be split into smaller fifo that can be arranged in the right configuration
   // The fifo's will be aligned in a way that minimizes the muxing
   // Limitation: IOW cannot be smaller than the fifo width!
   // As an example for 128b IOW with 8b minimum width the following configurations will be used:
   // iowidth=128b: all fifo's used in parallel
   // iowidth=64b:  0 ->  1
   //               2 ->  3
   //               4 ->  5
   //               6 ->  7
   //               8 ->  9
   //              10 -> 11
   //              12 -> 13
   //              14 -> 15
   // iowidth=32b:  0 ->  1 ->  2 ->  3
   //               4 ->  5 ->  6 ->  7
   //               8 ->  9 -> 10 -> 11
   //              11 -> 12 -> 14 -> 15
   // iowidth=16b:  0 ->  1 ->  2 ->  3 ->  4 ->  5 ->  6 ->  7
   //               8 ->  9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 15
   // iowidth=8b:   0 ->  1 ->  2 ->  3 ->  4 ->  5 ->  6 ->  7 ->  8 ->  9 -> 10 -> 11 -> 12 -> 13 -> 14 -> 15
   //########################################
   // common masks - for both request and response fifos
   //########################################
   assign iow_mask[7:0]      = (IOW >> 3) - 1'b1;
   assign fifo_mux_mask[7:0] = iow_mask[7:0] >> csr_iowidth[7:0] >> LOGFIFOWIDTH;

   genvar i;
   for(i=0;i<NFIFO;i=i+1)
     begin
        // Mask for which fifo gets IO data
        assign fifo_mux_sel[i] = (i[7:0] & fifo_mux_mask[7:0]) == 8'h0;
        /* verilator lint_off UNSIGNED */
        // Mapping of which fifo output goes to the output bus
        assign fifo_dout_sel[i] = (i << LOGFIFOWIDTH) >= iowidth;
        /* verilator lint_off UNSIGNED */
        // Mask for looking at empty fifo
        assign fifo_dout_mask[i] = (i[7:0] & fifo_mux_mask[7:0]) == fifo_mux_mask[7:0];
        // Shift for input busses
        assign fifo_wr_shift[i*8+:8] = fifo_mux_sel[i]  ? i >> (LOGNFIFO - csr_iowidth) : 8'h0;
        // Shift for output busses
        assign fifo_rd_shift[i*8+:8] = fifo_dout_sel[i] ? 32'h0 : (i+1)*(NFIFO >> csr_iowidth)-1;
     end

   // Dummy, just for the equations in the loop below
   assign fifo_mux_sel[NFIFO] = 1'b1;

   //########################################
   // Request Fifo
   //########################################
   assign fifo_wr[0]    = rxvalid & (rxtype[2:0] == 3'b001);
   assign fifo_empty[0] = ~(|(~req_fifo_empty[NFIFO-1:0] & fifo_dout_mask[NFIFO-1:0]));
   assign fifo_rd[0]    = ~fifo_empty[0] &
                          fifo_sel[0] &
                          ~sync_fifo_full;

   wire [NFIFO- 1:0] fifo_werror = req_fifo_wr[NFIFO-1:0] & req_fifo_full[NFIFO-1:0] & fifo_mux_sel[NFIFO-1:0];
   wire [NFIFO- 1:0] fifo_rerror = req_fifo_rd[NFIFO-1:0] & req_fifo_empty[NFIFO-1:0];

   genvar j;
   for(j=0;j<NFIFO;j=j+1)
     begin
        assign req_fifo_din[j*FIFOW+:FIFOW] = fifo_mux_sel[j] | (j == 0) ?
                                              {~(|sopptr_next),rxdata[fifo_wr_shift[j*8+:8]*RXFIFOW+:RXFIFOW]} :
                                              req_fifo_dout[(j-1)*FIFOW+:FIFOW];

        assign req_fifo_wr[j] = fifo_mux_sel[j] ? fifo_wr[0] : ~req_fifo_empty[j-1];

        assign req_fifo_rd[j] = fifo_mux_sel[j+1] ? fifo_rd[0] : ~req_fifo_full[j+1];

        assign req_fifo_dout_muxed[j*FIFOW+:FIFOW] = fifo_dout_sel[j] ?
                                                     'h0 :
                                                     req_fifo_dout[fifo_rd_shift[j*8+:8]*FIFOW+:FIFOW];

        la_syncfifo #(.DW(FIFOW),  // Memory width
                      .DEPTH(CRDTDEPTH), // FIFO depth
                      .NS(1),            // Number of power supplies
                      .CHAOS(0),         // generates random full logic when set
                      .CTRLW(1),         // width of asic ctrl interface
                      .TESTW(1),         // width of asic test interface
                      .TYPE("DEFAULT"))  // Pass through variable for hard macro
        req_fifo_i(// Outputs
                   .wr_full          (req_fifo_full[j]),
                   .rd_dout          (req_fifo_dout[j*FIFOW+:FIFOW]),
                   .rd_empty         (req_fifo_empty[j]),
                   // Inputs
                   .clk              (ioclk),
                   .nreset           (ionreset),
                   .vss              (1'b0),
                   .vdd              (1'b1),
                   .chaosmode        (1'b0),
                   .ctrl             (1'b0),
                   .test             (1'b0),
                   .wr_en            (req_fifo_wr[j]),
                   .wr_din           (req_fifo_din[j*FIFOW+:FIFOW]),
                   .rd_en            (req_fifo_rd[j]));
     end

   //########################################
   // Response Fifo
   //########################################
   assign fifo_wr[1]    = rxvalid & (rxtype[2:0] == 3'b010);
   assign fifo_empty[1] = ~(|(~resp_fifo_empty[NFIFO-1:0] & fifo_dout_mask[NFIFO-1:0]));
   assign fifo_rd[1]    = ~fifo_empty[1] &
                          fifo_sel[1] &
                          ~sync_fifo_full;

   genvar k;

   for(k=0;k<NFIFO;k=k+1)
     begin
        assign resp_fifo_din[k*FIFOW+:FIFOW] = fifo_mux_sel[k]  | (k == 0) ?
                                               {~(|sopptr_next),rxdata[fifo_wr_shift[k*8+:8]*RXFIFOW+:RXFIFOW]} :
                                               resp_fifo_dout[(k-1)*FIFOW+:FIFOW];

        assign resp_fifo_wr[k] = fifo_mux_sel[k] ? fifo_wr[1] : ~resp_fifo_empty[k-1];

        assign resp_fifo_rd[k] = fifo_mux_sel[k+1] ? fifo_rd[1] : ~resp_fifo_full[k+1];

        assign resp_fifo_dout_muxed[k*FIFOW+:FIFOW] = fifo_dout_sel[k] ?
                                                      'h0 :
                                                      resp_fifo_dout[fifo_rd_shift[k*8+:8]*FIFOW+:FIFOW];

        la_syncfifo #(.DW(FIFOW),  // Memory width
                      .DEPTH(CRDTDEPTH), // FIFO depth
                      .NS(1),            // Number of power supplies
                      .CHAOS(0),         // generates random full logic when set
                      .CTRLW(1),         // width of asic ctrl interface
                      .TESTW(1),         // width of asic test interface
                      .TYPE("DEFAULT"))  // Pass through variable for hard macro
        resp_fifo_i(// Outputs
                    .wr_full          (resp_fifo_full[k]),
                    .rd_dout          (resp_fifo_dout[k*FIFOW+:FIFOW]),
                    .rd_empty         (resp_fifo_empty[k]),
                    // Inputs
                    .clk              (ioclk),
                    .nreset           (ionreset),
                    .vss              (1'b0),
                    .vdd              (1'b1),
                    .chaosmode        (1'b0),
                    .ctrl             (1'b0),
                    .test             (1'b0),
                    .wr_en            (resp_fifo_wr[k]),
                    .wr_din           (resp_fifo_din[k*FIFOW+:FIFOW]),
                    .rd_en            (resp_fifo_rd[k]));
     end

   //########################################
   // link cmd Fifo - no FC
   //########################################
   assign lnk_fifo_wr = rxvalid & (rxtype[2:0] == 3'b100);
   assign lnk_fifo_rd = ~lnk_fifo_empty;
   assign lnk_fifo_din[CW-1:0] = rxdata[CW-1:0];

   la_asyncfifo #(.DW(CW)  ,  // Link commands are only 32b
                  .DEPTH(8),  // FIFO depth
                  .NS(1),     // Number of power supplies
                  .CHAOS(0),  // generates random full logic when set
                  .CTRLW(1),  // width of asic ctrl interface
                  .TESTW(1),  // width of asic test interface
                  .TYPE("DEFAULT")) // Pass through variable for hard macro
   lnk_fifo_i(// Outputs
              .wr_full          (),
              .rd_dout          (lnk_fifo_dout[CW-1:0]),
              .rd_empty         (lnk_fifo_empty),
              // Inputs
              .rd_clk           (clk),
              .rd_nreset        (nreset),
              .wr_clk           (ioclk),
              .wr_nreset        (ionreset),
              .vss              (1'b0),
              .vdd              (1'b1),
              .wr_chaosmode     (1'b0),
              .ctrl             (1'b0),
              .test             (1'b0),
              .wr_en            (lnk_fifo_wr),
              .wr_din           (lnk_fifo_din[CW-1:0]),
              .rd_en            (lnk_fifo_rd));

   assign lnk_sop_next[1:0] = lnk_sop[1:0] + iowidth[1:0];

   always @(posedge ioclk or negedge ionreset)
     if (~nreset)
       begin
          lnk_sop[1:0]               <= 'h0;
          lnk_fifo_dout_mask[CW-1:0] <= 'h0;
          lnk_shiftreg[CW-1:0]       <= 'h0;
       end
     else if (lnk_fifo_rd)
       begin
          lnk_sop[1:0]               <= lnk_sop_next[1:0];
          lnk_fifo_dout_mask[CW-1:0] <= (lnk_sop_next[1:0] == 2'b00) ?
                                        ~({CW{1'b1}}<<(iowidth<<3))  :
                                        lnk_fifo_dout_mask[CW-1:0] << (iowidth*8);
          lnk_shiftreg[CW-1:0]       <= (lnk_sop[1:0] == 2'b00)      ?
                                        lnk_fifo_dout[CW-1:0]        :
                                        lnk_fifo_dout[CW-1:0] & lnk_fifo_dout_mask[CW-1:0] |
                                        lnk_shiftreg[CW-1:0] & ~lnk_fifo_dout_mask[CW-1:0];
       end

   /*umi_unpack AUTO_TEMPLATE(
    .packet_cmd        (lnk_fifo_dout[]),
    .cmd_user_extended (lnk_cmd_user[]),
    .cmd_.*            (),
    );*/
   umi_unpack #(.CW(CW))
   lnk_unpack (/*AUTOINST*/
               // Outputs
               .cmd_opcode      (),                      // Templated
               .cmd_size        (),                      // Templated
               .cmd_len         (),                      // Templated
               .cmd_atype       (),                      // Templated
               .cmd_qos         (),                      // Templated
               .cmd_prot        (),                      // Templated
               .cmd_eom         (),                      // Templated
               .cmd_eof         (),                      // Templated
               .cmd_ex          (),                      // Templated
               .cmd_user        (),                      // Templated
               .cmd_user_extended(lnk_cmd_user[23:0]),   // Templated
               .cmd_err         (),                      // Templated
               .cmd_hostid      (),                      // Templated
               // Inputs
               .packet_cmd      (lnk_fifo_dout[CW-1:0])); // Templated

   //########################################
   //# "steal" incoming credit update
   //########################################
   assign credit_req_in[0] = lnk_fifo_rd &
                             (lnk_sop[1:0] == 2'b00) &
                             ((lnk_cmd_user[7:0] == 8'h01) | (lnk_cmd_user[7:0] == 8'h02));

   assign credit_req_in[1] = lnk_fifo_rd &
                             (lnk_sop[1:0] == 2'b00) &
                             ((lnk_cmd_user[7:0] == 8'h11) | (lnk_cmd_user[7:0] == 8'h12));

   always @(posedge ioclk or negedge ionreset)
     if (~nreset)
       begin
          rmt_crdt_req  <= 'h0;
          rmt_crdt_resp <= 'h0;
       end
     else
       begin //TODO - sync to internal clock
          if (credit_req_in[0])
            rmt_crdt_req  <= lnk_cmd_user[23:8];
          if (credit_req_in[1])
            rmt_crdt_resp <= lnk_cmd_user[23:8];
       end

   //########################################
   //# mux between requests and responses (link was already consumed)
   //########################################
   // lock fifo sel, change only at EOP
   // TODO - CDC
   always @(posedge clk or negedge nreset)
     if (~nreset)
       fifo_sel_hold <= 2'b00;
     else
       fifo_sel_hold <= ~sync_fifo_full & |(fifo_sel[1:0] & fifo_eop[1:0]) ? 2'b00             :
                        ~sync_fifo_full & ~(|fifo_sel_hold)                ? fifo_sel[1:0]     :
                                                                             fifo_sel_hold[1:0];

   assign fifo_eop[1:0] = {resp_fifo_dout_muxed[FIFOW-1],req_fifo_dout_muxed[FIFOW-1]} &
                          ~fifo_empty[1:0];

   // Cannot change fifo sel when there is already a pending transaction - wait for EOP
   assign fifo_sel = ~(|fifo_sel_hold) ?
                     {~fifo_empty[1], fifo_empty[1] & ~fifo_empty[0]} :
                     fifo_sel_hold;

   genvar l;
   for(l=0;l<NFIFO;l=l+1)
     begin
        assign fifo_data_muxed[l*RXFIFOW+:RXFIFOW] = {RXFIFOW{fifo_sel[1]}} & resp_fifo_dout_muxed[l*FIFOW+:RXFIFOW]  |
                                                     {RXFIFOW{fifo_sel[0]}} & req_fifo_dout_muxed[l*FIFOW+:RXFIFOW]   ;
     end

   //########################################
   // Async fifo to cross from phy clock to lumi clock
   //########################################
   assign sync_fifo_wr = |fifo_rd[1:0];
   assign sync_fifo_rd = ~sync_fifo_empty & ~(umi_out_valid & ~umi_out_ready);

   la_asyncfifo #(.DW(IOW),               // Link commands are only 32b
                  .DEPTH(ASYNCFIFODEPTH), // FIFO depth
                  .NS(1),                 // Number of power supplies
                  .CHAOS(0),              // generates random full logic when set
                  .CTRLW(1),              // width of asic ctrl interface
                  .TESTW(1),              // width of asic test interface
                  .TYPE("DEFAULT"))       // Pass through variable for hard macro
   clock_fifo_i(// Outputs
              .wr_full          (sync_fifo_full),
              .rd_dout          (sync_fifo_dout[IOW-1:0]),
              .rd_empty         (sync_fifo_empty),
              // Inputs
              .rd_clk           (clk),
              .rd_nreset        (nreset),
              .wr_clk           (ioclk),
              .wr_nreset        (ionreset),
              .vss              (1'b0),
              .vdd              (1'b1),
              .wr_chaosmode     (1'b0),
              .ctrl             (1'b0),
              .test             (1'b0),
              .wr_en            (sync_fifo_wr),
              .wr_din           (fifo_data_muxed[IOW-1:0]),
              .rd_en            (sync_fifo_rd));

   // link commands will be consumed before the sync fifo so that they are not blocked
   /*umi_decode AUTO_TEMPLATE(
    .command       (sync_fifo_dout[]),
    .cmd_invalid   (fifo_cmd_invalid[]),
    .cmd_.*        (),
    );*/
   umi_decode #(.CW(CW))
   fifo_decode (/*AUTOINST*/
                // Outputs
                .cmd_invalid    (fifo_cmd_invalid),      // Templated
                .cmd_request    (),                      // Templated
                .cmd_response   (),                      // Templated
                .cmd_read       (),                      // Templated
                .cmd_write      (),                      // Templated
                .cmd_write_posted(),                     // Templated
                .cmd_rdma       (),                      // Templated
                .cmd_atomic     (),                      // Templated
                .cmd_user0      (),                      // Templated
                .cmd_future0    (),                      // Templated
                .cmd_error      (),                      // Templated
                .cmd_link       (),                      // Templated
                .cmd_read_resp  (),                      // Templated
                .cmd_write_resp (),                      // Templated
                .cmd_user0_resp (),                      // Templated
                .cmd_user1_resp (),                      // Templated
                .cmd_future0_resp(),                     // Templated
                .cmd_future1_resp(),                     // Templated
                .cmd_link_resp  (),                      // Templated
                .cmd_atomic_add (),                      // Templated
                .cmd_atomic_and (),                      // Templated
                .cmd_atomic_or  (),                      // Templated
                .cmd_atomic_xor (),                      // Templated
                .cmd_atomic_max (),                      // Templated
                .cmd_atomic_min (),                      // Templated
                .cmd_atomic_maxu(),                      // Templated
                .cmd_atomic_minu(),                      // Templated
                .cmd_atomic_swap(),                      // Templated
                // Inputs
                .command        (sync_fifo_dout[CW-1:0])); // Templated

   assign fifo_cmd_only  = fifo_cmd_invalid;

   //########################################
   // UMI bandwidth optimization - only what is needed is sent
   //########################################

   // First step - decode the packet
   /*umi_unpack AUTO_TEMPLATE(
    .cmd_len           (cmd_len[]),
    .cmd_size          (cmd_size[]),
    .cmd.*             (),
    .packet_cmd        (shiftreg[]),
    );*/

   umi_unpack #(.CW(CW))
   umi_unpack(/*AUTOINST*/
              // Outputs
              .cmd_opcode       (),                      // Templated
              .cmd_size         (cmd_size[2:0]),         // Templated
              .cmd_len          (cmd_len[7:0]),          // Templated
              .cmd_atype        (),                      // Templated
              .cmd_qos          (),                      // Templated
              .cmd_prot         (),                      // Templated
              .cmd_eom          (),                      // Templated
              .cmd_eof          (),                      // Templated
              .cmd_ex           (),                      // Templated
              .cmd_user         (),                      // Templated
              .cmd_user_extended(),                      // Templated
              .cmd_err          (),                      // Templated
              .cmd_hostid       (),                      // Templated
              // Inputs
              .packet_cmd       (shiftreg[CW-1:0]));     // Templated

   /*umi_decode AUTO_TEMPLATE(
    .command       (shiftreg[]),
    .cmd_atomic.* (),
    );*/
   umi_decode #(.CW(CW))
   umi_decode (/*AUTOINST*/
               // Outputs
               .cmd_invalid     (cmd_invalid),
               .cmd_request     (cmd_request),
               .cmd_response    (cmd_response),
               .cmd_read        (cmd_read),
               .cmd_write       (cmd_write),
               .cmd_write_posted(cmd_write_posted),
               .cmd_rdma        (cmd_rdma),
               .cmd_atomic      (),                      // Templated
               .cmd_user0       (cmd_user0),
               .cmd_future0     (cmd_future0),
               .cmd_error       (cmd_error),
               .cmd_link        (cmd_link),
               .cmd_read_resp   (cmd_read_resp),
               .cmd_write_resp  (cmd_write_resp),
               .cmd_user0_resp  (cmd_user0_resp),
               .cmd_user1_resp  (cmd_user1_resp),
               .cmd_future0_resp(cmd_future0_resp),
               .cmd_future1_resp(cmd_future1_resp),
               .cmd_link_resp   (cmd_link_resp),
               .cmd_atomic_add  (),                      // Templated
               .cmd_atomic_and  (),                      // Templated
               .cmd_atomic_or   (),                      // Templated
               .cmd_atomic_xor  (),                      // Templated
               .cmd_atomic_max  (),                      // Templated
               .cmd_atomic_min  (),                      // Templated
               .cmd_atomic_maxu (),                      // Templated
               .cmd_atomic_minu (),                      // Templated
               .cmd_atomic_swap (),                      // Templated
               // Inputs
               .command         (shiftreg[CW-1:0]));     // Templated

   // Second step - decode what format will be received
   assign cmd_only  = cmd_invalid    |
                      cmd_link       |
                      cmd_link_resp  ;
   assign no_data   = cmd_read       |
                      cmd_rdma       |
                      cmd_error      |
                      cmd_write_resp |
                      cmd_user0      |
                      cmd_future0    ;

   assign cmd_lenp1[11:0] = {4'h0,cmd_len[7:0]} + 1'b1;
   assign cmd_bytes[11:0] = cmd_lenp1[11:0] << cmd_size[2:0];

   always @(*)
     case ({cmd_only,no_data})
       2'b10: bytes_to_receive = (CW)/8;
       2'b01: bytes_to_receive = (CW+AW+AW)/8;
       default: bytes_to_receive = full_hdr_size + cmd_bytes[8:0];
     endcase

   // Valid register holds one bit per byte to transfer
   always @ (posedge clk or negedge nreset)
     if (~nreset)
       rxptr <= 'b0;
     else if (sync_fifo_rd)
       rxptr <= rxptr_next;

   // Count by the number of bytes per cycle transfered
   // When reaching the end of the header need to re-align to the remaining bytes
   // Special case - need to check that the fifo data is cmd_only and then hold rxptr

   assign rxptr_next = ((|rxptr) & ((rxptr + byterate) >= bytes_to_receive) |
                        ~(|rxptr) & fifo_cmd_only & (byterate >= CW/8)) ?
                       0 :
                       rxptr + byterate;

   // Transfer shift regster data when counter rolls over
   // Need to stall it when the output is not ready
   always @ (posedge clk or negedge nreset)
     if (~nreset)
       transfer <= 'b0;
     else
       if (~transfer | umi_out_ready)
         transfer <= ((|rxptr) |
                      ~(|rxptr) & fifo_cmd_only & (byterate >= CW/8)) &
                     sync_fifo_rd &
                     (~|rxptr_next);

   //########################################
   //# DATA SHIFT REGISTER
   //########################################

   // extending byte based rxptr for full DW vector
   assign datashift[$clog2((DW+AW+AW+CW))-1:0] = rxptr;

   // writemask for writing to shift register
   assign writemask[(DW+AW+AW+CW)-1:0] = ~({(DW+AW+AW+CW){1'b1}} << (byterate<<3)) <<
                                         (datashift<<3);

   // The input bus needs to account for the shift output size
   assign shiftreg_in[(DW+AW+AW+CW)-1:0] = {{(DW+AW+AW+CW-IOW){1'b0}},sync_fifo_dout[IOW-1:0]};

   // non traditional shift register to handle multi modes
   // Need to stall the pipeline, including the shiftreg, when output is stalled
   always @ (posedge clk)
     if (sync_fifo_rd)
     shiftreg[(DW+AW+AW+CW)-1:0] <= (shiftreg_in[(DW+AW+AW+CW)-1:0] << (datashift<<3)) & writemask[(DW+AW+AW+CW)-1:0] |
                                    (shiftreg[(DW+AW+AW+CW)-1:0] & ~writemask[(DW+AW+AW+CW)-1:0]);

   //########################################
   //# output stage
   //########################################

   assign umi_out_cmd[CW-1:0] = shiftreg[CW-1:0];

   assign umi_out_dstaddr[AW-1:0] = cmd_only ? {AW{1'b0}} :
                                               shiftreg[CW+:AW];

   assign umi_out_srcaddr[AW-1:0] = cmd_only ? {AW{1'b0}} :
                                               shiftreg[(CW+AW)+:AW];

   assign umi_out_data[DW-1:0] = (cmd_only | no_data) ? {DW{1'b0}}              :
                                                        shiftreg[(CW+AW+AW)+:DW];

   // link commands are not passed on to the umi port
   assign umi_out_valid =  transfer & ~(cmd_link | cmd_link_resp);

   //########################################
   //# SPLIT OUT UMI_RESP/UMI_REQ TRAFFIC
   //########################################

   /*umi_splitter AUTO_TEMPLATE(
    .umi_in_\(.*\)       (umi_out_\1[]),
    );*/
   umi_splitter #(.DW(DW),
                  .CW(CW),
                  .AW(AW))
   umi_splitter(/*AUTOINST*/
                // Outputs
                .umi_in_ready   (umi_out_ready),         // Templated
                .umi_resp_out_valid(umi_resp_out_valid),
                .umi_resp_out_cmd(umi_resp_out_cmd[CW-1:0]),
                .umi_resp_out_dstaddr(umi_resp_out_dstaddr[AW-1:0]),
                .umi_resp_out_srcaddr(umi_resp_out_srcaddr[AW-1:0]),
                .umi_resp_out_data(umi_resp_out_data[DW-1:0]),
                .umi_req_out_valid(umi_req_out_valid),
                .umi_req_out_cmd(umi_req_out_cmd[CW-1:0]),
                .umi_req_out_dstaddr(umi_req_out_dstaddr[AW-1:0]),
                .umi_req_out_srcaddr(umi_req_out_srcaddr[AW-1:0]),
                .umi_req_out_data(umi_req_out_data[DW-1:0]),
                // Inputs
                .umi_in_valid   (umi_out_valid),         // Templated
                .umi_in_cmd     (umi_out_cmd[CW-1:0]),   // Templated
                .umi_in_dstaddr (umi_out_dstaddr[AW-1:0]), // Templated
                .umi_in_srcaddr (umi_out_srcaddr[AW-1:0]), // Templated
                .umi_in_data    (umi_out_data[DW-1:0]),  // Templated
                .umi_resp_out_ready(umi_resp_out_ready),
                .umi_req_out_ready(umi_req_out_ready));

endmodule
// Local Variables:
// verilog-library-directories:("." "../../umi/rtl/" "../../../lambdalib/ramlib/rtl/")
// End:
