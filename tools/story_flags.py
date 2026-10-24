#!/usr/bin/env python3
"""List where the map overlays set, clear and test story progress bits.

Story progress is a u32 per area (chapter) at 0x8011b7d0 + area * 4. Map
scripts change it through resident routines (set 0x801917d4, clear
0x801917fc, test 0x80191828; a0 = the word's address, a1 = bit). This scans
every overlay for calls to them, tracking a0/a1 through lui/addiu/ori within
straight-line code, and prints per overlay the bits it touches:
  set4:[0, 12]  = sets area 4 bits 0 and 12

Usage: python3 -I story_flags.py <overlays dir>
"""
import collections
import glob
import os
import struct
import sys

O = sys.argv[1] if len(sys.argv) == 2 else sys.exit(__doc__)
LO,HI=0x8011b7d0,0x8011b878
FN={0x801917d4:'set',0x801917fc:'clr',0x80191828:'tst'}
src={}
for line in open(O+'/manifest.tsv').read().splitlines()[1:]:
    c=line.split('\t'); src[c[0]]=c[5] if len(c)>5 else ''
out=[]
for p in sorted(glob.glob(O+'/ov_*.bin')):
    d=open(p,'rb').read(); name=os.path.basename(p); base=int(name.split('_')[1],16)
    W=[struct.unpack_from('<I',d,i)[0] for i in range(0,len(d)-3,4)]
    reg={}; res=collections.defaultdict(set)
    for k,x in enumerate(W):
        op=x>>26;rt=(x>>16)&31;rs=(x>>21)&31;rd=(x>>11)&31;imm=x&0xffff;simm=imm-0x10000 if imm&0x8000 else imm
        if op==15: reg[rt]=imm<<16
        elif op==9:
            v=0 if rs==0 else reg.get(rs)
            reg[rt]=None if v is None else (v+simm)&0xffffffff
        elif op==13 and rs==0: reg[rt]=imm
        elif op==0 and (x&63) in (33,37) and ((x>>16)&31)==0: reg[rd]=reg.get(rs)
        elif op==3:
            t=((x&0x3ffffff)<<2)|0x80000000
            if t in FN and k+1<len(W):
                # delay slot
                y=W[k+1]
                if y>>26==9 and (y>>21)&31==0: reg[(y>>16)&31]=y&0xffff
                a0=reg.get(4); a1=reg.get(5)
                if a0 is not None and LO<=a0<HI and a1 is not None:
                    res[(FN[t],(a0-LO)//4)].add(a1+(a0-LO)%4*8)
            for r in (2,3,4,5,6,7,8,9,10,11,12,13,14,15,24,25): reg.pop(r,None)
        elif op in (35,36,37,32,33): reg[rt]=None
        if x==0x03e00008: reg={}
    if res:
        print(name[3:], src.get(name,'').split('/')[-1][:24], ' '.join('%s%d:%s'%(k[0],k[1],sorted(v)) for k,v in sorted(res.items())))
