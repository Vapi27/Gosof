#!/usr/bin/env python3
"""Convertit la capture du banc (un entier signe 18 bits par ligne) en WAV 16 bits.

Verifie CE QUE contient le son, pas seulement qu'un fichier est sorti :
pic, energie, et proportion d'echantillons non nuls sont affiches. Un pic a 0
veut dire que le coeur n'a rien produit -- le WAV serait un silence credible.
"""
import sys, struct, wave

src, dst = sys.argv[1], sys.argv[2]
fe = int(sys.argv[3]) if len(sys.argv) > 3 else 192000

v = [int(x) for x in open(src) if x.strip()]
if not v:
    sys.exit("capture vide")

pic = max(abs(min(v)), abs(max(v)))
non_nuls = sum(1 for x in v if x != 0)
moy = sum(abs(x) for x in v) / len(v)
duree = len(v) / fe

print(f"echantillons : {len(v)}  ({duree:.2f} s a {fe} Hz)")
print(f"pic          : {pic}   (pleine echelle 18 bits = 131071)")
print(f"non nuls     : {non_nuls} ({100*non_nuls/len(v):.1f} %)")
print(f"amplitude moy: {moy:.0f}")

if pic == 0:
    sys.exit("PIC A ZERO : le coeur n'a produit AUCUN son. WAV non ecrit.")

# normalisation a -3 dBFS, sans ecreter
g = (32767 * 0.7071) / pic
with wave.open(dst, 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(fe)
    w.writeframes(b''.join(struct.pack('<h', max(-32768, min(32767, int(x * g)))) for x in v))
print(f"ecrit        : {dst}  (gain {g:.2f}, normalise a -3 dBFS)")
