#!/usr/bin/env python3
"""rom_vers_vhdl.py — mettre une ROM de jeu DANS le bitstream.

    python3 outils/rom_vers_vhdl.py ROM1.bin ROM2.bin sortie.vhd [--nom volcano]

POURQUOI CET OUTIL EXISTE. Gosof lit ses ROMs de jeu sur carte SD, et
`SD_Card.vhd:255` est le SEUL endroit du depot qui relache `cpu_reset_l`. Sans
carte valide, le 6502 ne demarre jamais : silence total, sans message. Tant que
la SD est sur le chemin critique, on ne peut rien entendre du tout.

Cet outil enleve la SD du chemin : la ROM devient une constante VHDL, initialisee
a la configuration du FPGA. 4 Ko sur un XC6SLX9 qui a 32 blocs, c'est gratuit.

⚠️ LE FICHIER PRODUIT NE DOIT JAMAIS ETRE COMMITE. Il contient du code Gottlieb.
   Le depot est en GPL et destine a remonter chez bontango : des ROMs de jeu n'y
   ont pas leur place. Ecrivez la sortie HORS de l'arbre versionne (~/gosof-roms
   par exemple) ; .gitignore l'interdit aussi, mais la regle passe avant le filet.

D'OU VIENNENT LES BINAIRES. De l'image SD publiee par bontango
(lisy.dev/swrep/soundboards/GOSOF/SD_image/). Le decoupage est verifie dans le
code, pas suppose :
    GOSOF80.vhd:527   SD_game_sel <= "00" & not game_sel(5 downto 0);
    SD_Card.vhd:189   secteur = numero_de_jeu * 8 + 660
    SD_Card.vhd:329   compteur plat 0..4095 -> ROM1 = 2 premiers Ko, ROM2 les 2 suivants
Recoupement independant : le vecteur de reset tombe a l'offset 0xFFC du bloc de
4 Ko, exactement ou le plan memoire le predit ($FFFC miroite en $7FFC, A15 etant
ignore par le decodage).
"""
import sys, os, hashlib

def lire_2k(chemin):
    with open(chemin, 'rb') as f:
        d = f.read()
    if len(d) != 2048:
        sys.exit(f"{chemin} : {len(d)} octets, il en faut exactement 2048")
    return d

def agregat(d, par_ligne=16):
    """Un agregat VHDL, 16 octets par ligne, avec l'offset en commentaire."""
    lignes = []
    for i in range(0, len(d), par_ligne):
        bloc = ", ".join(f'x"{b:02x}"' for b in d[i:i + par_ligne])
        fin = "," if i + par_ligne < len(d) else ""
        lignes.append(f"\t\t{bloc}{fin}   -- ${i:03X}")
    return "\n".join(lignes)

def main():
    # Analyse a la main : --nom prend une VALEUR, qu il faut retirer AUSSI de la
    # liste des fichiers. Ne pas le faire donnait quatre fichiers au lieu de trois.
    argv, a, nom = sys.argv[1:], [], "inconnu"
    i = 0
    while i < len(argv):
        if argv[i] == "--nom" and i + 1 < len(argv):
            nom = argv[i + 1]; i += 2
        elif argv[i].startswith("--"):
            i += 1
        else:
            a.append(argv[i]); i += 1
    if len(a) != 3:
        sys.exit(__doc__)
    f1, f2, sortie = a

    d1, d2 = lire_2k(f1), lire_2k(f2)

    # CONTROLE, pas decoration. Une ROM toute a zero ou toute a 0xFF se compile
    # parfaitement et donne un 6502 qui execute du vide : exactement le genre de
    # panne que ce projet paie en silence.
    for etiq, d in (("ROM1", d1), ("ROM2", d2)):
        distinct = len(set(d))
        if distinct < 32:
            sys.exit(f"{etiq} n'a que {distinct} valeurs d'octet distinctes : "
                     "ce n'est pas du code 6502, c'est du remplissage. ARRET.")
    # Le vecteur de reset vit a $7FFC = offset 0x7FC de ROM2 (A15 ignore).
    rst = d2[0x7FC] | (d2[0x7FD] << 8)
    if not (0x7000 <= (rst & 0x7FFF) <= 0x7FFF) or (rst & 0xFFFF) in (0x0000, 0xFFFF):
        sys.exit(f"vecteur de reset ${rst:04X} : hors de la plage ROM, ou du "
                 "remplissage. Mauvais fichier, ou mauvais decoupage. ARRET.")

    h1 = hashlib.sha256(d1).hexdigest()
    h2 = hashlib.sha256(d2).hexdigest()

    txt = f'''-- gosof_jeu.vhd — ROM de jeu embarquee dans le bitstream.  << ENGENDRE >>
--
-- Jeu    : {nom}
-- Source : {os.path.basename(f1)} + {os.path.basename(f2)}
-- sha256 : ROM1 {h1}
--          ROM2 {h2}
-- RESET  : ${rst:04X}
--
-- ⚠️ NE PAS COMMITER : contient du code Gottlieb. Voir outils/rom_vers_vhdl.py.
-- ⚠️ NE PAS EDITER A LA MAIN : regenerer avec l'outil.
--
-- JEU_PRESENT sert de garde-fou : gosof80 refuse de se construire en SANS_SD
-- avec le paquet vide, ou le 6502 executerait des zeros sans que rien ne le dise.
library ieee;
use ieee.std_logic_1164.all;
use work.gosof_mem.all;

package gosof_jeu is
\tconstant JEU_PRESENT : boolean := true;
\tconstant JEU_NOM     : string  := "{nom}";
\tconstant JEU_ROM1 : octet_t(0 to 2047) := (
{agregat(d1)}
\t);
\tconstant JEU_ROM2 : octet_t(0 to 2047) := (
{agregat(d2)}
\t);
end gosof_jeu;
'''
    with open(sortie, 'w') as f:
        f.write(txt)

    print(f"  jeu       : {nom}")
    print(f"  ROM1      : {len(set(d1))} valeurs distinctes, sha256 {h1[:12]}")
    print(f"  ROM2      : {len(set(d2))} valeurs distinctes, sha256 {h2[:12]}")
    print(f"  vecteur de reset : ${rst:04X}")
    print(f"  ecrit     : {sortie}  ({os.path.getsize(sortie)} octets)")
    if os.path.abspath(sortie).startswith(os.path.abspath(os.path.dirname(__file__) + "/..")):
        print("  /!\\ ATTENTION : la sortie est DANS l'arbre du depot. Deplacez-la.")

if __name__ == "__main__":
    main()
