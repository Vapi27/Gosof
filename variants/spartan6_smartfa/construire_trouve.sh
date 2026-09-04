#!/bin/sh
# construire_trouve.sh — le chercheur de broche audio. Minuscule, quelques secondes.
set -e
ISE=${ISE:-/opt/Xilinx/14.7/ISE_DS}
[ -f "$ISE/settings64.sh" ] && . "$ISE/settings64.sh" >/dev/null 2>&1 || true
X=$ISE/ISE/bin/lin64
R=$(cd "$(dirname "$0")/../.." && pwd)
D=${1:-/tmp/trouve}
C=xc6slx9-2-tqg144
rm -rf "$D"; mkdir -p "$D/xst/projnav.tmp"; cd "$D"
cp "$R/variants/spartan6_smartfa/trouve_audio.ucf" .
echo "vhdl work \"$R/rtl/spartan6/trouve_audio.vhd\"" > t.prj
cat > t.xst <<FIN
set -tmpdir "$D/xst/projnav.tmp"
set -xsthdpdir "$D/xst"
run
-ifn $D/t.prj
-ofn trouve_audio
-ofmt NGC
-p $C
-top trouve_audio
-ifmt mixed
-iobuf YES
FIN
$X/xst -intstyle silent -ifn t.xst -ofn trouve_audio.syr > xst.log 2>&1 || true
grep -qE '^ERROR' trouve_audio.syr && { grep -hE '^ERROR' trouve_audio.syr | head -5; exit 1; } || true
$X/ngdbuild -intstyle silent -p $C -uc trouve_audio.ucf trouve_audio.ngc trouve_audio.ngd > /dev/null
$X/map -intstyle silent -p $C -w -o t_map.ncd trouve_audio.ngd trouve_audio.pcf > /dev/null
$X/par -w -intstyle silent t_map.ncd trouve_audio.ncd trouve_audio.pcf > /dev/null
$X/bitgen -w -intstyle silent -g StartupClk:Cclk -g DriveDone:Yes \
    -g UnusedPin:Pulldown -g ConfigRate:16 trouve_audio.ncd trouve_audio.bit trouve_audio.pcf > /dev/null
grep -q "UnusedPin *| *Pulldown" trouve_audio.bgn || { echo "BITGEN : tirage inattendu, ARRET"; exit 1; }
cat > s.cmd <<CMD
setMode -bs
setCable -port svf -file $D/trouve_audio.svf
addDevice -p 1 -file $D/trouve_audio.bit
program -p 1
quit
CMD
$X/impact -batch s.cmd > impact.log 2>&1 || { echo "IMPACT a echoue"; exit 1; }
[ -s trouve_audio.svf ] || { echo "pas de SVF"; exit 1; }
sed 's://.*$::' trouve_audio.svf > trouve_audio_clean.svf
echo "=== broches posees ==="
grep -iE "cand_|clk_50" trouve_audio_pad.txt | cut -c1-72
echo "=== termine : $D/trouve_audio_clean.svf ==="
