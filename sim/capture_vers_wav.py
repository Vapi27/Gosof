#!/usr/bin/env python3
"""capture_vers_wav.py — la capture d'un banc (un entier par fenetre) en WAV.

    python3 sim/capture_vers_wav.py capture.txt sortie.wav [fe]

Les bancs de ce depot ne s'echantillonnent pas : ils FILTRENT le flux
delta-sigma 1 bit en comptant les '1' par fenetre, comme le fera le RC 3,3 kOhm /
4,7 nF de dac.vhd. Une valeur par fenetre, centree sur zero.

Ce convertisseur REFUSE d'ecrire un fichier si le son ne varie pas -- un WAV de
silence est parfaitement credible, et c'est exactement le piege de ce projet :
un flux bloque a '0' et un flux a 'X' se ressemblent, et les deux donnent un
fichier qui s'ouvre sans rien dire.
"""
import sys, struct, wave

src = sys.argv[1]
dst = sys.argv[2]
fe  = int(sys.argv[3]) if len(sys.argv) > 3 else 192307

v = []
for l in open(src):
    try:
        v.append(int(l.strip()))
    except ValueError:
        pass                      # derniere ligne coupee en cours d'ecriture
if not v:
    sys.exit("capture vide")

pic  = max(abs(min(v)), abs(max(v)))
dist = len(set(v))
nz   = sum(1 for x in v if x != 0)

print(f"echantillons : {len(v)}  ({len(v)/fe:.3f} s a {fe} Hz)")
print(f"plage        : {min(v)} .. {max(v)}   pic {pic}")
print(f"niveaux      : {dist} valeurs distinctes")
print(f"non nuls     : {nz} ({100*nz/len(v):.1f} %)")

if pic == 0:
    sys.exit("PIC A ZERO : rien n'est sorti du DAC. WAV non ecrit.")
if dist < 3:
    sys.exit(f"SEULEMENT {dist} niveau(x) : le DAC idle, ce n'est pas un son. "
             "WAV non ecrit.")

g = (32767 * 0.7071) / pic
with wave.open(dst, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(fe)
    w.writeframes(b''.join(struct.pack('<h', max(-32768, min(32767, int(x * g))))
                           for x in v))
print(f"ecrit        : {dst}  (gain {g:.2f}, normalise a -3 dBFS)")
