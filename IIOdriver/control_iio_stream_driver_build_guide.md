# ZedBoard FPGA Control Stream IIO 드라이버 제작·빌드·설치 가이드

- 기록일: 2026-11-25
- 대상: ZedBoard (Zynq-7000, ARMv7), ADI Kuiper Linux, ADI AXI-DMAC 기반 사용자 정의 FPGA control stream
- 최종 상태: **16채널 / 56바이트 scan 드라이버 빌드, 실제 DMA 수집, systemd 부팅 자동 로드까지 검증 완료**
- 목적: 이후 개발 환경을 다시 구축하거나 드라이버를 수정할 때 **커널 전체를 다시 빌드하지 않고 외부 모듈 `.ko`만 재제작**하기 위한 기록

> 이 문서는 2026-11-25 실제 터미널 출력 및 검증 결과를 기준으로 작성했다. 경로, IP, 포트, 커널 커밋은 당시 환경의 값이다. 소스 코드 전체는 당시 `control_iio_stream.c`에 있으므로 그 원본을 별도 백업/버전 관리해야 한다. 이 문서의 코드는 구조와 재현 절차를 설명한다.

## 1. 시스템 및 제작 환경

| 구분 | 확인된 값 |
|---|---|
| 개발 PC | Windows + WSL Ubuntu, 사용자 `coolj` |
| WSL 호스트 | `BOOK-JL2G3BJHNJ` |
| **주의** | 기본 `wsl`은 Debian(`jpark`)으로 연결됐으며 커널 소스/도구가 없었음. **`wsl -d Ubuntu`** 사용 |
| 커널 소스 | Ubuntu 내부 ext4: `/home/coolj/linux_adi` |
| 드라이버 소스 | Windows 드라이브: `/mnt/c/hdl_clean/ao_iio_driver/control_iio_stream.c` |
| Makefile | `/mnt/c/hdl_clean/ao_iio_driver/Makefile` |
| 보드 커널 설정 백업 | `/mnt/c/hdl_clean/ao_iio_driver/board_kernel.config` |
| 모듈 임시 빌드 | `/tmp/control_iio_build/` |
| 크로스 컴파일러 | `/usr/bin/arm-linux-gnueabihf-gcc` |
| 커널 소스 저장소 | `https://github.com/analogdevicesinc/linux.git` |
| 커널 소스 체크아웃 | Git commit `2e8908932dfd` |
| 보드 로그인 | `ssh.exe -p 2022 root@165.132.28.190` (당시 네트워크) |
| 보드 `uname -r` | `6.1.70-284114-g2e8908932dfd` |
| 빌드 `.ko`의 `vermagic` | `6.1.70-35304-g2e8908932dfd SMP preempt mod_unload modversions ARMv7 p2v8` |
| FPGA control DMA | `0x7c400000` |
| 기존 raw ADC DMA | `0x7c480000` (별도 시스템, 변경하지 않음) |
| 보드 IIO 이름 | `control_stream` (당시 `iio:device3`) |
| 모듈 이름 | `control_iio_stream` |
| 부팅 자동 로드 | `/etc/systemd/system/control-iio-stream.service` |

### 커널 버전 문자열에 대한 중요한 실제 기록

- 보드의 `uname -r`에는 `284114`가 있었고, 새 모듈과 기존 모듈의 `vermagic`에는 모두 `35304`가 있었다.
- **기존 모듈은 강제 로드나 우회 없이 정상 작동했으며, 새 모듈도 실제 `insmod` 및 부팅 시 systemd 자동 로드가 성공했다.** 따라서 이 환경에서 버전 문자열 불일치만 보고 모듈이 작동하지 않는다고 판단하면 안 된다.
- 이후 커널/모듈 ABI 또는 빌드 환경이 바뀐다면 실제 로드 결과와 커널 로그를 다시 확인한다. `insmod -f` 같은 강제 로드는 사용하지 않았다.

## 2. FPGA 데이터 형식: 1프레임 56바이트

