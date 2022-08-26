![UMI](docs/_images/hokusai.jpg)

# Universal Memory Interface (UMI)

## Overview

* A simple read/write memory interface
* Little Endian byte ordering
* Read requests include full source and destination addreses
* Valid transaction indicated by separate valid bit
* Transaction behavior controlled through 32bit command
* Native 64bit addressing with 32bit compatibilty mode
* 256 bit flit size
* Write always has priority over read

## Transaction Types

!!TODO: Add interrupt support

| Command        | 31:12      |  11:8     |  OPCODE   |
|----------------|------------|-----------|-----------|
| INVALID        | USER[19:0] | SIZE[3:0] | 0000_0000 |
| WRITE-NORMAL   | USER[19:0] | SIZE[3:0] | XXXX_0000 |
| WRITE-RESPONSE | USER[19:0] | SIZE[3:0] | XXXX_0001 |
| WRITE-SIGNAL   | USER[19:0] | SIZE[3:0] | XXXX_0010 |
| WRITE-STREAM   | USER[19:0] | --        | XXXX_0011 |
| WRITE-ACK      | USER[19:0] | --        | XXXX_0100 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_0101 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_0110 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_0111 |
|----------------|------------|-----------|-----------|
| READ           | USER[19:0] | SIZE[3:0] | 0000_1000 |
| ATOMIC-SWAP    | USER[19:0] | SIZE[3:0] | 0000_1001 |
| ATOMIC-ADD     | USER[19:0] | SIZE[3:0] | 0001_1001 |
| ATOMIC-AND     | USER[19:0] | SIZE[3:0] | 0010_1001 |
| ATOMIC-OR      | USER[19:0] | SIZE[3:0] | 0011_1001 |
| ATOMIC-XOR     | USER[19:0] | SIZE[3:0] | 0100_1001 |
| ATOMIC-MAX     | USER[19:0] | SIZE[3:0] | 0101_1001 |
| ATOMIC-MIN     | USER[19:0] | SIZE[3:0] | 0110_1001 |
| ATOMIC-USER    | USER[19:0] | SIZE[3:0] | 1XXX_1001 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_1011 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_1100 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_1101 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_1110 |
| USER           | USER[19:0] | SIZE[3:0] | XXXX_1111 |

## Data Sizes

* The number of bytes transferred is 2^SIZE.
* The range of sizes supported is system dependent.
* The minimum data transfer size if >=AW.

| SIZE    | TRANSER   | NOTE              |
|---------|-----------|-------------------|
| 0       | 1B        | Single byte       |
| 1       | 2B        |                   |
| 2       | 4B        |                   |
| 3       | 8B        |                   |
| 4       | 16B       | 128b single cycle |
| 5       | 32B       |                   |
| 6       | 64B       |                   |
| 7       | 128B      |                   |
| 8       | 256B      | Cache line        |
| ...     | ...       |                   |
| 14      | 16,384B   | >Jumbo frame      |
| 15      | 32,657B   |                   |

## Packet Formats

* Fields: A(address), D(data), S(source address), C(command)


### Single Cycle Write

|AW |255:224 |223:192  |191:160 |159:128 |127:96 |95:64  | 63:32 | 31:0  |
|---|--------|---------|--------|--------|-------|-------|-------|-------|
|64 |A[63:32]|D[127:96]|D[95:64]|D[63:32]|D[31:0]|       |A[31:0]|C[31:0]|
|32 |        |D[127:96]|D[95:64]|D[63:32]|D[31:0]|       |A[31:0]|C[31:0]|

### Single Cycle Read Request

|AW |255:224 |223:192  |191:160 |159:128 |127:96 |95:64  | 63:32 | 31:0  |
|---|--------|---------|--------|--------|-------|-------|-------|-------|
|64 |A[63:32]|S[63:32] |        |        |       |S[31:0]|A[31:0]|C[31:0]|
|32 |        |         |        |        |       |S[31:0]|A[31:0]|C[31:0]|

### Single Cycle Atomic

