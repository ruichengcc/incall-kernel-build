# 车机内核编译（i.MX6DL / Linux 3.0.35 / Android 4.4.2）

给长安 incall 车机编一个带 **CDC-NCM + iAP2** 的内核，用于有线 CarPlay。

## 文件说明

| 文件 | 作用 |
|---|---|
| `0001-iap2-ncm.patch` | 内核改动：`android.c` 接入 NCM/iAP2 function，新增 `f_iap2.c`，清掉 `f_ncm.c` 的 `__initdata` |
| `build.config` | 从车机运行内核提取的 `.config`，已关掉 `CONFIG_LOCALVERSION_AUTO` |
| `build-kernel.sh` | 构建脚本，带依赖检查、config 校验、产物自检 |
| `.github/workflows/build.yml` | 云端编译流水线 |

## 用法 A：GitHub Actions（不需要装任何东西）

1. 在 GitHub 新建一个仓库（公开/私有都行）
2. 把这个目录里的**全部文件**（含 `.github` 目录）上传上去
   - 网页上传时注意：`.github/workflows/build.yml` 必须保持这个路径，GitHub 才会识别流水线
3. 上传后自动开始跑；也可以到 **Actions** 页点 `Run workflow` 手动触发
4. 约 5–15 分钟后，在 Actions 那次运行的页面底部 **Artifacts** 下载 `zImage`

流水线内部做的事：
```
ubuntu:20.04 容器（保证 gcc 9，老内核编得过）
  → 装 build-essential / bison / flex / bc / gcc-arm-linux-gnueabi
  → git clone kk4.4.2_1.0.0-ga
  → git apply 补丁
  → build-kernel.sh 编译 + 自检
  → 上传 zImage
```

**编译日志里要确认这几行**（脚本会自己打印）：
```
OK   CONFIG_USB_GADGET        = y
OK   CONFIG_USB_G_ANDROID     = y
OK   CONFIG_MACH_MX6Q_SABRESD = y
OK   CONFIG_LOCALVERSION_AUTO 已关闭
OK   iap_bind_config / iap_setup / iap_function_bind / ncm_bind_config / gether_setup_name
NCM control 09 04 .. 02 0D 00   FOUND
NCM data    09 04 .. 0A 00 01   FOUND
iAP         09 04 .. FF F0 00   FOUND
```

## 用法 B：本机 Ubuntu 虚拟机

```bash
sudo apt update
sudo apt install -y build-essential bison flex bc libncurses5-dev git \
                    python3 gcc-arm-linux-gnueabi
git clone --depth 1 --single-branch --branch kk4.4.2_1.0.0-ga \
    https://github.com/GT-System/linux-2.6-imx.git ~/kb/linux-2.6-imx
cd ~/kb/linux-2.6-imx
git config core.autocrlf false
git apply /path/to/0001-iap2-ncm.patch
KERNEL_DIR=~/kb/linux-2.6-imx CONFIG_SRC=/path/to/build.config \
    bash /path/to/build-kernel.sh
```

产物在 `~/kb/out/zImage`。

## 拿到 zImage 之后

在 Windows 上打包成 boot.img（保持与原图完全同大小）：

```bash
python repack_boot.py --kernel zImage --ramdisk ramdisk.new.gz --out boot-iap-ncm.img
```

上车验证（只加载内存，不写 flash，失败断电即恢复）：

```bash
fastboot boot boot-iap-ncm.img
```

判据链：

```
1) dmesg: iap: /dev/android_iap registered
2) dmesg: ncm_function_bind_config netdev usb0 MAC ...
3) ls /sys/class/net/  → usb0 存在且有 fe80:: 地址
4) DiPlay 日志：first frame rendered
```

## 如果编译报错

| 现象 | 原因 | 处理 |
|---|---|---|
| `-fno-common` 重复定义 | gcc ≥ 10 | 脚本已自动加 `-fcommon`；若仍报错，换成 ubuntu 20.04 容器 / gcc 9 |
| `scripts/Makefile.build: not found` | 文件是 CRLF | `git config core.autocrlf false` 后重新 clone |
| `arm-linux-gnueabi-gcc: not found` | 缺工具链 | `apt install gcc-arm-linux-gnueabi` |
| 大量 `error: ... unknown register name` | binutils 太新 | 换 20.04 容器环境 |
