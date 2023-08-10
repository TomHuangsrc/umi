#!/usr/bin/env python3

# Example illustrating how UMI packets handled in the Switchboard Python binding
# Copyright (C) 2023 Zero ASIC

import numpy as np
from pathlib import Path
from argparse import ArgumentParser
from switchboard import SbDut, UmiTxRx, delete_queue, verilator_run, binary_run

THIS_DIR = Path(__file__).resolve().parent


def build_testbench(topo="2d"):
    dut = SbDut('testbench')

    EX_DIR = Path('..')

    # Set up inputs
    dut.input('testbench_lumi.sv')
    if topo=='2d':
        print("### Running 2D topology ###")
    elif topo=='3d':
        print("### Running 3D topology ###")
    else:
        raise ValueError('Invalid topology')

    dut.input(EX_DIR / 'submodules' / 'switchboard' / 'examples' / 'common' / 'verilator' / 'testbench.cc')
    for option in ['ydir', 'idir']:
        dut.add('option', option, EX_DIR / 'rtl')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'switchboard' / 'examples' / 'common' / 'verilog')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'umi' / 'umi' / 'rtl')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'oh' / 'stdlib' / 'rtl')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'lambdalib' / 'ramlib' / 'rtl')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'lambdalib' / 'stdlib' / 'rtl')
        dut.add('option', option, EX_DIR / '..' / 'submodules' / 'lambdalib' / 'vectorlib' / 'rtl')

    # Verilator configuration
    vlt_config = EX_DIR / 'testbench' / 'config.vlt'
    dut.set('tool', 'verilator', 'task', 'compile', 'file', 'config', vlt_config)
#    dut.set('option', 'relax', True)
    dut.add('tool', 'verilator', 'task', 'compile', 'option', '--prof-cfuncs')
    dut.add('tool', 'verilator', 'task', 'compile', 'option', '-CFLAGS')
    dut.add('tool', 'verilator', 'task', 'compile', 'option', '-DVL_DEBUG')

    # Settings
    dut.set('option', 'trace', True)  # enable VCD (TODO: FST option)

    # Build simulator
    dut.run()

    return dut.find_result('vexe', step='compile')


def main(topo="2d", vldmode="2", rdymode="2", host2dut="host2dut_0.q", dut2host="dut2host_0.q", sb2dut="sb2dut_0.q", dut2sb="dut2sb_0.q", host2dut="host2dut_0.q", dut2host="dut2host_0.q"):
    # clean up old queues if present
    for q in [host2dut, dut2host, sb2dut, dut2sb, host2dut, dut2host]:
        delete_queue(q)

    verilator_bin = build_testbench(topo)

    # launch the simulation
    #verilator_run(verilator_bin, plusargs=['trace'])
    verilator_run(verilator_bin, plusargs=['trace', ('valid_mode', vldmode), ('ready_mode', rdymode)])

    # instantiate TX and RX queues.  note that these can be instantiated without
    # specifying a URI, in which case the URI can be specified later via the
    # "init" method

    sb = UmiTxRx(sb2dut, dut2sb)
    umi = UmiTxRx(host2dut, dut2host)
    host = UmiTxRx(host2dut, dut2host)

    print("### Side Band loc reset ###")
    sb.write(0x7000000C, np.uint32(0x00000000), posted=True)

    # Need to add some delay are reassertion before sending things
    # over serial link
    print("### Read local reset ###")
    val32 = sb.read(0x70000000, np.uint32)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0x00000000

    if topo=='3d':
        print("### configure 8B width ###")
        sb.write(0x70000000, np.uint32(0x00000040), posted=True)

        print("### Read loc ctrl ###")
        val32 = sb.read(0x70000000, np.uint32)
        print(f"Read: 0x{val32:08x}")
        assert val32 == 0x00000040

        print("### configure rmt 8B width ###")
        sb.write(0x60000000, np.uint32(0x00000040), posted=True)

    print("### Rx enable local ###")
    sb.write(0x70000014, np.uint32(0x00000001), posted=True)

    print("### set chipid to 1 ###")
    sb.write(0x60000008, np.uint32(0x00000001), posted=True)

    print("### Rx enable remote ###")
    sb.write(0x60000014, np.uint32(0x00000001), posted=True)

    print("### Tx enable remote ###")
    sb.write(0x60000010, np.uint32(0x00000001), posted=True)

    print("### Tx enable local ###")
    sb.write(0x70000010, np.uint32(0x00000001), posted=True)

    print("### Tx enable credit ###")
    sb.write(0x60000010, np.uint32(0x00000011), posted=True)

    print("### Tx enable credit ###")
    sb.write(0x70000010, np.uint32(0x00000011), posted=True)

    print("### Read rmt ctrl reset ###")
    val32 = sb.read(0x60000000, np.uint32)
    print(f"Read: 0x{val32:08x}")
    if topo=='2d':
        assert val32 == 0x00000000
    if topo=='3d':
        assert val32 == 0x00000040

    print("### UMI WRITES ###")