|AW |255:224 |223:192  |191:160 |159:128 |127:96 |95:64  | 63:32 | 31:0  |
|---|--------|---------|--------|--------|-------|-------|-------|-------|
|64 |A[63:32]|S[63:32] |D[95:64]|D[63:32]|D[31:0]|S[31:0]|A[31:0]|C[31:0]|
|32 |        |         |        |        |D[31:0]|S[31:0]|A[31:0]|C[31:0]|


### Multi Cycle Write

|255:224   |223:192  |191:160 |159:128 |127:96 |95:64     |63:32     | 31:0    |
|----------|---------|--------|--------|-------|----------|----------|----------|
|A[63:32]  |D[127:96]|D[95:64]|D[63:32]|D[31:0]|          |A[31:0]   |C[31:0]   |
|D[159:128]|D[127:96]|D[95:64]|D[63:32]|D[31:0]|D[255:224]|D[223:192]|D[191:160]|

### 802.3 Ethernet Packet (AW=64)

* 112b ethernet header sent on first cycle
* Transaction size set to total ethernet frame + control + 2 empty bytes on first cycle

|255:224   |223:192     |191:160 |159:128 |127:96  |95:64     | 63:32    | 31:0     |
|----------|------------|--------|--------|--------|----------|----------|----------|
|A[63:32]  |00,H[111:96]|H[95:64]|H[63:32]|H[31:0] |          |A[31:0]   |C[31:0]   |
|D[159:128]|D[127:64]   |D[95:64]|D[63:32]|D[31:0] |D[255:224]|D[223:192]|D[191:160]|
|D[159:128]|D[127:64]   |D[95:64]|D[63:32]|D[31:0] |D[255:224]|D[223:192]|D[191:160]|
|D[159:128]|D[127:64]   |D[95:64]|D[63:32]|D[31:0] |D[255:224]|D[223:192]|D[191:160]|
|D[159:128]|D[127:64]   |D[95:64]|D[63:32]|D[31:0] |D[255:224]|D[223:192]|D[191:160]|
|D[159:128]|D[127:64]   |D[95:64]|D[63:32]|D[31:0] |D[255:224]|D[223:192]|D[191:160]|

### CXL.IO Latency Optimized 256B Flit (AW=64)

* 16b cxl header set on first cycle
* Transaction size set to 256 bytes (plus 14 empty byts on first cycle)

|255:224   |223:192  |191:160 |159:128 |127:96   |95:64         | 63:32    | 31:0     |
|----------|---------|--------|--------|---------|--------------|----------|----------|
|A[63:32]  |         |        |        |0,H[15:0]|              |A[31:0]   |C[31:0]   |
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |D[255:224]    |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |0,D[239:224]  |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |D[255:224]    |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |CRC,D[239:224]|D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |D[255:224]    |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |D[255:224]    |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |D[255:224]    |D[223:192]|D[191:160]|
|D[159:128]|D[127:64]|D[95:64]|D[63:32]|D[31:0]  |CRC,M,TLP     |D[223:192]|D[191:160]|

## Ready/valid handshake protocol

![UMI](docs/_images/ready_valid.svg)

## Transaction File Format (AW=64)

* Transactions can be stored as hexfiles readable/writeable by Verilog's
$readmemh/$writememh.
* The recommended file extension is ".memh"
* For $readmemh compatible readers, comments can be embedded using the "//" syntax.
* An optional single byte control field (TV) can be included with each transaction
(right aligned) to indicate the validity (bit[0]==1) and delayed start of
transaction (bit[7:1]) specified clock cyces relative to the previous transaction.

```txt
AAAA_DDDD_DDDD_DDDD_DDDD_XXXX_AAAA_CCCC_TV  // WRITE
AAAA_SSSS_XXXX_XXXX_XXXX_SSSS_AAAA_CCCC_TV  // READ REQUEST
AAAA_SSSS_XXXX_DDDD_DDDD_SSSS_AAAA_CCCC_TV  // ATOMIC
AAAA_DDDD_DDDD_DDDD_DDDD_XXXX_AAAA_CCCC_TV  // WRITE MULTICYCLE
DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_TV  // ...
DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_TV  // ...
DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_DDDD_TV  // ...
```
