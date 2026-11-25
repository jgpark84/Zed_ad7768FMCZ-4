#!/bin/sh

MOD=/root/control_iio_stream.ko

if lsmod | grep -q '^control_iio_stream'; then
    echo "control_iio_stream already loaded"
    exit 0
fi

insmod "$MOD"

sleep 1

echo "=== dmesg ==="
dmesg | grep -i control | tail -20

echo "=== IIO devices ==="
for d in /sys/bus/iio/devices/iio:device*; do
    [ -f "$d/name" ] || continue
    echo "$(basename "$d"): $(cat "$d/name")"
done