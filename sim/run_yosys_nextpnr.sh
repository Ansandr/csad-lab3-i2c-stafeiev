#!/usr/bin/env sh
# Open-source synthesis estimate (NOT the vendor tool required by the teacher):
#   Yosys + ghdl-yosys-plugin -> Xilinx 7-series and Lattice iCE40 cell counts,
#   nextpnr-ice40 (HX8K, ct256) -> place & route and Fmax at a 50 MHz target.
# Run from the repository root (PowerShell: replace "$PWD" with "${PWD}"):
#   docker run --rm -v "$PWD":/src -w /src hdlc/ghdl:yosys sh sim/run_yosys_nextpnr.sh synth
#   docker run --rm -v "$PWD":/src -w /src hdlc/nextpnr:ice40 sh sim/run_yosys_nextpnr.sh pnr
set -e
cd "$(dirname "$0")/.."
mkdir -p sim/yosys
for top in i2c_master_tx i2c_master_rx; do
  if [ "$1" = "synth" ]; then
    yosys -m ghdl -q -p "ghdl --std=08 rtl/i2c_master_tx.vhd rtl/i2c_master_rx.vhd -e $top; synth_xilinx -family xc7 -top $top -flatten; tee -o sim/yosys/${top}_xc7_stat.txt stat"
    yosys -m ghdl -q -p "ghdl --std=08 rtl/i2c_master_tx.vhd rtl/i2c_master_rx.vhd -e $top; synth_ice40 -top $top -json sim/yosys/${top}_ice40.json; tee -o sim/yosys/${top}_ice40_stat.txt stat"
  else
    nextpnr-ice40 --hx8k --package ct256 --json sim/yosys/${top}_ice40.json --freq 50 > sim/yosys/${top}_ice40_pnr.log 2>&1
    grep -E "ICESTORM_LC|Max frequency" sim/yosys/${top}_ice40_pnr.log
  fi
done
