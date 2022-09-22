import os

import siliconcompiler

umi_root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')

def setup():
    '''Generic setup for ASIC build and verification.'''
    chip = siliconcompiler.Chip('umi_mem')
    chip.set('input', 'verilog', 'umi_mem.v')
    chip.add('option', 'ydir', f'{umi_root}/umi/rtl')
    chip.load_target('za_snps_gf12lp')
    return chip
