#!/bin/sh
# construire_v230.sh [repertoire] [paquet_jeu.vhd] [SANS_SD]
#   GOSOF COMPLET sur porteuse GOSOF 2.30. SANS_SD=true (defaut) : ROM dans le
#   bitstream, mode PROUVE. SANS_SD=false : la carte SD choisit le jeu par les
#   DIP -- portage complet, mais ce chemin n'a JAMAIS ete exerce et son mode de
#   panne est le silence total sans message.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
R=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-/tmp/gosof_v230}; JEU=${2:-$R/rtl/spartan6/gosof_jeu_vide.vhd}; SD=${3:-true}
C=xc6slx9-2-tqg144
[ -f "$JEU" ] || { echo "paquet de jeu introuvable : $JEU"; exit 1; }
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"; cd "$D"
cp "$R/variants/spartan6_smartfa/gosof_v230.ucf" .
echo "   jeu : $(basename "$JEU")   SANS_SD=$SD"
: > g.prj
echo "vhdl work \"$JEU\"" >> g.prj
for f in rtl/spartan6/gosof_mem.vhd rtl/spartan6/gosof_rom_ram.vhd \
         rtl/spartan6/gosof_roms.vhd rtl/votrax/sc01a_coeff_scales_pkg.vhd \
         rtl/votrax/f1_rom.vhd rtl/votrax/f2v_rom.vhd rtl/votrax/f2n_rom.vhd \
         rtl/votrax/f3_rom.vhd rtl/votrax/f4_rom.vhd rtl/votrax/fn_rom.vhd \
         rtl/votrax/fx_rom.vhd rtl/votrax/sc01_rom.vhd rtl/votrax/sc01a_rom.vhd \
         rtl/votrax/iir_filter_slow.vhd rtl/votrax/sc01a_filter.vhd \
         rtl/votrax/sc01a_resamp.vhd rtl/votrax/sc01a.vhd \
         rtl/spartan6/sc01_dds.vhd rtl/spartan6/sc01_glue.vhd \
         rtl/spartan6/audio_mix.vhd lib_common/T65_Pack.vhd lib_common/T65_MCode.vhd \
         lib_common/T65_ALU.vhd lib_common/T65.vhd lib_common/R6532.vhd \
         SPI_Master.vhd SD_Card.vhd DFPlayer_Mini_CMD.vhd Votrax-SC01.vhd \
         background_sound.vhd cpu_clk_gen.vhd dac.vhd dac_dsm2.vhd \
         slow_to_fast_clock_bus.vhd uart_clk_gen.vhd GOSOF80.vhd \
         rtl/spartan6/gosof_v230.vhd; do
  echo "vhdl work \"$R/$f\"" >> g.prj
done
printf 'set -tmpdir "%s/xst/projnav.tmp"\nset -xsthdpdir "%s/xst"\nrun\n-ifn %s/g.prj\n-ofn gosof_v230\n-ofmt NGC\n-p %s\n-top gosof_v230\n-generics {SANS_SD=%s}\n-opt_mode Speed\n-opt_level 1\n-ifmt mixed\n-iobuf YES\n' "$D" "$D" "$D" "$C" "$SD" > g.xst
$X/xst -intstyle silent -ifn g.xst -ofn gosof_v230.syr > xst.log 2>&1 || true
grep -qE '^ERROR' gosof_v230.syr xst.log 2>/dev/null && { grep -hE '^ERROR' gosof_v230.syr xst.log|head -8; exit 1; } || true
LUTS=$(grep -oE "Number of Slice LUTs: *[0-9]+" gosof_v230.syr | grep -oE "[0-9]+$" | head -1)
[ -n "$LUTS" ] && [ "$LUTS" -ge 3500 ] || { echo "SYNTHESE EFFONDREE : ${LUTS:-?} LUT"; exit 1; }
echo "   synthese : $LUTS LUT"
$X/ngdbuild -intstyle silent -p $C -uc gosof_v230.ucf gosof_v230.ngc gosof_v230.ngd > ngd.log 2>&1 || { grep -E "^ERROR" ngd.log|head -8; exit 1; }
$X/map -intstyle silent -p $C -detail -pr b -w -o m.ncd gosof_v230.ngd gosof_v230.pcf > map.log 2>&1 || { grep -E "^ERROR" map.log|head -8; exit 1; }
$X/par -w -intstyle silent m.ncd gosof_v230.ncd gosof_v230.pcf > par.log 2>&1 || { grep -E "^ERROR" par.log|head -8; exit 1; }
$X/trce -intstyle silent -v 10 gosof_v230.ncd gosof_v230.pcf -o gosof_v230.twr > /dev/null 2>&1 || true
grep -m1 -E "All constraints were met|constraints were not met" gosof_v230.par | sed 's/^/   /'
$X/bitgen -w -intstyle silent -g StartupClk:Cclk -g DriveDone:Yes \
    -g UnusedPin:Pulldown -g ConfigRate:16 gosof_v230.ncd gosof_v230.bit gosof_v230.pcf > bg.log 2>&1
grep -q "UnusedPin *| *Pulldown" gosof_v230.bgn || { echo "BITGEN : tirage inattendu, ARRET"; exit 1; }
printf 'setMode -bs\nsetCable -port svf -file %s/gosof_v230.svf\naddDevice -p 1 -file %s/gosof_v230.bit\nprogram -p 1\nquit\n' "$D" "$D" > c.cmd
$X/impact -batch c.cmd > impact.log 2>&1 || { echo "IMPACT a echoue"; exit 1; }
sed 's://.*$::' gosof_v230.svf > gosof_v230_clean.svf
echo "   place : $(grep -oE 'Number of occupied Slices: *[0-9,]+' m.mrp 2>/dev/null | head -1)"
grep -E "Slice Registers|Slice LUTs|occupied Slices|bonded IOB" m.mrp | head -4
echo "   broches posees : $(grep -cE '^\|P[0-9]+ ' gosof_v230_pad.txt) sur le pad report"
echo "=== termine : $D/gosof_v230_clean.svf ==="
