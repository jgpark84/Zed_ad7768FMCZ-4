
#!/bin/sh

RAW_DEV=/dev/iio:device1
CTRL_DEV=/dev/iio:device3

RAW_SYS=/sys/bus/iio/devices/iio:device1
CTRL_SYS=/sys/bus/iio/devices/iio:device3

RAW_OUT=/tmp/raw_dma.bin
CTRL_OUT=/tmp/control_dma.bin

RAW_FRAME_BYTES=16
CTRL_FRAME_BYTES=32

echo "=== Disable buffers ==="
echo 0 > $RAW_SYS/buffer/enable 2>/dev/null
echo 0 > $CTRL_SYS/buffer/enable 2>/dev/null

echo "=== Enable scan channels ==="
for f in $RAW_SYS/scan_elements/*_en; do
    echo 1 > "$f"
done

for f in $CTRL_SYS/scan_elements/*_en; do
    echo 1 > "$f"
done

echo "=== Set buffer lengths ==="
echo 4096 > $RAW_SYS/buffer/length
echo 4096 > $CTRL_SYS/buffer/length

rm -f "$RAW_OUT" "$CTRL_OUT"

echo "=== Enable both DMA buffers ==="
echo 1 > $RAW_SYS/buffer/enable
echo 1 > $CTRL_SYS/buffer/enable

echo "=== Capture for 3 seconds ==="

timeout 3 cat $RAW_DEV > "$RAW_OUT" &
PID_RAW=$!

timeout 3 cat $CTRL_DEV > "$CTRL_OUT" &
PID_CTRL=$!

wait $PID_RAW
wait $PID_CTRL

echo "=== Disable buffers ==="
echo 0 > $RAW_SYS/buffer/enable
echo 0 > $CTRL_SYS/buffer/enable

RAW_BYTES=$(wc -c < "$RAW_OUT")
CTRL_BYTES=$(wc -c < "$CTRL_OUT")

RAW_FRAMES=$((RAW_BYTES / RAW_FRAME_BYTES))
CTRL_FRAMES=$((CTRL_BYTES / CTRL_FRAME_BYTES))

echo "=== Results ==="
ls -lh "$RAW_OUT" "$CTRL_OUT"

echo
echo "Raw bytes   : $RAW_BYTES"
echo "Raw frames  : $RAW_FRAMES"

echo "Control bytes  : $CTRL_BYTES"
echo "Control frames : $CTRL_FRAMES"

echo
echo "=== First raw frames ==="
hexdump -Cv "$RAW_OUT" | head -n 8

echo
echo "=== First control frames ==="
hexdump -Cv "$CTRL_OUT" | head -n 12