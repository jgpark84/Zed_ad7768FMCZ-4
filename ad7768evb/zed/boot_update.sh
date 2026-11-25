#!/bin/bash
set -e

PROJECT=/mnt/c/hdl_clean/projects/ad7768evb/zed
BOOTDIR=/mnt/c/hdl_clean/boot_test
ZED_IP=169.254.92.202

echo "[1] Copy new bitstream"
cp "$PROJECT/ad7768evb_zed.runs/impl_1/system_top.bit" \
   "$BOOTDIR/system_top.bit"

cd "$BOOTDIR"

echo "[2] Generate BOOT.BIN"
cmd.exe /C C:\\AMDesignTools\\2025.2\\Vivado\\bin\\bootgen.bat \
  -image zynq.bif -arch zynq -o BOOT.BIN -w

echo "[3] Send to ZedBoard"
scp BOOT.BIN root@$ZED_IP:/root/BOOT.BIN

echo "[4] Replace boot file"
ssh root@$ZED_IP "cp /root/BOOT.BIN /boot/BOOT.BIN && sync"

echo "Done."