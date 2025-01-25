/******************************************************************************
 * Copyright 2020 Zero ASIC Corporation
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * ----
 *
 * Documentation:
 *
 * - This module is a synthesizable module that generate host requests
 *   based on UMI transactions stored in a local RAM.
 *
 * - Valid UMI host transactions from memory, incrementing the memory
 *   read address and sending a UMI transaction whnile 'go' is held high.
 *
 * - The local memory has one host transaction per memory address,
 *   with the following format: [MSB..LSB]
 *   {data, srcaddr, dstaddr, cmd, ctrl}
 *
 * - The data, srcaddr, dstaddr, cmd, ctrl widths are parametrized
 *   via DW,AW,CW.
 *
 * - Bit[0] of the ctrl field indicates a valid transaction. Bits
 *   [7:1] user bits driven out to to the interface
 *
 * - Memory read address loops to zero when it reaches the end of
 *   the memory.
 *
 * - APB access port can be used by an external host to
 *   to read/write from the memory.
 *
 * - Address map is dictated by the MAXWIDTH:
 * - MAXWITH
 *
 * - The memory access priority is:
 *   - apb (highest)
 *   - response
 *   - request (lowest)
 *
 * Dependencies:
 *   - https://github.com/siliconcompiler/lambdalib
 *
 * Demo:
 *
 * >> iverilog umi_stimulus.v -DTB_UMI_TESTER -y . -I. -y
 * >> ./a.out +hexfile="./test0.memh"
 *
 *****************************************************************************/

module umi_tester
  #(// user parameters
    parameter DEPTH = 128,         // memory depth (entries)
    parameter LOOP = 0,            // loop to zero when end reached
    parameter ARGREQ = "hexreq",   // $plusargs for req memh init (optional)
    parameter ARGRESP = "hexresp", // $plusargs for resp memh  init (optional)
    parameter TCW = 8,             // ctrl interface width
    parameter MAXWIDTH = 512,      // bits [256, 512, 1024, 2048]
    // bus parameters
    parameter DW = 256,            // umi data width
    parameter AW = 64,             // umi addr width
    parameter CW = 32,             // umi ctrl width
    parameter RW = 32,             // apb data width
    parameter RAW = 32             // apb address width
    )
   (
    // control
    input            nreset,      // async active low reset
    input            clk,         // clk
    input            en_req,      // enable request generation
    input            en_resp,     // enable response capture
    input [TCW-1:0]  gpio_in,     // gpio inputs to response RAM
    output [TCW-1:0] gpio_out,    // gpio outputs from request RAM
    // apb load interface (optional)
    input [AW-1:0]   apb_paddr,   // address bus
    input            apb_penable, // goes high for cycle 2:n of transfer
    input            apb_pwrite,  // 1=write, 0=read
    input [RW-1:0]   apb_pwdata,  // write data (8, 16, 32b)
    input [3:0]      apb_pstrb,   // (optional) write strobe byte lanes
    input [2:0]      apb_pprot,   // (optional) level of access
    input            apb_psel,    // select signal for each device
    output           apb_pready,  // device ready
    output [RW-1:0]  apb_prdata,  // read data (8, 16, 32b)
    // umi host interface
    output reg       uhost_req_valid,
    output [CW-1:0]  uhost_req_cmd,
    output [AW-1:0]  uhost_req_dstaddr,
    output [AW-1:0]  uhost_req_srcaddr,
    output [DW-1:0]  uhost_req_data,
    input            uhost_req_ready,
    input            uhost_resp_valid,
    input [CW-1:0]   uhost_resp_cmd,
    input [AW-1:0]   uhost_resp_dstaddr,
    input [AW-1:0]   uhost_resp_srcaddr,
    input [DW-1:0]   uhost_resp_data,
    output           uhost_resp_ready
    );

