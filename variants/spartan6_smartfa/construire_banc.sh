#!/bin/sh
# construire_banc.sh — banc d'ecoute du SC-01A sur XC6SLX9 (Pstore Smart FA V1.0).
#                      A lancer sur la machine qui porte ISE 14.7.
#
# Produit un .svf de chargement SRAM. VOLATIL, ET C'EST VOULU : on coupe
# l'alimentation et il n'en reste rien. La flash de configuration U5 n'est PAS
# gravee — sinon la carte demarrerait sur ce banc au lieu de son firmware, et il
# faudrait la regraver pour revenir en arriere. Pour un essai, non.
#
# /!\ UnusedPin:Pulldown N'EST PAS UN DETAIL. Les broches non utilisees sortent
#     sur P1-P4. Sur le module Smart FA les grilles des MOSFET de bobines sont
#     actives au niveau HAUT : un Pullup les met sous tension — c'est deja
#     arrive, une bobine a chauffe. Couper l'alimentation de puissance malgre
#     tout, HSWAPEN etant tire a la masse (toutes les broches montent pendant la
#     configuration, quoi qu'on demande a bitgen).
#     Ce banc n'utilise que 5 broches sur 102 : 97 sont donc concernees.
#
# /!\ NE JAMAIS alimenter l USB et P6 en meme temps : meme noeud +5 V, sans diode.
#
# /!\ Le sourcing de settings64.sh d'ISE reference des variables non definies : il
#     TUE un shell en `set -u`. D'ou `set -e` seul, et l'appel des binaires par
#     chemin absolu — meme forme que construire.sh de WillFA7, qui marche.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
[ -x "$X/xst" ] || { echo "ISE introuvable dans $ISE (poser ISE=...)"; exit 1; }

R=$(cd "$(dirname "$0")/../.." && pwd)      # racine du depot
D=${1:-/tmp/banc_sc01}
COMPOSANT=xc6slx9-2-tqg144
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"
cp "$R/variants/spartan6_smartfa/banc_sc01.ucf" "$D/"

# --- liste des sources -------------------------------------------------------
# Le strict necessaire pour produire du son : le coeur SC-01A, ses ROMs de
# coefficients, le DDS, la colle, le melangeur et le DAC. Ni SD, ni ROM de jeu,
# ni 6502, ni GOSOF80.
: > "$D/banc.prj"
for f in rtl/votrax/sc01a_coeff_scales_pkg.vhd \
         rtl/votrax/f1_rom.vhd rtl/votrax/f2v_rom.vhd rtl/votrax/f2n_rom.vhd \
         rtl/votrax/f3_rom.vhd rtl/votrax/f4_rom.vhd rtl/votrax/fn_rom.vhd \
         rtl/votrax/fx_rom.vhd rtl/votrax/sc01_rom.vhd rtl/votrax/sc01a_rom.vhd \
         rtl/votrax/iir_filter_slow.vhd rtl/votrax/sc01a_filter.vhd \
         rtl/votrax/sc01a_resamp.vhd rtl/votrax/sc01a.vhd \
         rtl/spartan6/sc01_dds.vhd rtl/spartan6/sc01_glue.vhd \
         rtl/spartan6/audio_mix.vhd dac.vhd \
         rtl/spartan6/banc_sc01.vhd; do
  echo "vhdl work \"$R/$f\"" >> "$D/banc.prj"
done

cat > "$D/banc.xst" <<FIN
set -tmpdir "$D/xst/projnav.tmp"
set -xsthdpdir "$D/xst"
run
-ifn $D/banc.prj
-ofn banc_sc01
-ofmt NGC
-p $COMPOSANT
-top banc_sc01
-opt_mode Speed
-opt_level 1
-ifmt mixed
-iobuf YES
FIN

cd "$D"
echo "== 1/6 synthese (xst) =="
$X/xst -intstyle silent -ifn banc.xst
grep -E '^ERROR' banc_sc01.syr | head -12 && { echo "XST : erreurs, ARRET"; exit 1; } || true

echo "== 2/6 ngdbuild =="
$X/ngdbuild -intstyle silent -p $COMPOSANT -uc banc_sc01.ucf banc_sc01.ngc banc_sc01.ngd

echo "== 3/6 map =="
$X/map -intstyle silent -p $COMPOSANT -detail -pr b -w -o banc_map.ncd banc_sc01.ngd banc_sc01.pcf

echo "== 4/6 par (placement-routage) =="
$X/par -w -intstyle silent banc_map.ncd banc_sc01.ncd banc_sc01.pcf

echo "== 5/6 timing =="
$X/trce -intstyle silent -v 10 banc_sc01.ncd banc_sc01.pcf -o banc_sc01.twr || true
# Le timing doit etre TENU, pas seulement calcule : une contrainte ratee ici
# donne un circuit qui parle de travers sans rien signaler.
if grep -qE '[1-9][0-9]* +(timing )?errors? detected' banc_sc01.twr 2>/dev/null; then
  echo "TIMING NON TENU — voir $D/banc_sc01.twr"; grep -E 'errors? detected' banc_sc01.twr; exit 1
fi

echo "== 6/6 bitgen puis SVF =="
$X/bitgen -w -intstyle silent \
    -g StartupClk:Cclk -g DriveDone:Yes -g UnusedPin:Pulldown -g ConfigRate:16 \
    banc_sc01.ncd banc_sc01.bit banc_sc01.pcf
# Ce controle n'est pas decoratif : c'est la ligne qui protege les bobines.
grep -q "UnusedPin *| *Pulldown" banc_sc01.bgn || { echo "BITGEN : tirage inattendu, ARRET"; exit 1; }

# LE .BIT NE SUFFIT PAS. Par le pont XVC de l'ESP, un .bit se charge a 100 %,
# sans erreur, et DONE reste bas : le design ne demarre JAMAIS. Il faut un .svf.
# C'est un piege paye sur le projet, pas une precaution theorique.
cat > s.cmd <<CMD
setMode -bs
setCable -port svf -file $D/banc_sc01.svf
addDevice -p 1 -file $D/banc_sc01.bit
program -p 1
quit
CMD
$X/impact -batch s.cmd > impact.log 2>&1 || { echo "IMPACT a echoue, voir $D/impact.log"; exit 1; }
[ -s banc_sc01.svf ] || { echo "IMPACT n'a PAS ecrit le SVF (il ne le fait pas toujours seul), voir impact.log"; exit 1; }
# Commentaires retires : openFPGALoader et impact sont plus surs sans -- un
# commentaire avalait l'ordre suivant en silence lors d'une mise au point.
sed 's://.*$::' banc_sc01.svf > banc_sc01_clean.svf

echo
echo "== place =="
sed -n '/Device utilization summary/,/^Partition/p' banc_sc01.syr |
  grep -E 'Number of|Slice|LUT|RAMB|IOs' | head -16
echo "== periode =="
grep -A2 'Minimum period' banc_sc01.syr | head -4
echo
echo "== termine =="
echo "   $D/banc_sc01.bit"
echo "   $D/banc_sc01_clean.svf   <- c'est CELUI-CI qu'on charge"
echo "   SVF : $(wc -l < banc_sc01.svf) lignes, nettoye : $(wc -l < banc_sc01_clean.svf)"
echo
echo "   Chargement (SRAM, volatil), APRES avoir coupe le 43 V :"
echo "     openFPGALoader --cable xvc-client --ip <ip-esp> --port 2542 $D/banc_sc01_clean.svf"
