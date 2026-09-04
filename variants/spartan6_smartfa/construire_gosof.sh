#!/bin/sh
# construire_gosof.sh — GOSOF COMPLET sur XC6SLX9 (Pstore Smart FA V1.0).
#
#   sh construire_gosof.sh [repertoire] [paquet_jeu.vhd]
#
# Le paquet du jeu est ENGENDRE par outils/rom_vers_vhdl.py et vit HORS du depot
# (~/gosof-roms) : il contient du code Gottlieb, le depot est en GPL et destine a
# remonter chez bontango. Sans argument, on prend le paquet VIDE -- et gosof80
# s'arrete alors de lui-meme, son garde-fou refusant SANS_SD avec des ROMs a zero.
#
# CE QUE CE BUILD REGLE. gosof80 n'a JAMAIS ete place-route. La mesure publiee
# jusqu'ici (4326 LUT, 56,3 MHz) vient de xst SEUL, sans contrainte de broches et
# sans placement. Un design a 75 % de LUT peut tres bien ne pas tenir les 20 ns.
# C'est ici que ca se sait, avec un vrai chiffre.
#
# LE .UCF EST CELUI DU BANC SC-01A, et ce n'est pas de la paresse : les noms de
# nets sont identiques (clk_50, reset_sw, audio_p43..47). Deux fichiers jumeaux
# divergeraient au premier changement de brochage.
#
# /!\ UnusedPin:Pulldown N'EST PAS UN DETAIL. Les broches non utilisees sortent
#     sur P1-P4. Sur le module Smart FA les grilles des MOSFET de bobines sont
#     actives au niveau HAUT : un Pullup les met sous tension -- c'est deja
#     arrive, une bobine a chauffe. Couper l'alimentation de puissance malgre
#     tout, HSWAPEN etant tire a la masse.
#
# /!\ NE JAMAIS alimenter l USB et P6 en meme temps : meme noeud +5 V, sans diode.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
[ -x "$X/xst" ] || { echo "ISE introuvable dans $ISE (poser ISE=...)"; exit 1; }

R=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-/tmp/gosof_banc}
JEU=${2:-$R/rtl/spartan6/gosof_jeu_vide.vhd}
COMPOSANT=xc6slx9-2-tqg144
[ -f "$JEU" ] || { echo "paquet de jeu introuvable : $JEU"; exit 1; }
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"
cp "$R/variants/spartan6_smartfa/banc_sc01.ucf" "$D/gosof_banc.ucf"
echo "   jeu : $(basename "$JEU")"

# --- sources : gosof80 EN ENTIER, plus le sommet de banc ----------------------
: > "$D/g.prj"
for f in rtl/spartan6/gosof_mem.vhd \
         rtl/spartan6/gosof_rom_ram.vhd rtl/spartan6/gosof_roms.vhd \
         rtl/votrax/sc01a_coeff_scales_pkg.vhd \
         rtl/votrax/f1_rom.vhd rtl/votrax/f2v_rom.vhd rtl/votrax/f2n_rom.vhd \
         rtl/votrax/f3_rom.vhd rtl/votrax/f4_rom.vhd rtl/votrax/fn_rom.vhd \
         rtl/votrax/fx_rom.vhd rtl/votrax/sc01_rom.vhd rtl/votrax/sc01a_rom.vhd \
         rtl/votrax/iir_filter_slow.vhd rtl/votrax/sc01a_filter.vhd \
         rtl/votrax/sc01a_resamp.vhd rtl/votrax/sc01a.vhd \
         rtl/spartan6/sc01_dds.vhd rtl/spartan6/sc01_glue.vhd \
         rtl/spartan6/audio_mix.vhd \
         lib_common/T65_Pack.vhd lib_common/T65_MCode.vhd lib_common/T65_ALU.vhd \
         lib_common/T65.vhd lib_common/R6532.vhd \
         SPI_Master.vhd SD_Card.vhd DFPlayer_Mini_CMD.vhd Votrax-SC01.vhd \
         background_sound.vhd cpu_clk_gen.vhd dac.vhd dac_dsm2.vhd \
         slow_to_fast_clock_bus.vhd uart_clk_gen.vhd GOSOF80.vhd \
         rtl/spartan6/gosof_banc.vhd; do
  echo "vhdl work \"$R/$f\"" >> "$D/g.prj"
done
# le paquet du jeu doit passer AVANT gosof_rom_ram (qui l'utilise) : on le glisse
# en tete plutot que de le mettre dans la boucle.
sed -i "1i vhdl work \"$JEU\"" "$D/g.prj"

cat > "$D/g.xst" <<FIN
set -tmpdir "$D/xst/projnav.tmp"
set -xsthdpdir "$D/xst"
run
-ifn $D/g.prj
-ofn gosof_banc
-ofmt NGC
-p $COMPOSANT
-top gosof_banc
-opt_mode Speed
-opt_level 1
-ifmt mixed
-iobuf YES
FIN

cd "$D"
echo "== 1/6 synthese (xst) =="
$X/xst -intstyle silent -ifn g.xst -ofn gosof_banc.syr > xst.log 2>&1 || true
if grep -qE '^ERROR' gosof_banc.syr xst.log 2>/dev/null; then
  echo "XST : erreurs, ARRET"; grep -hE '^ERROR' gosof_banc.syr xst.log | head -12; exit 1