FPGA serializer는 32비트 워드 **14개 = 56바이트**를 프레임 하나로 출력한다. DMA와 IIO 채널의 배치는 이 물리적 바이트 배치에 맞아야 한다.

| 워드 | 바이트 오프셋 | IIO `scan_index` | 항목 | IIO 정의 | 의미 |
|---:|---:|---:|---|---|---|
| 0–3 | 0–15 | 0–3 | AVG0–AVG3 | `le:s32/32>>0` | 4개 signed 평균값 |
| 4–5 | 16–23 | 4–5 | PHASE0–PHASE1 | `le:s32/32>>0` | CORDIC BAM 위상 |
| 6 | 24–27 | 6–7 | AO0, AO1 | 각각 `le:u16/16>>0` | `[AO1(15:0), AO0(15:0)]` |
| 7 | 28–31 | 8–9 | AO2, AO3 | 각각 `le:u16/16>>0` | `[AO3(15:0), AO2(15:0)]` |
| 8 | 32–35 | 10 | AO4 | `le:u20/32>>0` | 하위 20비트 값, 32비트 슬롯 |
| 9 | 36–39 | 11 | AO5 | `le:u20/32>>0` | 하위 20비트 값, 32비트 슬롯 |
| 10–13 | 40–55 | 12–15 | PID0–PID3 | `le:s32/32>>0` | 4개 signed PID 출력 |

**전체 16개 채널이 활성화되면 IIO scan은 정확히 56바이트**다. `scan_index`는 0~15로 연속이며 중복이 없다. sysfs 파일 목록은 문자열순으로 출력되어 `in_voltage10`이 `in_voltage1`보다 먼저 보일 수 있으나, **버퍼 내 실제 순서는 `scan_index`가 결정**한다.

### Python에서 프레임 해석

```python
import struct
frame = struct.unpack('<6i4H2I4i', data[:56])
avg = frame[0:4]
phase = frame[4:6]
ao0_to_3 = frame[6:10]
ao4_to_5 = frame[10:12]
pid0_to_3 = frame[12:16]
```

이 구조체 형식은 정확히 **56바이트**다 (`struct.calcsize('<6i4H2I4i') == 56`). AO4/AO5는 필요할 때 `& 0xFFFFF`로 20비트 마스킹할 수 있다.

## 3. Linux IIO 커널 드라이버 구조

원본 파일: `/mnt/c/hdl_clean/ao_iio_driver/control_iio_stream.c`

### 핵심 헤더 및 함수

```c
#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/iio/iio.h>
#include <linux/iio/buffer.h>
#include <linux/iio/buffer-dmaengine.h>
```

- `static const struct iio_chan_spec control_channels[]`: 위 표대로 16채널. `.indexed = 1`, `.channel = 0..15`, `.scan_index = 0..15`, `.scan_type`의 `realbits/storagebits/sign/endianness`를 지정.
- `static const struct iio_info control_iio_info = { };`: 직접 읽는 IIO 속성 없이 DMA 버퍼로 데이터 수집.
- `control_iio_probe(struct platform_device *pdev)`: IIO device 할당 → 채널 배열 부착 → DMAEngine 버퍼 설정 → IIO device 등록.

핵심 코드:

```c
indio_dev = devm_iio_device_alloc(&pdev->dev, 0);
if (!indio_dev)
    return -ENOMEM;

indio_dev->name = "control_stream";
indio_dev->dev.parent = &pdev->dev;
indio_dev->info = &control_iio_info;
indio_dev->modes = INDIO_DIRECT_MODE;
indio_dev->channels = control_channels;
indio_dev->num_channels = ARRAY_SIZE(control_channels);

ret = devm_iio_dmaengine_buffer_setup(
    &pdev->dev, indio_dev, "rx", IIO_BUFFER_DIRECTION_IN);
if (ret)
    return ret;

ret = devm_iio_device_register(&pdev->dev, indio_dev);
if (ret)
    return ret;
```

