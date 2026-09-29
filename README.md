# ubuntu-image-builder

Builds bootable Ubuntu images for RK3588 single-board computers from
Ubuntu's official arm64 ISOs.

The default (**stock**) path keeps Ubuntu's own kernel and rootfs, writes our
U-Boot to the image, and installs a few small board and camera packages from
[`packages/`](packages/README.md). Custom kernels (**vendor** or **mainline**)
are still available for development.

| Board | `--board` | Status (stock kernel) |
|---|---|---|
| Orange Pi 5B | `orangepi-5b` | Tested: boot, eMMC/SD, WiFi, Bluetooth, status LED, IMX708 camera on cam1 |
| Orange Pi 5 | `orangepi-5` | Builds; not tested on hardware |
| Radxa ROCK 5B+ | `rock-5b-plus` | Builds; not tested on hardware |

Releases (`--release`): `questing` (25.10), `resolute` (26.04), `stonking`
(26.10 daily). Flavors (`--flavor`): `desktop`, `server`.

## Quick start

Build on an Ubuntu host (arm64 native, or x86_64 with `qemu-user-static`),
**as root** (see [Known issues](#known-issues)):

```bash
sudo apt install git make gcc gcc-aarch64-linux-gnu bison flex swig \
    python3-dev python3-pyelftools libssl-dev libgnutls28-dev uuid-dev \
    debhelper dh-dkms dkms dpkg-dev device-tree-compiler \
    squashfs-tools parted e2fsprogs xz-utils wget
# x86_64 hosts also need: qemu-user-static binfmt-support

sudo ./build.sh -b orangepi-5b -r stonking -f desktop
```

The image lands in `images/ubuntu-<release>-preinstalled-<flavor>-arm64-<board>.img[.xz]`.
Flash it to an SD card or eMMC (e.g. `xzcat image.img.xz | sudo dd of=/dev/sdX bs=4M status=progress`,
or balenaEtcher). The root partition grows to fill the disk on first boot.

The first build downloads the ISO (~4.5 GB), U-Boot and rkbin, and the
upstream device-tree sources for the Orange Pi 5B (~16 MB, from GitHub).

## Options

```
-b, --board=BOARD         orangepi-5 | orangepi-5b | rock-5b-plus
-r, --release=RELEASE     questing | resolute | stonking
-f, --flavor=FLAVOR       desktop | server
-kt, --kernel-type=TYPE   stock (default) | vendor | mainline
    --compress / --no-compress   xz the final image (default: compress)
-c,  --clean              delete build/ entirely

Rebuild one stage (and everything after it):
-rd, --rebuild-debs       packages/ changed        -> debs, rootfs, image
-rr, --rebuild-rootfs     want a fresh rootfs      -> rootfs, image (keeps the ISO)
-ru, --rebuild-uboot      U-Boot changed           -> U-Boot, image
-rk, --rebuild-kernel     vendor/mainline kernel   -> kernel, rootfs, image

Only run one stage:
-do, --debs-only   -ro, --rootfs-only   -uo, --uboot-only   -ko, --kernel-only
```

A plain rerun without flags reuses every finished stage and rebuilds only the
image, which takes a few minutes. Existing `.deb`s are **not** rebuilt
automatically, so use `-rd` after editing anything under `packages/`.

## How the stock path works

```
Ubuntu ISO ──build-rootfs.sh──► build/rootfs/<release>-<flavor>/   (+ board/camera .debs, DKMS)
                                        │
U-Boot + rkbin ──build-u-boot.sh──►  build/u-boot/u-boot-rockchip.bin
                                        │
                           build-image.sh ──► images/*.img  (GPT, one ext4 root, U-Boot at 32 KiB)
```

1. **`scripts/build-debs.sh`** builds `packages/rk3588-*` into `build/debs/`.
2. **`scripts/build-rootfs.sh`** downloads and verifies the ISO. If Ubuntu has
   respun a daily ISO, it downloads it again from scratch. It then unpacks
   the desktop or server squashfs layers and, in a chroot, installs
   `u-boot-menu`, DKMS, headers matching the ISO's kernel, and the board and
   camera packages. It fails if the board package doesn't install. It
   finishes by writing `<release>-<flavor>.done`, which records the board and
   kernel type; building for a different board rebuilds the rootfs.
3. **`scripts/build-image.sh`** copies the rootfs into a new image. It keeps
   numeric owners, xattrs and ACLs, so file capabilities like `snap-confine`'s
   survive. It then writes fstab, `/etc/default/u-boot` and `extlinux.conf`,
   and dd's U-Boot.

The board packages make Ubuntu's kernel bootable from our U-Boot:

- **Kernel unpacking.** Ubuntu's arm64 `vmlinuz` is a PE/EFI wrapper
  (stubble, with built-in DTBs) around an EFI zboot image around a
  zstd-compressed kernel. U-Boot's extlinux path uses `booti`, which only
  accepts a raw ARM64 `Image` ("Bad Linux ARM64 Image magic!"). The
  `/etc/kernel/postinst.d/zz-rk3588-unwrap-kernel` hook replaces each
  `vmlinuz` in place with the raw Image, now and on every kernel upgrade.
- **initramfs.** Adds the Rockchip MMC drivers, which Ubuntu builds as
  modules, so the root filesystem on SD/eMMC can be mounted.
- **flash-kernel.** Its database doesn't know these boards, and without an
  entry kernel upgrades fail. The package merges a `Machine:` entry into
  `/etc/flash-kernel/db`.
- **Status LED.** Loads `ledtrig_heartbeat` at boot.

## Board notes

### Orange Pi 5B

Ubuntu's 5B device tree doesn't describe the AP6275P WiFi/Bluetooth module,
and it's compiled without overlay symbols. The board package therefore ships
its **own DTB**, built by `packages/rk3588-board-orangepi-5b/files/build-dtb.sh`:

- It sparse-fetches the upstream rockchip DTS at `DTS_KERNEL_REF`
  (default `v7.3-rc4`, matching Ubuntu's 7.3 kernel). The fetch uses the
  GitHub mirror, because git.kernel.org ignores partial-clone filters.
- It applies only the device-tree hunks of kernel patches **0006** (the 5B's
  WiFi on `pcie2x1l2` and Bluetooth on `uart9`) and **0002** (the ISP nodes,
  disabled until a camera overlay enables them).
- It adds `rk3588s-orangepi-5b-wifi-lpo.dtsi`. The WiFi chip needs the
  HYM8563 RTC's 32 kHz clock, and `rtc-hym8563` switches that clock off when
  it probes. On Ubuntu that driver loads from the initramfs just before PCIe
  link training, so the link failed ("Device found, but not active"). The
  fragment chains the WiFi and PCIe power supplies behind a
  `regulator-fixed-clock`, so the PCIe host waits until the clock is back on.
- It compiles with `-@`, so camera overlays can apply.

The AP6275P firmware is vendored in
[`packages/rk3588-board-orangepi-5b/firmware/`](packages/rk3588-board-orangepi-5b/firmware/README.md).
When Ubuntu moves to a newer kernel, bump `DTS_KERNEL_REF`.

### Orange Pi 5

No onboard WiFi or Bluetooth. Uses Ubuntu's DTB.

### ROCK 5B+

The onboard Radxa A8 module is an RTL8852BE (WiFi over PCIe, Bluetooth over
USB). Its drivers and firmware are already in Ubuntu's kernel and
`linux-firmware`. Uses Ubuntu's DTB.

## Cameras (IMX708)

`rk3588-camera-dkms` builds the `imx708` sensor driver and the `rkisp2` ISP
driver against the installed kernel. `rk3588-camera-overlays` ships the
overlays. None are enabled by default. On the board:

```bash
sudo sed -i 's/^RK3588_CAMERA_OVERLAYS=.*/RK3588_CAMERA_OVERLAYS="rk3588s-orangepi-5-cam1-imx708"/' \
    /etc/rk3588-camera/overlays.conf
sudo /usr/lib/rk3588-camera/apply-overlays.sh
sudo reboot
```

After reboot, `cat /proc/device-tree/isp@fdcb0000/status` should print
`okay`. The pipeline uses two media devices: `rockchip-cif` captures from the
sensor into memory, and `rkisp2` reads the frames back through
`rkisp2_rawrd0` for processing. Processed images need a libcamera build with
the rkisp2 pipeline handler, which Ubuntu's libcamera doesn't have yet. Build
it yourself for now.

Stock kernels' DTBs don't have the ISP nodes the camera overlays reference
(they come from kernel patch 0002), so `apply-overlays.sh` always puts
`rk3588-isp.dtbo` first; U-Boot applies overlays in order and merges each
one's labels into the base DTB. Overlays also need the base DTB to have
`__symbols__`:

| Board | Base DTB | Camera overlays |
|---|---|---|
| Orange Pi 5B | Packaged (built with `-@`) | cam1 tested on hardware |
| ROCK 5B+ | Ubuntu's (has `__symbols__`, since upstream ships overlays for it) | cam0 (isp0) and cam1 (isp1), both at once; verified with `fdtoverlay`, not yet on hardware. Use the plain overlays, not `-isp` (those need the unapplied patch 0003) |
| Orange Pi 5 | Ubuntu's, **no** `__symbols__` | Won't apply; needs a packaged DTB like the 5B's |

cam2/cam3 on the Orange Pi 5/5B use the DCPHY, which needs a patched
`phy-rockchip-samsung-dcphy` (kernel patch 0001). That isn't packaged for the
stock kernel yet.

## Custom kernels (vendor / mainline)

`--kernel-type=mainline` builds a kernel from the ideasonboard rkisp2 tree
with `patches/kernel/mainline/series`. `--kernel-type=vendor` builds the
Rockchip BSP kernel. Both install their own `linux-image` and skip the stock
board packages. Board-specific setup for these paths lives in
`configs/boards/<board>.sh`. Some of it needs the Armbian firmware tree in
`overlay/firmware/`, which isn't in git:
`git clone --depth 1 https://github.com/armbian/firmware.git overlay/firmware`.

After changing the patch series, run `./scripts/extract-oot-from-patches.sh`
to regenerate the DKMS sources and overlays in `packages/`.

## Known issues

- **Run as root (`sudo ./build.sh`).** Without root, `build.sh` re-executes
  itself in an unprivileged user namespace. That mode can't produce a correct
  image: only uid 0 is mapped, so the rootfs copy can't restore non-root file
  owners, and file capabilities written there aren't valid on the board.
  Builds without sudo are unsupported.
- **initramfs-tools replaces dracut.** Ubuntu 26.10 defaults to dracut, but
  `build-rootfs.sh` installs `initramfs-tools`, which removes dracut. The
  board packages' MMC hook is an initramfs-tools hook. If Ubuntu stops
  shipping initramfs-tools, that hook needs a dracut equivalent.
- **GitHub rate limits.** The 5B package build fetches device-tree sources
  from GitHub. The fetch is cached in `packages/rk3588-board-orangepi-5b/build/`,
  but fresh clones and CI fetch every time and can hit HTTP 429.
- **Cosmetic.** `build-image.sh` passes `${SUITE}` to board hooks, but nothing
  sets it (the hooks don't use it). The release configs export misspelled
  `RELASE_NAME`/`RELASE_VERSION`, which nothing reads.
