#!/bin/sh
# construire_sirene.sh [repertoire] [broche]   -- defaut : P44
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
R=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-/tmp/sirene}; BROCHE=${2:-P44}; C=xc6slx9-2-tqg144
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"; cd "$D"
sed "s/LOC = \"P44\"/LOC = \"$BROCHE\"/" "$R/variants/spartan6_smartfa/sirene.ucf" > sirene.ucf
echo "   broche de sortie : $BROCHE"
echo "vhdl work \"$R/rtl/spartan6/sirene.vhd\"" > s.prj
printf 'set -tmpdir "%s/xst/projnav.tmp"\nset -xsthdpdir "%s/xst"\nrun\n-ifn %s/s.prj\n-ofn sirene\n-ofmt NGC\n-p %s\n-top sirene\n-ifmt mixed\n-iobuf YES\n' "$D" "$D" "$D" "$C" > s.xst
$X/xst -intstyle silent -ifn s.xst -ofn sirene.syr > xst.log 2>&1 || true
grep -qE '^ERROR' sirene.syr && { grep -hE '^ERROR' sirene.syr|head -5; exit 1; } || true
$X/ngdbuild -intstyle silent -p $C -uc sirene.ucf sirene.ngc sirene.ngd > /dev/null
$X/map -intstyle silent -p $C -w -o m.ncd sirene.ngd sirene.pcf > /dev/null
$X/par -w -intstyle silent m.ncd sirene.ncd sirene.pcf > /dev/null
$X/bitgen -w -intstyle silent -g StartupClk:Cclk -g DriveDone:Yes \
    -g UnusedPin:Pulldown -g ConfigRate:16 sirene.ncd sirene.bit sirene.pcf > /dev/null
grep -q "UnusedPin *| *Pulldown" sirene.bgn || { echo "BITGEN : tirage inattendu, ARRET"; exit 1; }
printf 'setMode -bs\nsetCable -port svf -file %s/sirene.svf\naddDevice -p 1 -file %s/sirene.bit\nprogram -p 1\nquit\n' "$D" "$D" > c.cmd
$X/impact -batch c.cmd > impact.log 2>&1 || { echo "IMPACT a echoue"; exit 1; }
sed 's://.*$::' sirene.svf > sirene_clean.svf
grep -iE "^\|$BROCHE |son |clk_50" sirene_pad.txt | cut -c1-70
echo "=== termine ==="
