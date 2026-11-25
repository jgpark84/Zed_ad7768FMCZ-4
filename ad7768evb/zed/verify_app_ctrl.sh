#!/bin/sh
BASE=0x43C10000
FULL=0
[ "$1" = "--full" ] && FULL=1

PASS=0
FAIL=0

addr() { printf "0x%08X" $((BASE + $1)); }
rd() { busybox devmem "$(addr "$1")" 32; }
wr() { busybox devmem "$(addr "$1")" 32 "$2" >/dev/null; }
hexnorm() { printf "0x%08X" $(( $1 )); }

check_eq() {
  NAME="$1"; OFF="$2"; EXPECT="$3"
  GOT="$(rd "$OFF")"
  GOTN="$(hexnorm "$GOT")"
  EXPN="$(hexnorm "$EXPECT")"
  if [ "$GOTN" = "$EXPN" ]; then
    echo "PASS  $NAME  $GOTN"
    PASS=$((PASS+1))
  else
    echo "FAIL  $NAME  got=$GOTN expected=$EXPN"
    FAIL=$((FAIL+1))
  fi
}

rw_test_restore() {
  NAME="$1"; OFF="$2"; TESTVAL="$3"
  OLD="$(rd "$OFF")"; OLDN="$(hexnorm "$OLD")"
  wr "$OFF" "$TESTVAL"
  GOT="$(rd "$OFF")"; GOTN="$(hexnorm "$GOT")"; TESTN="$(hexnorm "$TESTVAL")"
  if [ "$GOTN" = "$TESTN" ]; then
    echo "PASS  $NAME write/read  $TESTN"
    PASS=$((PASS+1))
  else
    echo "FAIL  $NAME write/read  got=$GOTN expected=$TESTN"
    FAIL=$((FAIL+1))
  fi
  wr "$OFF" "$OLDN"
  REST="$(rd "$OFF")"; RESTN="$(hexnorm "$REST")"
  if [ "$RESTN" = "$OLDN" ]; then
    echo "PASS  $NAME restore     $OLDN"
    PASS=$((PASS+1))
  else
    echo "FAIL  $NAME restore     got=$RESTN expected=$OLDN"
    FAIL=$((FAIL+1))
  fi
}

sel_test_restore() {
  NAME="$1"; OFF="$2"
  OLD="$(rd "$OFF")"; OLDN="$(hexnorm "$OLD")"
  V=0
  while [ "$V" -le 3 ]; do
    wr "$OFF" "$V"
    check_eq "$NAME=$V" "$OFF" "$V"
    V=$((V+1))
  done
  wr "$OFF" "$OLDN"
}

pid_block_test() {
  PREFIX="$1"; B="$2"
  sel_test_restore "$PREFIX input_sel" $((B+0x04))
  rw_test_restore "$PREFIX input_offset" $((B+0x08)) 0x13572468
  rw_test_restore "$PREFIX input_gain"   $((B+0x0C)) 0x24681357
  rw_test_restore "$PREFIX setpoint"     $((B+0x10)) 0x11223344
  rw_test_restore "$PREFIX kp"           $((B+0x14)) 0x01020304
  rw_test_restore "$PREFIX ki"           $((B+0x18)) 0x05060708
  rw_test_restore "$PREFIX kd"           $((B+0x1C)) 0x090A0B0C
  rw_test_restore "$PREFIX out_min"      $((B+0x20)) 0x80001000
  rw_test_restore "$PREFIX out_max"      $((B+0x24)) 0x7FFFF000

  if [ "$FULL" -eq 1 ]; then
    OLDEN="$(rd $((B+0x00)))"
    wr $((B+0x00)) 0
    check_eq "$PREFIX enable=0" $((B+0x00)) 0
    wr $((B+0x00)) 1
    check_eq "$PREFIX enable=1" $((B+0x00)) 1
    wr $((B+0x00)) 0
    check_eq "$PREFIX enable back=0" $((B+0x00)) 0
    wr $((B+0x00)) "$(hexnorm "$OLDEN")"
  else
    echo "SKIP  $PREFIX enable toggle (safe mode)"
  fi

  echo "INFO  $PREFIX output      $(rd $((B+0x28)))"
  echo "INFO  $PREFIX error       $(rd $((B+0x2C)))"
  echo "INFO  $PREFIX integrator  $(rd $((B+0x30)))"
  echo "INFO  $PREFIX status      $(rd $((B+0x34)))"
}