Device Tree의 호환 문자열 및 DMA 채널 이름:

```c
static const struct of_device_id control_iio_of_match[] = {
    { .compatible = "jpark,control-iio-stream" },
    { }
};
MODULE_DEVICE_TABLE(of, control_iio_of_match);

/* platform_driver 등록: module_platform_driver(control_iio_driver); */
MODULE_IMPORT_NS(IIO_DMAENGINE_BUFFER);
MODULE_LICENSE("GPL");
```

연결되는 Device Tree 노드에 해당 드라이버의 compatible 문자열과 `dma-names = "rx"`, `dmas = <&ao_dma 0>`와 같은 RX DMA 연결이 필요하다. **당시 보드에서는 이미 존재하고 정상 동작했으므로 DT/BOOT.BIN을 수정하지 않았다.**

### 추가된 여섯 채널의 타입

```c
/* AO4, AO5: scan_index = 10, 11 */
.scan_type = { .sign = 'u', .realbits = 20, .storagebits = 32,
               .shift = 0, .endianness = IIO_LE },

/* PID0~PID3: scan_index = 12, 13, 14, 15 */
.scan_type = { .sign = 's', .realbits = 32, .storagebits = 32,
               .shift = 0, .endianness = IIO_LE },
```

기존 소스 상단의 주석에는 예전 **10채널/32바이트** 설명이 남아 있었다. 실제 16채널 배열/컴파일 동작과는 별개인 주석 불일치이며, 다음 편집 때 문서와 소스 주석을 56바이트로 갱신하면 된다.

## 4. WSL Ubuntu 개발 환경 복원

### 올바른 WSL 배포판 진입

Windows PowerShell에서:

```powershell
wsl -d Ubuntu
```

WSL Ubuntu에서:

```bash
whoami                           # coolj
which arm-linux-gnueabihf-gcc     # /usr/bin/arm-linux-gnueabihf-gcc
ls /home/coolj/linux_adi/Module.symvers
ls /home/coolj/linux_adi/.config
```

원래 사용했던 Windows 기본 `wsl`은 Debian으로 들어가서 `linux_adi`와 git 도구가 보이지 않았다. Ubuntu 환경을 새로 잃어버린 것으로 오해하지 않도록 주의한다.

### 커널 소스가 없는 경우

Ubuntu의 Linux 파일 시스템(ext4)에서:

```bash
cd /home/coolj
git clone https://github.com/analogdevicesinc/linux.git linux_adi
cd linux_adi
git checkout 2e8908932dfd
```

**`/mnt/c/linux_adi`에 clone하지 않는다.** 과거 NTFS 파일명 대소문자 충돌이 있었으므로 Ubuntu 내부 `/home/coolj/linux_adi`를 사용했다.

필요한 구성:

- `ARCH=arm`, `CROSS_COMPILE=arm-linux-gnueabihf-`
- 커널 소스 체크아웃 commit: `2e8908932dfd`
- 준비된 `.config`, `Module.symvers` (단순 clone만으로 자동 생성되지 않음)
- 당시 설정에 `CONFIG_MODULES=y`, `CONFIG_MODVERSIONS=y`, `CONFIG_LOCALVERSION=""`, `CONFIG_LOCALVERSION_AUTO=y`
- 보드에서 추출해 저장한 당시 설정 파일: `/mnt/c/hdl_clean/ao_iio_driver/board_kernel.config`

**주의:** 아래의 모듈 빌드 명령은 `.config`와 `Module.symvers`가 갖춰진 당시 소스 트리에서 성공했다. 새로 clone한 빈 트리라면 필요한 준비 파일이 없을 수 있다. 이 문서는 커널 전체 빌드 명령을 요구하거나 권장하지 않으며, 기존 준비된 트리를 우선 보존·재사용한다.

확인 명령:

```bash
cd /home/coolj/linux_adi
git rev-parse --short HEAD
make -s ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- kernelrelease
ls -lh .config Module.symvers
```

