/*******************************************************************************
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
 * - Testbench driver wrapper for switchboard
 *
 ******************************************************************************/

module umi_testbench (
        input clk,
        input nreset
);
        // UMI RX port

        wire [255:0] umi_packet_rx;
        wire umi_valid_rx;
        wire umi_ready_rx;

        // UMI TX port

        wire [255:0] umi_packet_tx;
        wire umi_valid_tx;
        wire umi_ready_tx;

        umi_rx_sim rx_i (
                .clk(clk),
                .ready(umi_ready_rx), // input
                .packet(umi_packet_rx), // output
                .valid(umi_valid_rx) // output
        );

        umi_tx_sim tx_i (
                .clk(clk),
                .ready(umi_ready_tx), // output
                .packet(umi_packet_tx), // input
                .valid(umi_valid_tx) // input
        );

        `MOD_UNDER_TEST uut (
                .clk(clk),
                .nreset(nreset),

                .rx0_umi_valid(umi_valid_rx),
                .rx0_umi_packet(umi_packet_rx),
                .rx0_umi_ready(umi_ready_rx),

                .tx0_umi_valid(umi_valid_tx),
                .tx0_umi_packet(umi_packet_tx),
                .tx0_umi_ready(umi_ready_tx)
        );

        string rx_port;
        string tx_port;

`ifdef TRACE
        initial begin
                $dumpfile("umi_testbench.vcd");
                $dumpvars;
        end
`endif

        initial begin
                // read command-line arguments, setting defaults as needed

                if (!$value$plusargs("rx_port=%s", rx_port)) begin
                        rx_port = "queue-5555";
                end

                if (!$value$plusargs("tx_port=%s", tx_port)) begin
                        tx_port = "queue-5556";
                end

                // initialize UMI according to command-line arguments

                /* verilator lint_off IGNOREDRETURN */
                rx_i.init(rx_port);
                tx_i.init(tx_port);
                /* verilator lint_on IGNOREDRETURN */
        end

endmodule