echo "============================================================"
echo "app_ctrl automatic verification"
echo "BASE=$BASE MODE=$([ "$FULL" -eq 1 ] && echo FULL || echo SAFE)"
echo "============================================================"

ORIG_DAC_SRC="$(rd 0x140)"
ORIG_DAC_CODE="$(rd 0x000)"
ORIG_AVG_SHIFT="$(rd 0x014)"

echo
echo "[1] Baseline / force manual DAC"
echo "INFO  dac_code       $ORIG_DAC_CODE"
echo "INFO  avg_shift      $ORIG_AVG_SHIFT"
echo "INFO  dac_source_sel $ORIG_DAC_SRC"
wr 0x140 0
check_eq "dac_source_sel forced manual" 0x140 0

echo
echo "[2] Averager/common"
echo "SKIP  dac_code write test (direct hardware output)"
rw_test_restore "avg_shift N=1"    0x014 0
rw_test_restore "avg_shift N=16"   0x014 4
rw_test_restore "avg_shift N=256"  0x014 8
rw_test_restore "avg_shift N=1024" 0x014 10
OLD="$(rd 0x014)"
wr 0x014 15
check_eq "avg_shift clamp 15->10" 0x014 10
wr 0x014 "$(hexnorm "$OLD")"
echo "INFO  avg0 $(rd 0x004)"
echo "INFO  avg1 $(rd 0x008)"
echo "INFO  avg2 $(rd 0x00C)"
echo "INFO  avg3 $(rd 0x010)"

echo
echo "[3] CORDIC selectors"
sel_test_restore "cordic0_sel_x" 0x018
sel_test_restore "cordic0_sel_y" 0x01C
sel_test_restore "cordic1_sel_x" 0x020
sel_test_restore "cordic1_sel_y" 0x024
sel_test_restore "cordic2_sel_x" 0x028
sel_test_restore "cordic2_sel_y" 0x02C

echo
echo "[4] CORDIC readback"
echo "INFO  cordic0_phase $(rd 0x030)"
echo "INFO  cordic1_phase $(rd 0x034)"
echo "INFO  cordic2_phase $(rd 0x038)"
echo "INFO  cordic_status $(rd 0x03C)"

echo
echo "[5] Phase PID0"
pid_block_test phase_pid0 0x040
echo
echo "[6] Phase PID1"
pid_block_test phase_pid1 0x080
echo
echo "[7] General PID0"
pid_block_test general_pid0 0x0C0
echo
echo "[8] General PID1"
pid_block_test general_pid1 0x100

echo
echo "[9] DAC source selector"
V=0
while [ "$V" -le 4 ]; do
  wr 0x140 "$V"
  check_eq "dac_source_sel=$V" 0x140 "$V"
  V=$((V+1))
done
wr 0x140 7
check_eq "dac_source_sel invalid->manual" 0x140 0

echo
echo "[10] Restore"
wr 0x014 "$(hexnorm "$ORIG_AVG_SHIFT")"
wr 0x140 "$(hexnorm "$ORIG_DAC_SRC")"
check_eq "avg_shift restored" 0x014 "$ORIG_AVG_SHIFT"
check_eq "dac_source_sel restored" 0x140 "$ORIG_DAC_SRC"
check_eq "dac_code unchanged" 0x000 "$ORIG_DAC_CODE"

echo
echo "============================================================"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "============================================================"
[ "$FAIL" -eq 0 ] && echo "ALL REGISTER TESTS PASSED" && exit 0
echo "ONE OR MORE TESTS FAILED"
exit 1