fi

# GARDE-FOU DE TAILLE. Une entree de melangeur devenue constante avait deja fait
# supprimer tout le SC-01A -- 102 LUT au lieu de 3242, sans une seule ERROR. Ici
# le sommet complet doit peser bien plus : en dessous de 3500 LUT il manque des
# morceaux, et le bitstream se construirait quand meme.
LUTS=$(grep -oE "Number of Slice LUTs: *[0-9]+" gosof_banc.syr | grep -oE "[0-9]+$" | head -1)
if [ -z "$LUTS" ] || [ "$LUTS" -lt 3500 ]; then
  echo "SYNTHESE EFFONDREE : ${LUTS:-?} LUT (attendu > 4000). Des blocs ont ete supprimes."
  grep -cE "WARNING:Xst:2677" gosof_banc.syr | sed "s/^/  noeuds non connectes : /"
  exit 1
fi
echo "   place : $LUTS LUT"

echo "== 2/6 ngdbuild =="
$X/ngdbuild -intstyle silent -p $COMPOSANT -uc gosof_banc.ucf gosof_banc.ngc gosof_banc.ngd

echo "== 3/6 map =="
$X/map -intstyle silent -p $COMPOSANT -detail -pr b -w -o g_map.ncd gosof_banc.ngd gosof_banc.pcf

echo "== 4/6 par (placement-routage) =="
# C'EST ICI QUE SE SOLDE LA QUESTION OUVERTE : gosof80 tient-il vraiment ?
$X/par -w -intstyle silent g_map.ncd gosof_banc.ncd gosof_banc.pcf

echo "== 5/6 timing =="
$X/trce -intstyle silent -v 10 gosof_banc.ncd gosof_banc.pcf -o gosof_banc.twr || true
if grep -qE '[1-9][0-9]* +(timing )?errors? detected' gosof_banc.twr 2>/dev/null; then
  echo "TIMING NON TENU — voir $D/gosof_banc.twr"; grep -E 'errors? detected' gosof_banc.twr; exit 1
fi
grep -m1 -E "All constraints were met|constraints were not met" gosof_banc.par | sed 's/^/   /'

# ERRATUM 9K, VERIFIE SUR LE DESIGN PLACE. AR 34712 vise le mode SIMPLE DUAL PORT ;
# bitgen avertit pour TOUT RAMB8BWER, ce qui est plus large que l'erratum. On lit
# donc le mode reellement configure, pas le simple fait qu'un bloc existe.
$X/xdl -ncd2xdl gosof_banc.ncd gosof_banc.xdl > /dev/null 2>&1 || true
if [ -s gosof_banc.xdl ]; then
  echo "   blocs de 9 K places : $(grep -cE '^inst .*RAMB8BWER' gosof_banc.xdl)"
  if grep -A80 "RAMB8BWER" gosof_banc.xdl | grep -qiE "RAM_MODE:+[^:]*:SDP"; then
    echo "   /!\\ un bloc de 9 K est en SIMPLE DUAL PORT : erratum AR 34712 APPLICABLE, ARRET"
    exit 1
  fi
  echo "   aucun bloc de 9 K en mode SDP -> erratum AR 34712 hors sujet ici."
else
  echo "   /!\\ xdl n a pas produit de netlist : mode des blocs NON VERIFIE."
fi

echo "== 6/6 bitgen puis SVF =="
$X/bitgen -w -intstyle silent \
    -g StartupClk:Cclk -g DriveDone:Yes -g UnusedPin:Pulldown -g ConfigRate:16 \
    gosof_banc.ncd gosof_banc.bit gosof_banc.pcf
grep -q "UnusedPin *| *Pulldown" gosof_banc.bgn || { echo "BITGEN : tirage inattendu, ARRET"; exit 1; }

# LE .BIT NE SUFFIT PAS : par le pont XVC de l'ESP il se charge a 100 %, sans
# erreur, et DONE reste bas. Il faut un .svf. Piege paye sur le projet.
cat > s.cmd <<CMD
setMode -bs
setCable -port svf -file $D/gosof_banc.svf
addDevice -p 1 -file $D/gosof_banc.bit
program -p 1
quit
CMD
$X/impact -batch s.cmd > impact.log 2>&1 || { echo "IMPACT a echoue, voir $D/impact.log"; exit 1; }
[ -s gosof_banc.svf ] || { echo "IMPACT n'a PAS ecrit le SVF, voir impact.log"; exit 1; }
sed 's://.*$::' gosof_banc.svf > gosof_banc_clean.svf

echo
echo "== place, MESUREE APRES PLACEMENT (pas la synthese) =="
grep -E "Slice Registers|Slice LUTs|occupied Slices|RAMB(8|16)BWER|bonded IOB" g_map.mrp | head -8
echo "== periode =="
grep -A2 'Minimum period' gosof_banc.syr | head -4
echo
echo "== termine =="
echo "   $D/gosof_banc_clean.svf   <- c'est CELUI-CI qu'on charge"
echo
echo "   Chargement (SRAM, volatil), APRES avoir coupe le 43 V :"
echo "     PSTORE SVF par USB, ou openFPGALoader --cable xvc-client --ip <esp> --port 2542"
