#!/usr/bin/env bash
#
# build-kernel.sh -- build a zImage for the incall head unit (i.MX6DL,
#                    Linux 3.0.35, Freescale kk4.4.2_1.0.0-ga BSP) with
#                    CDC-NCM + iAP2 gadget support added.
#
# Run this on Linux (Ubuntu 18.04 / 20.04 recommended). It cannot run on
# Windows: the 3.0 Kbuild needs a POSIX shell, and the ARM toolchain is a
# Linux ELF binary.
#
# Usage:
#   ./build-kernel.sh                      # use defaults
#   CROSS_COMPILE=arm-eabi- ./build-kernel.sh
#   KERNEL_DIR=/path/to/src ./build-kernel.sh
#
set -euo pipefail

KERNEL_DIR="${KERNEL_DIR:-$HOME/kb/linux-2.6-imx}"
CONFIG_SRC="${CONFIG_SRC:-$HOME/kb/work/build.config}"
OUT_DIR="${OUT_DIR:-$HOME/kb/out}"
JOBS="${JOBS:-$(nproc)}"
CROSS_COMPILE="${CROSS_COMPILE:-}"

log()  { printf '\n\033[1m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33m!! %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

mkdir -p "$OUT_DIR"

# ---------------------------------------------------------------- 1. inputs
log "检查输入"
[ -d "$KERNEL_DIR" ] || die "找不到内核源码目录: $KERNEL_DIR"
[ -f "$CONFIG_SRC" ] || die "找不到 config: $CONFIG_SRC"
[ -f "$KERNEL_DIR/drivers/usb/gadget/f_iap2.c" ] || \
    die "f_iap2.c 不在源码树里，补丁没打上？"
grep -q 'f_ncm.c' "$KERNEL_DIR/drivers/usb/gadget/android.c" || \
    die "android.c 里没有引入 f_ncm.c，补丁没打上？"

VERSION_LINE=$(head -5 "$KERNEL_DIR/Makefile" | tr '\n' ' ')
echo "  源码  : $KERNEL_DIR"
echo "  config: $CONFIG_SRC"
echo "  版本  : $VERSION_LINE"

# ------------------------------------------------------------ 2. host tools
log "检查构建依赖"
missing=()
for t in make gcc bison flex bc python3; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "缺少: ${missing[*]}"
    echo
    echo "Ubuntu/Debian 安装："
    echo "  sudo apt update"
    echo "  sudo apt install -y build-essential bison flex bc libncurses5-dev python3"
    die "依赖不全"
fi
echo "  依赖齐全"

# ------------------------------------------------------------ 3. toolchain
log "检测 ARM 交叉编译器"
if [ -z "$CROSS_COMPILE" ]; then
    for c in arm-eabi- arm-linux-gnueabi- arm-linux-gnueabihf- arm-none-eabi-; do
        if command -v "${c}gcc" >/dev/null 2>&1; then
            CROSS_COMPILE="$c"
            break
        fi
    done
fi
[ -n "$CROSS_COMPILE" ] || die "没找到 ARM 交叉编译器。
安装: sudo apt install gcc-arm-linux-gnueabi
或用 AOSP 的 arm-eabi-4.6 并设置 CROSS_COMPILE=arm-eabi-"

echo "  使用  : ${CROSS_COMPILE}gcc"
"${CROSS_COMPILE}gcc" --version | head -1 | sed 's/^/  /'

GCC_MAJOR=$("${CROSS_COMPILE}gcc" -dumpversion 2>/dev/null | cut -d. -f1)
GCC_MAJOR=${GCC_MAJOR:-0}
KCFLAGS_EXTRA=""

# gcc 5 起把 `extern inline` 改成 C99 语义（不再生成外部定义）。
# 3.0 内核大量依赖 GNU89 的 extern inline，会报 "redefinition of ..."。
# 必须显式退回 GNU89 inline 语义。
if [ "$GCC_MAJOR" -ge 5 ]; then
    KCFLAGS_EXTRA="-fgnu89-inline"
    echo "  gcc $GCC_MAJOR: 加 -fgnu89-inline（老内核的 extern inline 语义）"
fi
# gcc 10 起默认 -fno-common，老内核的重复 tentative definition 会报错。
if [ "$GCC_MAJOR" -ge 10 ]; then
    KCFLAGS_EXTRA="$KCFLAGS_EXTRA -fcommon"
    echo "  gcc $GCC_MAJOR: 加 -fcommon"
fi
if [ "$GCC_MAJOR" -ge 12 ]; then
    warn "gcc 12+ 编 3.0 内核成功率低，建议换 gcc 4.9/5.4 或 AOSP arm-eabi-4.6"
fi

# --------------------------------------------------------------- 4. config
# 3.0.35 只带了 compiler-gcc3.h / compiler-gcc4.h；
# compiler-gcc.h 会按 __GNUC__ 拼出 linux/compiler-gcc<N>.h，用新 gcc 编就找不到文件。
# 这里按当前编译器版本补一个转发头，复用 gcc4 的定义。
CG_H="$KERNEL_DIR/include/linux/compiler-gcc${GCC_MAJOR}.h"
if [ ! -f "$CG_H" ]; then
    log "补 compiler-gcc${GCC_MAJOR}.h（本内核早于 gcc ${GCC_MAJOR}）"
    cat > "$CG_H" <<EOF
#ifndef __LINUX_COMPILER_H
#error "Please don't include <linux/compiler-gcc${GCC_MAJOR}.h> directly, include <linux/compiler.h> instead."
#endif

/* This kernel predates gcc ${GCC_MAJOR}; reuse the gcc4 capability definitions. */
#include <linux/compiler-gcc4.h>
EOF
    echo "  已生成 $(basename "$CG_H")"
else
    echo "  compiler-gcc${GCC_MAJOR}.h 已存在"
fi

# gcc 5 起不再保证 "r" 约束被分配到某个具体寄存器，
# 而 3.0 的 div64.h / uaccess.h 用 __asmeq 做"偏执检查"（源码注释自称 paranoia），
# 一旦寄存器编号不符就由汇编器 .ifnc/.err 报错。
# 那些内联汇编用的是操作数编号 %0/%1/%2，本身不依赖具体寄存器，
# 所以停用这个断言不改变生成的代码，只是不再强制校验。
if grep -q 'ifnc.*\.err' "$KERNEL_DIR/arch/arm/include/asm/system.h" 2>/dev/null; then
    sed -i 's|^#define __asmeq(x, y).*|#define __asmeq(x, y)|' \
        "$KERNEL_DIR/arch/arm/include/asm/system.h"
    echo "  已停用 __asmeq 汇编寄存器断言"
fi

# perl 5.22 起禁止 defined(@array)（运行时报
# "Can't use 'defined(@array)'"），3.0 的 timeconst.pl 还在用。
if grep -q 'defined(@val)' "$KERNEL_DIR/kernel/timeconst.pl" 2>/dev/null; then
    sed -i 's/if (!defined(@val))/if (!@val)/' "$KERNEL_DIR/kernel/timeconst.pl"
    echo "  已修正 timeconst.pl 的 defined(@array)"
fi

log "写入 .config"
cp "$CONFIG_SRC" "$KERNEL_DIR/.config"
echo "  已复制 $(wc -l < "$CONFIG_SRC") 行"

log "make oldconfig（非交互，新符号取默认值）"
# 这里必须只看 make 的退出码。
# `yes "" |` 喂满 make 之后，make 一退出，yes 就会吃到 SIGPIPE（退出码 141）；
# 在 set -o pipefail 下，整条管道会被判为失败 —— 即使 oldconfig 明明写成功了。
set +e
set +o pipefail
yes "" | make -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
    oldconfig > "$OUT_DIR/oldconfig.log" 2>&1
rc_old=$?
set -o pipefail
set -e
if [ "$rc_old" -ne 0 ]; then
    tail -30 "$OUT_DIR/oldconfig.log"
    die "oldconfig 失败（make 退出码 $rc_old），完整日志: $OUT_DIR/oldconfig.log"
fi
echo "  oldconfig 完成"

# 关键项必须成立，否则说明 config 被源码 Kconfig 改掉了
log "校验关键配置"
CONFIG_FILE="$KERNEL_DIR/.config"
check_cfg() {
    local key="$1" want="$2" desc="$3"
    local got
    got=$(grep -E "^${key}=" "$CONFIG_FILE" 2>/dev/null | head -1 | cut -d= -f2 || true)
    if [ "$got" = "$want" ]; then
        printf '  \033[32mOK\033[0m   %-30s = %s   %s\n' "$key" "$got" "$desc"
    else
        printf '  \033[31mFAIL\033[0m %-30s = %s (期望 %s)   %s\n' "$key" "${got:-<未设置>}" "$want" "$desc"
        return 1
    fi
}
fails=0
check_cfg CONFIG_USB_GADGET      y "USB gadget 框架"            || fails=$((fails+1))
check_cfg CONFIG_USB_G_ANDROID   y "Android gadget（含我们的 iap/ncm）" || fails=$((fails+1))
check_cfg CONFIG_MACH_MX6Q_SABRESD y "官方 sabresd 板级"        || fails=$((fails+1))
if grep -q '^CONFIG_LOCALVERSION_AUTO=y' "$CONFIG_FILE"; then
    printf '  \033[31mFAIL\033[0m CONFIG_LOCALVERSION_AUTO 竟然还是 y，vermagic 会带 -g<hash>\n'
    fails=$((fails+1))
else
    printf '  \033[32mOK\033[0m   %-30s\n' "CONFIG_LOCALVERSION_AUTO 已关闭"
fi
[ "$fails" -eq 0 ] || die "$fails 项关键配置不成立，先修 config"

# ----------------------------------------------------------------- 5. build
log "编译 zImage（-j$JOBS）"
BUILD_LOG="$OUT_DIR/build.log"
set +e
make -C "$KERNEL_DIR" ARCH=arm CROSS_COMPILE="$CROSS_COMPILE" \
     KCFLAGS="$KCFLAGS_EXTRA" -j"$JOBS" zImage 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}