당시 `kernelrelease`는 `6.1.70-35304-g2e8908932dfd`, git describe는 `v6.1-35304-g2e8908932dfd`였다.

## 5. 외부 모듈만 빌드 (성공한 실제 명령)

### Makefile

```makefile
obj-m += control_iio_stream.o
```

### 빌드

Ubuntu WSL에서:

```bash
mkdir -p /tmp/control_iio_build
cp /mnt/c/hdl_clean/ao_iio_driver/control_iio_stream.c \
   /mnt/c/hdl_clean/ao_iio_driver/Makefile \
   /tmp/control_iio_build/

make -C /home/coolj/linux_adi \
  M=/tmp/control_iio_build \
  ARCH=arm \
  CROSS_COMPILE=arm-linux-gnueabihf- \
  modules
```

당시 빌드 성공 로그의 핵심:

```text
CC [M]  /tmp/control_iio_build/control_iio_stream.o
MODPOST /tmp/control_iio_build/Module.symvers
CC [M]  /tmp/control_iio_build/control_iio_stream.mod.o
LD [M]  /tmp/control_iio_build/control_iio_stream.ko
```

빌드 결과: `/tmp/control_iio_build/control_iio_stream.ko` (당시 약 8.9KB).

검증:

```bash
modinfo -F vermagic /tmp/control_iio_build/control_iio_stream.ko
file /tmp/control_iio_build/control_iio_stream.ko
```

당시 `vermagic` 출력:

```text
6.1.70-35304-g2e8908932dfd SMP preempt mod_unload modversions ARMv7 p2v8
```

> 소스 파일 수정 후에는 이 빌드를 다시 실행해야 한다. `.ko`만 빌드하며 FPGA bitstream, BOOT.BIN, 전체 커널 이미지는 다시 생성하지 않는다.

## 6. 보드 설치 및 안전한 교체

### 6.1 새 파일을 별도 이름으로 전송

WSL Ubuntu에서 (당시 `scp.exe` 사용):

```bash
scp.exe -P 2022 \
  /tmp/control_iio_build/control_iio_stream.ko \
  root@165.132.28.190:/root/control_iio_stream_56.ko
```

보드 접속:

```bash
ssh.exe -p 2022 root@165.132.28.190
```

이하 명령은 **보드 셸 `root@analog:~#`에서 실행**한다. WSL 셸에서 `/sys/bus/iio/...`를 읽지 않는다.

### 6.2 기존 장치 사용 여부 확인

```bash
cat /sys/bus/iio/devices/iio:device3/buffer/enable
fuser /dev/iio:device3 2>/dev/null
```

당시 결과는 `enable=0`, `fuser` 출력 없음. 실제 스트림 사용 중인 프로그램이 있다면 먼저 종료하고 버퍼를 끈다. IIO 번호 `device3`는 다시 열거될 때 달라질 수 있으므로 `name`으로 찾는 것이 더 안전하다.

### 6.3 기존 모듈 백업 후 새 모듈 테스트

```bash
cp -p /root/control_iio_stream.ko /root/control_iio_stream_old.ko
rmmod control_iio_stream
insmod /root/control_iio_stream_56.ko
dmesg | tail -n 20
```

당시 새 드라이버는 `probing control IIO DMA stream`, `control IIO DMA stream registered`를 출력했고 성공했다. **강제 로드, 커널 재빌드, BOOT.BIN 수정은 하지 않았다.**

로딩 실패 시 (원인을 확인한 후):

```bash
insmod /root/control_iio_stream_old.ko
```

실패 메시지에 따라 DMA buffer 사용 상태, 모듈 로딩 상태 등을 먼저 확인할 것. 이미 로드된 모듈에 중복 `insmod`하지 않는다.

## 7. 보드에서 채널 및 DMA 실측 검증

### 장치 이름 찾기

```bash
for d in /sys/bus/iio/devices/iio:device*; do
    [ "$(cat "$d/name" 2>/dev/null)" = control_stream ] && echo "$d"
done
```

