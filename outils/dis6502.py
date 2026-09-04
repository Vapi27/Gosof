#!/usr/bin/env python3
"""dis6502.py — desassembleur 6502 minimal pour les ROM de carte son Gottlieb MA-216.

    python3 outils/dis6502.py <jeu> reads            # toutes les lectures du port B du RIOT
    python3 outils/dis6502.py <jeu> dis F010 F0D0    # desassemble [debut, fin) en hexa

Les ROM (<jeu>_rom1.bin, <jeu>_rom2.bin, 2 Ko chacune) vivent dans ~/gosof-roms,
HORS du depot : c'est du code Gottlieb. ROM1 est vue en $F000, ROM2 en $F800
(A15 est ignoree par le decodage de GOSOF80.vhd : $7000/$7800 sont les memes).

CARTE DE LA MA-216 TELLE QUE LE ROM LA VOIT (etablie sur Mars et Volcano) :
  $0200-$03FF  RIOT 6532 : $0200 PA (commande de son S1..S32 sur PA0-5, PA7 =
               demande), $0202 PB : PB1 DIP6, PB2 DIP5, PB3 DIP1, PB4 DIP4,
               PB5 DIP3, PB6 poussoir TEST (actif bas), PB7 = /AR du SC-01.
  $1000        DAC 8 bits         $2000  strobe SC-01, donnee EOR #$3F (bus inverse)
  $3000        horloge (hauteur) du SC-01
  Reset $F010 : DDRA=DDRB=0, strobe $00 (= STOP $3F sur le bus inverse), RAM a 0.
  $F03A/$F085 : mode ATTRACT. DIP3 ou DIP4 ON (lu 0) -> apres un compte a rebours
               (DIP3 seul ~10 s, DIP4 seul ~2 min, les deux ~4 min a 895 kHz) le
               jeu dit UNE PHRASE AU HASARD puis repart au reset. Les deux OFF :
               silence au repos.
  $F069       : TEST lu 0 -> routine de test ($FA5B Mars, $FA49 Volcano) : dit
               "TEST", test RAM ("RAM TEST FAILS"), somme des deux ROM ("EPROM ONE
               FAILS" / "EPROM TWO FAILS"), "TURN DIP SWITCHES OFF", "THANK YOU",
               "TURN DIP SWITCHES ON", bips, "TEST COMPLETE". Volcano y fait SEI.
               C'EST LE DIAGNOSTIC EMBARQUE : S4 maintenu a la mise sous tension
               verifie la ROM chargee depuis la SD sans aucun firmware special.
  $F402       : DIP6 lu 1 -> les commandes d'une table de 16 ($F680) sont ignorees
               (vraisemblablement la parole -- non verifie).
  Distributeur de son : table de pointeurs (octet HAUT d'abord) a $F510 (Mars),
  $F64B (Volcano), entree 2*(n-1). Phrases : Mars enregistrements de 8 octets a
  $F660 (pointeur haut-bas en +2,+3) ; Volcano table $F767 -> descripteur de 6
  octets [phrase lo,hi][hauteurs lo,hi][drapeaux][hauteur fixe]. Une phrase est
  une suite de codes SC-01 terminee par $FF ; joueur $FB8B (Mars) / $FB7A (Volcano).
  Aucun rire dans Mars ni Volcano : les phrases d'attract sont "EARTHLING, I AM
  SUPREME", "THE FORCES OF MARS CHALLENGE YOU", "CAN YOU SURVIVE BATTLE WITH
  MARS" ; "IT'S GONNA BLOW", "THROW ME A SACRIFICE", "DANGER... VOLCANO".
"""
import sys
T={}
def add(mn,pairs):
    for op,m in pairs: T[op]=(mn,m)