set -e
[ "$rc" -eq 0 ] || {
    echo
    warn "编译失败（退出码 $rc），最后 30 行："
    tail -30 "$BUILD_LOG"
    echo
    echo "常见原因："
    echo "  - gcc 太新：换 gcc 4.9/5.4，或 AOSP arm-eabi-4.6"
    echo "  - 缺 32 位库：sudo apt install lib32z1 lib32ncurses5"
    echo "  - CRLF 污染：脚本/ Makefile 必须是 LF，用 file scripts/Makefile.build 检查"
    die "编译失败，完整日志: $BUILD_LOG"
}

# ---------------------------------------------------------------- 6. verify
ZIMAGE="$KERNEL_DIR/arch/arm/boot/zImage"
VMLINUX="$KERNEL_DIR/vmlinux"
[ -f "$ZIMAGE" ] || die "没有产出 zImage"
cp "$ZIMAGE" "$OUT_DIR/zImage"

log "校验产物"
ls -la "$ZIMAGE" | sed 's/^/  /'

if [ -f "$VMLINUX" ]; then
    echo
    echo "  内核版本串："
    python3 - "$VMLINUX" <<'PY' | sed 's/^/    /'
import re, sys
d = open(sys.argv[1], 'rb').read()
m = re.search(rb'Linux version [^\x00]{0,180}', d)
print(m.group().decode('ascii', 'replace') if m else 'NOT FOUND')
PY

    echo
    echo "  gadget 符号："
    for sym in iap_bind_config iap_setup iap_function_bind ncm_bind_config gether_setup_name; do
        if "${CROSS_COMPILE}nm" "$VMLINUX" 2>/dev/null | grep -qE " [tT] ${sym}$"; then
            printf '    \033[32mOK\033[0m   %s\n' "$sym"
        else
            printf '    \033[31mMISS\033[0m %s\n' "$sym"
        fi
    done

    echo
    echo "  描述符字节（NCM 应为 02 0D 00 与 0A 00 01）："
    python3 - "$VMLINUX" <<'PY' | sed 's/^/    /'