당시에는 `/sys/bus/iio/devices/iio:device3`였다.

### 16채널 형식 검사

```bash
D=/sys/bus/iio/devices/iio:device3
cat "$D/name"
for f in "$D"/scan_elements/*_type; do
    echo "$(basename "$f"): $(cat "$f")"
done
```

실제 확인된 새 채널:

```text
in_voltage10_ao4_type: le:u20/32>>0
in_voltage11_ao5_type: le:u20/32>>0
in_voltage12_pid0_type: le:s32/32>>0
in_voltage13_pid1_type: le:s32/32>>0
in_voltage14_pid2_type: le:s32/32>>0
in_voltage15_pid3_type: le:s32/32>>0
```

### 전체 채널 활성화

```bash
D=/sys/bus/iio/devices/iio:device3
echo 0 > "$D/buffer/enable"
for f in "$D"/scan_elements/*_en; do echo 1 > "$f"; done
grep -H . "$D"/scan_elements/*_en
```

실제로 16개 `_en` 값이 모두 `1`임을 확인했다.

### 32프레임 수집

```bash
D=/sys/bus/iio/devices/iio:device3
echo 56 > "$D/buffer/length"
echo 1 > "$D/buffer/enable"
dd if=/dev/iio:device3 of=/tmp/control56_test.bin bs=1792 count=1 status=none
echo 0 > "$D/buffer/enable"
wc -c /tmp/control56_test.bin
```

실제 출력: **`1792 /tmp/control56_test.bin`** = 56 × 32프레임.

**`buffer/length=56`은 56바이트가 아니라 IIO scan 56개**를 의미한다. 따라서 채널 전체가 활성화된 현재에는 56 × 56 = 3136바이트에 해당한다. 위 `dd`는 그중 1792바이트를 읽는 테스트였다. `dd`의 읽기 크기만으로 장시간 연속 수집의 프레임 정렬까지 보장되지는 않으므로 장시간 수집은 별도로 시험한다.

### 수집 데이터 해석

```bash
python3 - <<'PY'
import struct

data = open('/tmp/control56_test.bin', 'rb').read()
print('bytes:', len(data), 'frames:', len(data) // 56)
for i in range(min(5, len(data) // 56)):
    v = struct.unpack_from('<6i4H2I4i', data, i * 56)
    print(f'frame {i}: AVG={v[0:4]} PHASE={v[4:6]} '
          f'AO0-3={v[6:10]} AO4-5={v[10:12]} PID={v[12:16]}')
PY
```

실측 결과:

```text
bytes: 1792 frames: 32
frame 0: AVG=(3086, 376325, 377117, 5468) PHASE=(1068137118, 9912446) AO0-3=(32768, 32768, 32768, 32768) AO4-5=(524288, 524288) PID=(0, 0, 0, 0)
frame 1: AVG=(3095, 377127, 378403, 5473) PHASE=(1068131904, 9888976) AO0-3=(32768, 32768, 32768, 32768) AO4-5=(524288, 524288) PID=(0, 0, 0, 0)
frame 2: AVG=(3065, 376771, 377961, 5461) PHASE=(1068184056, 9878546) AO0-3=(32768, 32768, 32768, 32768) AO4-5=(524288, 524288) PID=(0, 0, 0, 0)
frame 3: AVG=(3131, 375483, 376259, 5483) PHASE=(1068043248, 9964598) AO0-3=(32768, 32768, 32768, 32768) AO4-5=(524288, 524288) PID=(0, 0, 0, 0)
frame 4: AVG=(3104, 376192, 377350, 5454) PHASE=(1068100614, 9883762) AO0-3=(32768, 32768, 32768, 32768) AO4-5=(524288, 524288) PID=(0, 0, 0, 0)
```