#    umi.write(0x70, np.arange(32, dtype=np.uint8), srcaddr=0x0000110000000000)
    umi.write(0x70, np.uint64(0xBAADD70DCAFEFACE) , srcaddr=0x0000110000000000)
    host.write(0x0000110000000000, np.uint32(0xABB00BBA), srcaddr=0x0000010000000000)
    umi.write(0x80, np.uint64(0xBAADD80DCAFEFACE), srcaddr=0x0000110000000000)
    host.write(0x0000110000000010, np.uint32(0xABB10BBA), srcaddr=0x0000010000000000)
    umi.write(0x90, np.uint64(0xBAADD90DCAFEFACE), srcaddr=0x0000110000000000)
    host.write(0x0000110000000020, np.uint32(0xABB20BBA), srcaddr=0x0000010000000000)
    umi.write(0xA0, np.uint64(0xBAADDA0DCAFEFACE), srcaddr=0x0000110000000000)
    host.write(0x0000110000000030, np.uint32(0xABB30BBA), srcaddr=0x0000010000000000)
    umi.write(0xB0, np.uint64(0xBAADDB0DCAFEFACE), srcaddr=0x0000110000000000)

    val32 = host.read(0x0000110000000000, np.uint32, srcaddr=0x0000010000000000)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xABB00BBA

    val32 = host.read(0x0000110000000010, np.uint32, srcaddr=0x0000010000000000)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xABB10BBA

    val32 = host.read(0x0000110000000020, np.uint32, srcaddr=0x0000010000000000)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xABB20BBA

    val32 = host.read(0x0000110000000030, np.uint32, srcaddr=0x0000010000000000)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xABB30BBA
    # 1 byte
    wrbuf = np.array([0xBAADF00D], np.uint32).view(np.uint8)
    for i in range(4):
        umi.write(0x10 + i*8, wrbuf[i], srcaddr=0x0000110000000000)

    # 2 bytes
    wrbuf = np.array([0xB0BACAFE], np.uint32).view(np.uint16)
    umi.write(0x40, wrbuf, srcaddr=0x0000110000000000)

    # 4 bytes
    umi.write(0x50, np.uint32(0xDEADBEEF), srcaddr=0x0000110000000000)

    # 8 bytes
    umi.write(0x60, np.uint64(0xBAADD00DCAFEFACE), srcaddr=0x0000110000000000)

    print("### UMI READS ###")

    # 1 byte - the ebrick_core template does not support unaligned byte accesses
    rdbuf = umi.read(0x10, 1, np.uint8, srcaddr=0x0000110000000000)
    val8 = rdbuf.view(np.uint8)[0]
    print(f"Read: 0x{val8:08x}")
    assert val8 == 0x0D

    rdbuf = umi.read(0x18, 1, np.uint8, srcaddr=0x0000110000000000)
    val8 = rdbuf.view(np.uint8)[0]
    print(f"Read: 0x{val8:08x}")
    assert val8 == 0xF0

    rdbuf = umi.read(0x20, 1, np.uint8, srcaddr=0x0000110000000000)
    val8 = rdbuf.view(np.uint8)[0]
    print(f"Read: 0x{val8:08x}")
    assert val8 == 0xAD

    rdbuf = umi.read(0x28, 1, np.uint8, srcaddr=0x0000110000000000)
    val8 = rdbuf.view(np.uint8)[0]
    print(f"Read: 0x{val8:08x}")
    assert val8 == 0xBA

#    import time
#    time.sleep (5)

    # 2 bytes
    rdbuf = umi.read(0x40, 2, np.uint16, srcaddr=0x0000110000000000)
    val32 = rdbuf.view(np.uint32)[0]
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xB0BACAFE

    # 4 bytes
    val32 = umi.read(0x50, np.uint32, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val32:08x}")
    assert val32 == 0xDEADBEEF

    # 8 bytes
    val64 = umi.read(0x60, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADD00DCAFEFACE

    val64 = umi.read(0x70, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADD70DCAFEFACE

    val64 = umi.read(0x80, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADD80DCAFEFACE

    val64 = umi.read(0x90, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADD90DCAFEFACE

    val64 = umi.read(0xA0, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADDA0DCAFEFACE

    val64 = umi.read(0xB0, np.uint64, srcaddr=0x0000110000000000)
    print(f"Read: 0x{val64:016x}")
    assert val64 == 0xBAADDB0DCAFEFACE

    print("### TEST PASS ###")

if __name__ == '__main__':
    parser = ArgumentParser()
    parser.add_argument('--topo', default='2d')
    parser.add_argument('--vldmode', default='2')
    parser.add_argument('--rdymode', default='2')
    args = parser.parse_args()

    main(topo=args.topo,vldmode=args.vldmode,rdymode=args.rdymode)
