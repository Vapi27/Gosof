#!/bin/sh
# Mesure de place de Gosof sur le Spartan-6 du Smart FA (XC6SLX9-2TQG144C).
# A lancer sur la machine qui porte ISE 14.7.                 -- Pstore, 09/2026
#
# SYNTHESE SEULE, volontairement : il n'y a pas encore de .ucf, et la question du
# jour est « est-ce que ca tient », pas « est-ce que ca tourne ». XST donne les
# LUT, les bascules et les blocs memoire sans aucune contrainte de broches.
#
# CE QUE CETTE MESURE VAUT, ET CE QU'ELLE NE VAUT PAS. Les ROMs de jeu ne sont pas
# dans le depot amont ; elles portent ici un motif derive de l'adresse. Le contenu
# ne change ni la logique ni le nombre de blocs, donc la PLACE est juste — mais le
# circuit produit ne jouerait aucun son.
#
# /!\ Le sourcing de settings64.sh d'ISE reference des variables non definies : il
#     TUE un shell en `set -u`. D'ou `set -e` seul, et l'appel des binaires par
#     chemin absolu plutot que par le PATH — meme forme que construire.sh de
#     WillFA7, qui marche.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
[ -x "$X/xst" ] || { echo "ISE introuvable dans $ISE (poser ISE=...)"; exit 1; }

R=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-/tmp/gosof}
COMPOSANT=xc6slx9-2-tqg144
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"

# L'ordre n'importe pas : XST resout les dependances lui-meme.
: > "$D/gosof.prj"
for f in rtl/spartan6/gosof_mem.vhd rtl/spartan6/gosof_rom_ram.vhd \
         rtl/spartan6/gosof_roms.vhd \
         lib_common/T65_Pack.vhd lib_common/T65_MCode.vhd lib_common/T65_ALU.vhd \
         lib_common/T65.vhd lib_common/R6532.vhd \
         SPI_Master.vhd SD_Card.vhd DFPlayer_Mini_CMD.vhd Votrax-SC01.vhd \
         background_sound.vhd cpu_clk_gen.vhd dac.vhd dac_dsm2.vhd \
         slow_to_fast_clock_bus.vhd uart_clk_gen.vhd GOSOF80.vhd; do
  echo "vhdl work \"$R/$f\"" >> "$D/gosof.prj"
done

cat > "$D/gosof.xst" <<FIN
run
-ifn $D/gosof.prj
-ofn $D/gosof80.ngc
-ofmt NGC
-p $COMPOSANT
-top gosof80
-opt_mode Speed
-opt_level 1
-iuc NO
-keep_hierarchy No
-glob_opt AllClockNets
-rtlview No
FIN

echo "== synthese XST =="
cd "$D"
"$X/xst" -ifn "$D/gosof.xst" -ofn "$D/gosof.syr" > "$D/xst.log" 2>&1 || true

echo "== erreurs =="
grep -E '^ERROR' "$D/gosof.syr" | head -12 || echo "  aucune"
echo
echo "== place =="
sed -n '/Device utilization summary/,/^Partition Resource/p' "$D/gosof.syr" |
  grep -E 'Number of|Slice|LUT|RAMB|IOs' | head -16
echo
echo "== horloge la plus contraignante =="
grep -B1 -A4 'Minimum period' "$D/gosof.syr" | head -8