A8=lambda i,z,zx,a,ax,ay,ix,iy:[(i,'imm'),(z,'zp'),(zx,'zpx'),(a,'abs'),(ax,'abx'),(ay,'aby'),(ix,'izx'),(iy,'izy')]
add('ADC',A8(0x69,0x65,0x75,0x6D,0x7D,0x79,0x61,0x71)); add('AND',A8(0x29,0x25,0x35,0x2D,0x3D,0x39,0x21,0x31))
add('CMP',A8(0xC9,0xC5,0xD5,0xCD,0xDD,0xD9,0xC1,0xD1)); add('EOR',A8(0x49,0x45,0x55,0x4D,0x5D,0x59,0x41,0x51))
add('LDA',A8(0xA9,0xA5,0xB5,0xAD,0xBD,0xB9,0xA1,0xB1)); add('ORA',A8(0x09,0x05,0x15,0x0D,0x1D,0x19,0x01,0x11))
add('SBC',A8(0xE9,0xE5,0xF5,0xED,0xFD,0xF9,0xE1,0xF1)); add('STA',A8(None,0x85,0x95,0x8D,0x9D,0x99,0x81,0x91)[1:])
add('ASL',[(0x0A,'acc'),(0x06,'zp'),(0x16,'zpx'),(0x0E,'abs'),(0x1E,'abx')]); add('LSR',[(0x4A,'acc'),(0x46,'zp'),(0x56,'zpx'),(0x4E,'abs'),(0x5E,'abx')])
add('ROL',[(0x2A,'acc'),(0x26,'zp'),(0x36,'zpx'),(0x2E,'abs'),(0x3E,'abx')]); add('ROR',[(0x6A,'acc'),(0x66,'zp'),(0x76,'zpx'),(0x6E,'abs'),(0x7E,'abx')])
for mn,op in [('BPL',0x10),('BMI',0x30),('BVC',0x50),('BVS',0x70),('BCC',0x90),('BCS',0xB0),('BNE',0xD0),('BEQ',0xF0)]: add(mn,[(op,'rel')])
add('BIT',[(0x24,'zp'),(0x2C,'abs')]); add('JMP',[(0x4C,'abs'),(0x6C,'ind')]); add('JSR',[(0x20,'abs')])
add('CPX',[(0xE0,'imm'),(0xE4,'zp'),(0xEC,'abs')]); add('CPY',[(0xC0,'imm'),(0xC4,'zp'),(0xCC,'abs')])
add('DEC',[(0xC6,'zp'),(0xD6,'zpx'),(0xCE,'abs'),(0xDE,'abx')]); add('INC',[(0xE6,'zp'),(0xF6,'zpx'),(0xEE,'abs'),(0xFE,'abx')])
add('LDX',[(0xA2,'imm'),(0xA6,'zp'),(0xB6,'zpy'),(0xAE,'abs'),(0xBE,'aby')]); add('LDY',[(0xA0,'imm'),(0xA4,'zp'),(0xB4,'zpx'),(0xAC,'abs'),(0xBC,'abx')])
add('STX',[(0x86,'zp'),(0x96,'zpy'),(0x8E,'abs')]); add('STY',[(0x84,'zp'),(0x94,'zpx'),(0x8C,'abs')])
for mn,op in [('BRK',0x00),('CLC',0x18),('CLD',0xD8),('CLI',0x58),('CLV',0xB8),('DEX',0xCA),('DEY',0x88),('INX',0xE8),('INY',0xC8),('NOP',0xEA),
              ('PHA',0x48),('PHP',0x08),('PLA',0x68),('PLP',0x28),('RTI',0x40),('RTS',0x60),('SEC',0x38),('SED',0xF8),('SEI',0x78),
              ('TAX',0xAA),('TAY',0xA8),('TSX',0xBA),('TXA',0x8A),('TXS',0x9A),('TYA',0x98)]: add(mn,[(op,'imp')])
SZ={'imp':1,'acc':1,'imm':2,'zp':2,'zpx':2,'zpy':2,'izx':2,'izy':2,'rel':2,'abs':3,'abx':3,'aby':3,'ind':3}
def sym(a):
    if 0x0200<=a<=0x03FF:
        r=a&7; return {0:'RIOT_PA',1:'RIOT_DDRA',2:'RIOT_PB',3:'RIOT_DDRB'}.get(r,'RIOT_TIMER' if r>=4 else '?')+f'(${a:04X})'
    if 0x1000<=a<=0x1FFF: return f'DAC(${a:04X})'
    if 0x2000<=a<=0x2FFF: return f'SC01_STROBE(${a:04X})'
    if 0x3000<=a<=0x3FFF: return f'SC01_CLK(${a:04X})'
    return f'${a:04X}'
def dis(rom,base,start,end,out=print):
    pc=start
    while pc<end:
        i=pc-base; op=rom[i]
        if op not in T: out(f"  ${pc:04X}: {op:02X}        ???"); pc+=1; continue
        mn,m=T[op]; n=SZ[m]; b=rom[i:i+n]
        if m in('imp',): o=''
        elif m=='acc': o='A'
        elif m=='imm': o=f'#${b[1]:02X}'
        elif m=='zp': o=f'${b[1]:02X}'
        elif m=='zpx': o=f'${b[1]:02X},X'
        elif m=='zpy': o=f'${b[1]:02X},Y'
        elif m=='izx': o=f'(${b[1]:02X},X)'
        elif m=='izy': o=f'(${b[1]:02X}),Y'
        elif m=='rel': t=pc+2+(b[1]-256 if b[1]>127 else b[1]); o=f'${t:04X}'
        else:
            a=b[1]|b[2]<<8; o=sym(a)+{'abx':',X','aby':',Y','ind':' (ind)'}.get(m,'')
        out(f"  ${pc:04X}: {' '.join(f'{x:02X}' for x in b):9s} {mn} {o}")
        pc+=n
if __name__=='__main__':
    jeu=sys.argv[1]; d='/Users/vapi27/gosof-roms/'
    rom=open(d+jeu+'_rom1.bin','rb').read()+open(d+jeu+'_rom2.bin','rb').read(); base=0xF000
    v=lambda o:rom[o]|rom[o+1]<<8
    print(f"== {jeu}: NMI ${v(0xFFA):04X}  RESET ${v(0xFFC):04X}  IRQ ${v(0xFFE):04X}")
    if sys.argv[2]=='reads':
        for i in range(len(rom)-2):
            op,lo,hi=rom[i],rom[i+1],rom[i+2]
            if op in T and T[op][1]=='abs' and hi==0x02 and (lo&7)==2 and T[op][0] in('LDA','BIT','LDX','LDY','AND','ORA','EOR','CMP'):
                print(f"-- ${base+i:04X}"); dis(rom,base,base+i,base+i+min(14,len(rom)-i))
    else:
        dis(rom,base,int(sys.argv[3],16),int(sys.argv[4],16))
