#!/usr/bin/env sh
# Analyze, elaborate and run the I2C testbench with GHDL (VHDL-2008); writes sim/i2c.vcd.
# Native:  sh sim/run_ghdl.sh
# Docker:  docker run --rm -v "$PWD":/src -w /src ghdl/ghdl:6.0.0-mcode-ubuntu-24.04 sh sim/run_ghdl.sh
set -e
cd "$(dirname "$0")/.."
mkdir -p sim/work
ghdl --version | head -n 1
ghdl -a --std=08 --workdir=sim/work rtl/i2c_master_tx.vhd rtl/i2c_master_rx.vhd tb/tb_i2c.vhd
ghdl -e --std=08 --workdir=sim/work tb_i2c
ghdl -r --std=08 --workdir=sim/work tb_i2c --vcd=sim/i2c.vcd --stop-time=2ms