`include "umi_messages.vh"

   // memory parameters
   localparam MAW = $clog2(DEPTH);      // Memory address-width
   localparam MW = DW+2*AW+CW+TCW;      // Memory data width
   localparam LAW = $clog2(MAXWIDTH/8); // Per entry address width

   // file names
   reg [8*128-1:0] memhreq;
   reg [8*128-1:0] memhresp;

   // local state
   reg [MAW-1:0]  test_addr;

   // local wires
   wire [MW-1:0]  mem_req_dout;
   wire [MW-1:0]  mem_req_din;
   wire           mem_req_ce;
   wire [MAW-1:0] mem_req_addr;
   wire [MW-1:0]  mem_req_wmask;

   wire [MW-1:0]  mem_resp_dout;
   wire [MW-1:0]  mem_resp_din;
   wire           mem_resp_ce;
   wire [MAW-1:0] mem_resp_addr;
   wire [MW-1:0]  mem_resp_wmask;

   wire [MW-1:0]  apb_din;
   wire [MW-1:0]  apb_wmask;
   wire           apb_req_beat;
   wire           apb_resp_beat;


   //#####################################################
   // Initialize RAM
   //#####################################################

   initial
     begin
        if($value$plusargs($sformatf("%s=%%s", ARGREQ), memhreq))
          $readmemh(memhreq, ram_req.memory.ram);
        if($value$plusargs($sformatf("%s=%%s", ARGRESP), memhresp))
          $readmemh(memhresp, ram_resp.memory.ram);
     end

   //####################################################
   // Request Generator
   //####################################################
   // 1. Generate memory read requests when go is high
   // 2. Not ready creates a valid bubble at addr stage
   // 3. Stall valid on requst ready signal

   assign test_beat = en_req & uhost_req_ready & ~apb_penable;

   // memory read address
   always @ (posedge clk or negedge nreset)
     if(!nreset)
       test_addr[MAW-1:0] <= 'b0;
     else
       test_addr[MAW-1:0] <= test_addr[MAW-1:0] + test_beat;

   // requests driven on next clock cycle by RAM
   always @ (posedge clk or negedge nreset)
     if(!nreset)
       uhost_req_valid <= 'b0;
     else if(uhost_req_valid & uhost_req_ready)
       uhost_req_valid <= test_beat;

   // assigning RAM output to UMI signals
   assign gpio_out[TCW-1:0]          = mem_req_dout[0+:TCW];
   assign uhost_req_cmd[CW-1:0]      = mem_req_dout[TCW+:CW];
   assign uhost_req_dstaddr[AW-1:0]  = mem_req_dout[(TCW+CW)+:AW];
   assign uhost_req_srcaddr[AW-1:0]  = mem_req_dout[(TCW+CW+AW)+:AW];
   assign uhost_req_data[DW-1:0]     = mem_req_dout[(TCW+CW+2*AW)+:DW];

   //####################################################
   // APB Port
   //####################################################

   // respone RAM placed after request in memory map
   // note address gaps between last byte of data and MAXWIDTH
   // done to avoid odd modulo addressing
   assign apb_req_sel  = apb_psel & apb_paddr[MAW+LAW];
   assign apb_resp_sel = apb_psel & ~apb_paddr[MAW+LAW];

   // avoiding clobbering sdtalled umi request at output
   // (neeeded due to 1 cycle RAM pipeline)
   assign apb_req_beat  = (apb_penable & apb_req_sel & apb_pready);
   assign apb_resp_beat = (apb_penable & apb_resp_sel);

   assign apb_din[MW-1:0] = apb_pwdata[RW-1:0] <<
                            apb_paddr[$clog2(MAXWIDTH)-1:0];

   // TODO: implement
   assign apb_wmask[MW-1:0] = {8{apb_pstrb[3:0]}} <<
                              apb_paddr[LAW-1:0];

   // TODO: implement
   assign apb_prdata[RW-1:0] = mem_req_dout[RW-1:0];

   assign apb_pready = ~(apb_req_sel & uhost_req_valid & ~uhost_req_ready);

   //######################################################
   // REQUEST RAM
   //######################################################

   assign mem_req_ce = apb_req_beat | test_beat;

   assign mem_req_we = apb_req_beat ? apb_pwrite : 1'b0;

   assign mem_req_addr[MAW-1:0] = apb_req_beat ? apb_paddr[LAW+:MAW]:
                                                 test_addr[MAW-1:0];

   assign mem_req_din[MW-1:0] = apb_din;

   assign mem_req_wmask[MW-1:0] = apb_wmask;


   la_spram #(.DW    (MW),      // Memory width
              .AW    (MAW))     // Address width (derived)
   ram_req(// Outputs
           .dout             (mem_req_dout[MW-1:0]),
           // Inputs
           .clk              (clk),
           .ce               (mem_req_ce),
           .we               (mem_req_we),
           .wmask            (mem_req_wmask[MW-1:0]),
           .addr             (mem_req_addr[MAW-1:0]),
           .din              (mem_req_din[MW-1:0]),
           .vss              (1'b0),
           .vdd              (1'b1),
           .vddio            (1'b1),
           .ctrl             (1'b0),
           .test             (1'b0));

   //#########################################################
   // RESPONSE RAM
   //#########################################################

   la_spram #(.DW    (MW),   // Memory width
              .AW    (MAW))  // Address width (derived)
   ram_resp(// Outputs
            .dout             (mem_resp_dout[MW-1:0]),
            // Inputs
            .clk              (clk),
            .ce               (mem_resp_ce),
            .we               (mem_resp_we),
            .wmask            (mem_resp_wmask[MW-1:0]),
            .addr             (mem_resp_addr[MAW-1:0]),
            .din              (mem_resp_din[MW-1:0]),
            .vss              (1'b0),
            .vdd              (1'b1),
            .vddio            (1'b1),
            .ctrl             (1'b0),
            .test             (1'b0));

endmodule
// Local Variables:
// verilog-library-directories:("./" "../../../../lambdalib/lambdalib/ramlib/rtl/")
// End:

//#####################################################################
// A SIMPLE TESTBENCH
//#####################################################################

`ifdef TB_UMI_TESTER