- AVG 및 PHASE 값은 프레임별로 변화.
- AO0–AO3은 `32768` (`0x8000`).
- AO4–AO5는 `524288` (`0x80000`).
- PID0–PID3은 0.
- 이 값들은 56바이트 경계가 맞는다는 강한 증거다. 다만 32프레임 단발 수집 결과이므로 연속 장시간 DMA 검증 결과와 혼동하지 않는다.

## 8. 부팅 시 자동 로드 설정

기존 부팅 설정 확인:

```bash
grep -R -n 'control_iio_stream' \
  /etc/modules /etc/modules-load.d /etc/modprobe.d \
  /etc/systemd/system /etc/rc.local 2>/dev/null
```

당시 기존 서비스 파일:

```text
/etc/systemd/system/control-iio-stream.service
```

관련 핵심 설정:

```ini
ExecStart=/sbin/insmod /root/control_iio_stream.ko
ExecStop=/sbin/rmmod control_iio_stream
```

서비스는 기존에 이미 설치·활성화되어 있었다. 별도 서비스를 새로 만들지 않고 **새 모듈 파일을 서비스의 기존 참조 경로에 설치**했다.

보드에서:

```bash
# 이전 .ko는 반드시 먼저 백업
cp -p /root/control_iio_stream.ko /root/control_iio_stream_old.ko

# 검증한 새 .ko를 서비스가 읽는 경로에 복사
cp -p /root/control_iio_stream_56.ko /root/control_iio_stream.ko

ls -lh /root/control_iio_stream*.ko
systemctl is-enabled control-iio-stream.service
```

당시 파일 상태:

```text
/root/control_iio_stream_56.ko   8.9K (새 모듈)
/root/control_iio_stream.ko      8.9K (자동 로드 대상)
/root/control_iio_stream_old.ko  8.3K (이전 모듈 백업)
```

`systemctl is-enabled` 실제 결과: `enabled`.

### 재부팅 후 검증 (실제 성공)

```bash
reboot
```

다시 SSH 접속 후:

```bash
systemctl status control-iio-stream.service --no-pager
ls /sys/bus/iio/devices/iio:device3/scan_elements/*pid*_type
```

실제 systemd 상태:

```text
Loaded: loaded (/etc/systemd/system/control-iio-stream.service; enabled; vendor preset: enabled)
Active: active (exited)
ExecStart=/sbin/insmod /root/control_iio_stream.ko (code=exited, status=0/SUCCESS)
```

재부팅 후에도 PID0~PID3의 `_type` 파일 네 개가 존재함을 확인했다. **부팅 자동 로드 완료**.

> `active (exited)`는 이 서비스에서 `insmod` 명령이 성공적으로 종료된 상태로 확인되었으며, 정상 작동 판정에 사용한 것은 실제 `status=0/SUCCESS`와 IIO 채널 재등록 결과다.

## 9. 복구 방법 및 안전 수칙

1. **기존 모듈 보존:** `/root/control_iio_stream_old.ko`를 삭제하지 않는다.
2. **실행 중인 이용자 중지:** DMA 스트림을 읽는 Python/GUI를 먼저 종료하고 IIO buffer를 비활성화한다.
3. **모듈 교체:** 정상 동작 확인 후 `rmmod control_iio_stream` → `insmod /root/control_iio_stream_old.ko`로 일시 복구 가능.
4. **재부팅 복구:** 영구적으로 이전 모듈로 되돌리려면 서비스가 읽는 경로(`/root/control_iio_stream.ko`)를 백업 모듈로 교체하고, 재부팅 후 서비스/채널을 확인한다.
5. **변경하지 않을 영역:** raw AD7768-4 ADC IIO(`cf_axi_adc`, 당시 `iio:device1`), FPGA BOOT.BIN, 전체 커널 이미지는 이 드라이버 확장 과정에서 변경하지 않았다.
6. **모듈 강제 로드 불필요:** 당시 `insmod -f`나 우회 조치는 사용하지 않았다.

예시 영구 롤백 (현재 작업 중인 수집 프로세스를 모두 중지한 다음):

```bash
cp -p /root/control_iio_stream_old.ko /root/control_iio_stream.ko
reboot
```

