#!/bin/sh

BASE=0x43C10000

rd() {
    busybox devmem $1 32
}

wr() {
    busybox devmem $1 32 $2
}

addr() {
    printf "0x%08X" $((BASE + $1))
}

echo "========================================"
echo " Control block sanity check"
echo " BASE = $BASE"
echo "========================================"
echo


echo "[1] Basic readback"
echo "avg_shift:"
rd $(addr 0x014)

echo "cordic selectors:"
for off in 0x018 0x01C 0x020 0x024 0x028 0x02C
do
    printf "%s = " $(addr $off)
    rd $(addr $off)
done

echo "cordic phase:"
for off in 0x030 0x034 0x038
do
    printf "%s = " $(addr $off)
    rd $(addr $off)
done

echo "cordic status:"
rd $(addr 0x03C)

echo


echo "[2] avg_shift write/read test"

OLD_AVG=$(rd $(addr 0x014))

wr $(addr 0x014) 0x00000005
NEW_AVG=$(rd $(addr 0x014))

echo "written = 0x00000005"
echo "read    = $NEW_AVG"

wr $(addr 0x014) $OLD_AVG

echo "restored ="
rd $(addr 0x014)

echo


echo "[3] CORDIC selector write/read test"

OLD_C0X=$(rd $(addr 0x018))
OLD_C0Y=$(rd $(addr 0x01C))

wr $(addr 0x018) 0x00000002
wr $(addr 0x01C) 0x00000003

echo "CORDIC0 X selector:"
rd $(addr 0x018)

echo "CORDIC0 Y selector:"
rd $(addr 0x01C)

wr $(addr 0x018) $OLD_C0X
wr $(addr 0x01C) $OLD_C0Y

echo "restored:"
rd $(addr 0x018)
rd $(addr 0x01C)

echo


echo "[4] PID0 register readback"

for off in \
    0x040 \
    0x044 \
    0x048 \
    0x04C \
    0x050 \
    0x054 \
    0x058 \
    0x05C \
    0x060 \
    0x064 \
    0x068 \
    0x06C \
    0x070 \
    0x074
do
    printf "%s = " $(addr $off)
    rd $(addr $off)
done

echo


echo "[5] PID0 configuration write/read test"

OLD_PID_CTRL=$(rd $(addr 0x040))
OLD_PID_SEL=$(rd $(addr 0x044))
OLD_PID_OFF=$(rd $(addr 0x048))
OLD_PID_GAIN=$(rd $(addr 0x04C))
OLD_PID_SP=$(rd $(addr 0x050))
OLD_PID_KP=$(rd $(addr 0x054))

wr $(addr 0x040) 0x00000000
wr $(addr 0x044) 0x00000001
wr $(addr 0x048) 0x00001234
wr $(addr 0x04C) 0x00010000
wr $(addr 0x050) 0x10000000
wr $(addr 0x054) 0x00008000

echo "control:"
rd $(addr 0x040)

echo "input_sel:"
rd $(addr 0x044)

echo "input_offset:"
rd $(addr 0x048)

echo "input_gain:"
rd $(addr 0x04C)

echo "setpoint:"
rd $(addr 0x050)

echo "kp:"
rd $(addr 0x054)

echo "restoring..."

wr $(addr 0x040) $OLD_PID_CTRL
wr $(addr 0x044) $OLD_PID_SEL
wr $(addr 0x048) $OLD_PID_OFF
wr $(addr 0x04C) $OLD_PID_GAIN
wr $(addr 0x050) $OLD_PID_SP
wr $(addr 0x054) $OLD_PID_KP

echo


echo "[6] PID0 reset pulse test"

echo "before reset:"
printf "output     = "
rd $(addr 0x068)

printf "error      = "
rd $(addr 0x06C)

printf "integrator = "
rd $(addr 0x070)

wr $(addr 0x040) 0x00000002

echo "control readback after reset command:"
rd $(addr 0x040)

echo "after reset:"
printf "output     = "
rd $(addr 0x068)

printf "error      = "
rd $(addr 0x06C)

printf "integrator = "
rd $(addr 0x070)

echo


echo "[7] AO0 readback"

for off in \
    0x140 \
    0x144 \
    0x148 \
    0x14C \
    0x150 \
    0x154 \
    0x158 \
    0x15C
do
    printf "%s = " $(addr $off)
    rd $(addr $off)
done

echo


echo "[8] AO0 manual code test"

OLD_AO_SRC=$(rd $(addr 0x140))
OLD_AO_MAN=$(rd $(addr 0x144))

wr $(addr 0x140) 0x00000000

wr $(addr 0x144) 0x00004000
sleep 1

echo "manual 0x4000:"
printf "manual reg = "
rd $(addr 0x144)

printf "AO output  = "
rd $(addr 0x158)

wr $(addr 0x144) 0x0000C000
sleep 1

echo "manual 0xC000:"
printf "manual reg = "
rd $(addr 0x144)

printf "AO output  = "
rd $(addr 0x158)

wr $(addr 0x144) $OLD_AO_MAN
wr $(addr 0x140) $OLD_AO_SRC

echo "restored:"
printf "source = "
rd $(addr 0x140)

printf "manual = "
rd $(addr 0x144)

printf "output = "
rd $(addr 0x158)

echo


echo "[9] Legacy DAC alias test"

OLD_LEGACY=$(rd $(addr 0x000))

wr $(addr 0x000) 0x00005555

echo "legacy dac_code:"
rd $(addr 0x000)

echo "AO0 manual_code:"
rd $(addr 0x144)

echo "AO0 output:"
rd $(addr 0x158)

wr $(addr 0x000) $OLD_LEGACY

echo


echo "[10] Average data snapshot"

for off in 0x004 0x008 0x00C 0x010
do
    printf "%s = " $(addr $off)
    rd $(addr $off)
done

echo


echo "[11] CORDIC live snapshot"

for i in 1 2 3 4 5
do
    echo "sample $i"

    printf "phase0 = "
    rd $(addr 0x030)

    printf "phase1 = "
    rd $(addr 0x034)

    printf "phase2 = "
    rd $(addr 0x038)

    printf "status = "
    rd $(addr 0x03C)

    sleep 1
done

echo
echo "========================================"
echo " Done"
echo "========================================"