import sys
d = open(sys.argv[1], 'rb').read()
for pat, label in [(b'\x09\x04\x00\x00\x01\x02\x0d\x00\x00', 'NCM control 09 04 .. 02 0D 00'),
                   (b'\x09\x04\x00\x00\x02\x0a\x00\x01\x00', 'NCM data    09 04 .. 0A 00 01'),
                   (b'\x09\x04\x00\x00\x02\xff\xf0\x00\x00', 'iAP         09 04 .. FF F0 00')]:
    print('%-38s %s' % (label, 'FOUND x%d' % d.count(pat) if d.count(pat) else 'NOT FOUND'))
PY
fi

cat <<EOF

$(printf '\033[1m== 完成 ==\033[0m')

  zImage : $OUT_DIR/zImage
  日志   : $BUILD_LOG

下一步（在 Windows 上）：
  python repack_boot.py --kernel $OUT_DIR/zImage \\
                        --ramdisk ramdisk.new.gz \\
                        --out boot-iap-ncm.img

然后用 fastboot boot 只加载内存验证，不写 flash：
  fastboot boot boot-iap-ncm.img

判据（通过 WiFi ADB 抓 dmesg）：
  1) 出现 "iap: /dev/android_iap registered"
  2) 出现 "ncm_function_bind_config netdev usb0 MAC ..."
  3) ip link 或 /sys/class/net 里有 usb0
  4) DiPlay 日志出现 "first frame rendered"
EOF