기존 모듈은 10채널/32바이트 인터페이스이므로, 롤백하면 사용자 프로그램과 IIO 채널 설정도 이에 맞춰 되돌려야 한다.

## 10. Python 스트림 수집 코드 후속 작업

보드 Python 경로: `/root/control_stream_source.py`.

이전 상황:

- FPGA는 이미 56바이트 프레임을 출력하는데 기존 커널 IIO 드라이버는 10채널/32바이트 scan으로 등록되어 있었다.
- 당시 Python은 `FRAME_BYTES=56`, `BUFFER_LENGTH=56`, `READ_FRAMES=32`, `READ_BYTES=1792`로 설정했고 56바이트 프레임 정렬을 유지하면서 장시간 데이터를 수집한 기록이 있다.
- 이번에 드라이버 자체가 16채널/56바이트 scan이 되었으므로, Python에서 **16채널 전체의 `_en=1` 활성화**와 `buffer/length`가 scan 개수라는 점을 확인해야 한다.
- `READ_BYTES=1792`는 여전히 56×32바이트라서 유지할 수 있지만, `BUFFER_LENGTH`는 읽기 전략과 버퍼링에 맞춰 재검토한다. 값을 무조건 32로 바꿔야 하는 것은 아니다.
- 프로그램이 부분 `read()`를 반환받아도 56바이트씩 누적·분리하는지, DMA 시작/정지 및 버퍼 에러를 안전하게 처리하는지 확인할 것.

**2026-11-25 기준:** 새 드라이버의 단발 32프레임 테스트와 부팅 자동 로드는 검증 완료. Python 수집 프로그램의 새 드라이버용 최종 정리 및 장시간 재검증은 별도 후속 작업이다.

## 11. 추후 다시 제작할 때의 최소 체크리스트

- [ ] `wsl -d Ubuntu`로 올바른 WSL 진입
- [ ] `/home/coolj/linux_adi`에 올바른 커밋 및 준비된 `.config`, `Module.symvers` 확인
- [ ] `control_iio_stream.c` 16채널/56바이트 정의 확인
- [ ] `make -C ... M=... ARCH=arm CROSS_COMPILE=... modules`로 `.ko`만 빌드
- [ ] `modinfo -F vermagic` 기록
- [ ] 보드 기존 `.ko` 백업, 새 `.ko`는 별도 파일로 우선 전송
- [ ] 이용 프로세스 중지 및 IIO buffer 비활성화
- [ ] 새 모듈 로드 후 채널 16개와 실제 56바이트 프레임 검증
- [ ] 검증된 모듈을 `/root/control_iio_stream.ko`로 복사
- [ ] `control-iio-stream.service`가 `enabled`인지 확인
- [ ] 재부팅 후 `ExecStart ... status=0/SUCCESS`, PID 채널 재등록 확인
- [ ] Python의 16채널 활성화 및 연속 수집 시험

---

### 재현성 관련 보존 권장 파일

아래 파일은 이 Markdown과 별도로 백업하면 좋다.

```text
/mnt/c/hdl_clean/ao_iio_driver/control_iio_stream.c
/mnt/c/hdl_clean/ao_iio_driver/Makefile
/mnt/c/hdl_clean/ao_iio_driver/board_kernel.config
/home/coolj/linux_adi/.config
/home/coolj/linux_adi/Module.symvers
/tmp/control_iio_build/control_iio_stream.ko
/root/control_iio_stream.ko       (보드: 새 파일)
/root/control_iio_stream_old.ko   (보드: 이전 백업)
/etc/systemd/system/control-iio-stream.service (보드)
```

**핵심 결론:** 당시 환경에서는 FPGA 변경 없이 10채널/32바이트 IIO consumer를 16채널/56바이트로 확장했고, 기존 ADI 커널 소스/준비된 빌드 산출물로 외부 모듈만 재빌드해 보드 적용·DMA 검증·자동 부팅 로드까지 완료했다.