module tb();

   parameter integer RW = 32;
   parameter integer DW = 64;
   parameter integer AW = 64;
   parameter integer CW = 32;
   parameter integer CTRLW = 8;
   parameter integer REGS = 512;
   parameter integer PERIOD = 2;
   parameter integer TIMEOUT = PERIOD * 100;

   //######################################
   // TEST HARNESS
   //######################################

   // waveform dump
   initial
     begin
        $timeformat(-9, 0, " ns", 20);
        $dumpfile("dump.vcd");
        $dumpvars();
        #(TIMEOUT)
        $finish;
     end

   // control sequence
   reg             nreset;
   reg             clk;
   initial
     begin
        #(1)
        nreset = 'b0;
        clk = 'b0;
        go = 'b0;
        #(PERIOD * 10)
        nreset = 1'b1;
        #(PERIOD * 10)
        go = 1'b1;
     end

   // clock
   always
     #(PERIOD/2) clk = ~clk;

   //######################################
   // DUT
   //######################################


   /* umi_tester AUTO_TEMPLATE(
    .uhost_req_\(.*\)  (uhost_req_\1[]),
    .uhost_resp_\(.*\) (uhost_resp_\1[]),
    .\(.*\)            (@"(if (equal vl-dir \\"output\\")  \\"\\" (concat vl-width \\"'b0\\") )"),
    );*/

   /*AUTOWIRE*/
   // Beginning of automatic wires (for undeclared instantiated-module outputs)
   wire [CW-1:0]        uhost_req_cmd;
   wire [DW-1:0]        uhost_req_data;
   wire [AW-1:0]        uhost_req_dstaddr;
   wire [AW-1:0]        uhost_req_srcaddr;
   wire                 uhost_req_valid;
   wire                 uhost_resp_ready;
   // End of automatics
   umi_tester #(.AW(AW),
                  .DW(DW),
                  .RW(CW))
   umi_tester (/*AUTOINST*/
               // Outputs
               .gpio_out        (),                      // Templated
               .apb_pready      (),                      // Templated
               .apb_prdata      (),                      // Templated
               .uhost_req_valid (uhost_req_valid),       // Templated
               .uhost_req_cmd   (uhost_req_cmd[CW-1:0]), // Templated
               .uhost_req_dstaddr(uhost_req_dstaddr[AW-1:0]), // Templated
               .uhost_req_srcaddr(uhost_req_srcaddr[AW-1:0]), // Templated
               .uhost_req_data  (uhost_req_data[DW-1:0]), // Templated
               .uhost_resp_ready(uhost_resp_ready),      // Templated
               // Inputs
               .nreset          (1'b0),                  // Templated
               .clk             (1'b0),                  // Templated
               .en_req          (1'b0),                  // Templated
               .en_resp         (1'b0),                  // Templated
               .gpio_in         (TCW'b0),                // Templated
               .apb_paddr       (AW'b0),                 // Templated
               .apb_penable     (1'b0),                  // Templated
               .apb_pwrite      (1'b0),                  // Templated
               .apb_pwdata      (RW'b0),                 // Templated
               .apb_pstrb       (4'b0),                  // Templated
               .apb_pprot       (3'b0),                  // Templated
               .apb_psel        (1'b0),                  // Templated
               .uhost_req_ready (uhost_req_ready),       // Templated
               .uhost_resp_valid(uhost_resp_valid),      // Templated
               .uhost_resp_cmd  (uhost_resp_cmd[CW-1:0]), // Templated
               .uhost_resp_dstaddr(uhost_resp_dstaddr[AW-1:0]), // Templated
               .uhost_resp_srcaddr(uhost_resp_srcaddr[AW-1:0]), // Templated
               .uhost_resp_data (uhost_resp_data[DW-1:0])); // Templated

endmodule

`endif
