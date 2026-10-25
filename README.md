# ubuntu-image-builder

Builds bootable Ubuntu images for RK3588 single-board computers from
Ubuntu's official arm64 ISOs.

The default (**stock**) path keeps Ubuntu's own kernel and rootfs, writes our
U-Boot to the image, and installs a few small board and camera packages from
[`packages/`](packages/README.md). Custom kernels (**vendor** or **mainline**)
are still available for development.

| Board | `--board` | Status (stock kernel) |
|---|---|---|
| Orange Pi 5B | `orangepi-5b` | Tested: boot, eMMC/SD, WiFi/BT out of the box, status LED, IMX708 camera on cam1 |
| Orange Pi 5 | `orangepi-5` | Builds; not tested on hardware |
| Radxa ROCK 5B+ | `rock-5b-plus` | Tested: boot, WiFi/BT out of the box, status LED, IMX708 on cam0 and cam1 |

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
image, which takes a few minutes. A `.deb` is rebuilt automatically, along
with the rootfs, only when its `debian/changelog` version changes, so use `-rd`
after editing anything under `packages/` without bumping the version.

## How the stock path works

```
Ubuntu ISO ──build-rootfs.sh──► build/rootfs/<release>-<flavor>/   (+ board/camera .debs, DKMS)
                                        │
U-Boot + rkbin ──build-u-boot.sh──►  build/u-boot/<board>/u-boot-rockchip.bin
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
   kernel type; building for a different board rebuilds the rootfs. On
   Ubuntu 25.10+ it keeps **dracut** (and does not install initramfs-tools,
   which would remove dracut); older releases use initramfs-tools.
3. **`scripts/build-u-boot.sh`** writes a **per-board** binary under
   `build/u-boot/<board>/`, so switching boards does not reuse another
   board's blob. The u-boot/rkbin source trees are shared.
4. **`scripts/build-image.sh`** copies the rootfs into a new image. It keeps
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
  modules, so the root filesystem on SD/eMMC can be mounted. Board packages
  ship both an initramfs-tools hook and a dracut module (`50rk3588-mmc`).
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
- It applies only the `rk3588s-orangepi-5b.dts` hunk of kernel patch
  **0006** (the 5B's WiFi on `pcie2x1l2` and Bluetooth on `uart9`). The ISP
  nodes come from `rk3588-isp.dtbo` at boot, as on every board (see
  [Cameras](#cameras)).
- It adds `rk3588s-orangepi-5b-wifi-lpo.dtsi`. The WiFi chip needs the
  HYM8563 RTC's 32 kHz clock, and `rtc-hym8563` switches that clock off when
  it probes. On Ubuntu that driver loads from the initramfs just before PCIe
  link training, so the link failed ("Device found, but not active"). The
  fragment chains the WiFi and PCIe power supplies behind a
  `regulator-fixed-clock`, so the PCIe host waits until the clock is back on.
- It compiles with `-@`, so camera overlays can apply.

The AP6275P firmware is vendored in
[`packages/rk3588-board-orangepi-5b/firmware/`](packages/rk3588-board-orangepi-5b/firmware/README.md).
WiFi and Bluetooth work on a fresh install of the built image. When Ubuntu
moves to a newer kernel, bump `DTS_KERNEL_REF`.

### Orange Pi 5

No onboard WiFi or Bluetooth. Ubuntu's DTB is compiled without overlay
symbols, so the board package ships its **own DTB**, built by
`packages/rk3588-board-orangepi-5/files/build-dtb.sh` from the same upstream
ref as the 5B, with `-@` and no board-specific DTS patches. ISP nodes come
from `rk3588-isp.dtbo` at boot.

### ROCK 5B+

The onboard Radxa A8 module is an RTL8852BE (WiFi over PCIe, Bluetooth over
USB). Its drivers and firmware are already in Ubuntu's kernel and
`linux-firmware`, so WiFi and Bluetooth work on a fresh install. Uses
Ubuntu's DTB (which has `__symbols__`).

## Cameras

`rk3588-camera-dkms` builds the `imx708` sensor driver and the `rkisp2` ISP
driver against the installed kernel. `rk3588-camera-overlays` ships one
overlay per CSI port and one overlay per sensor. None are enabled by default.

A port overlay turns the connector on (I2C, clock, reset, regulator, CSI
host) and publishes `cam_portN_*` labels. A sensor overlay describes the
chip and attaches to whichever port you name. It also enables one ISP.
U-Boot does not apply Raspberry Pi overlay parameters, so
`apply-overlays.sh` bakes `portN`, `ispN`, `4lane`, `link-frequency`,
`rotation`, and `orientation` into a dtbo under `/var/lib/rk3588-camera/`
and points `U_BOOT_FDT_OVERLAYS` at it. It also selects the port overlay
for the installed board package.

```bash
sudo sed -i 's/^RK3588_CAMERA_OVERLAYS=.*/RK3588_CAMERA_OVERLAYS="imx708,port1"/' \
    /etc/rk3588-camera/overlays.conf
sudo /usr/lib/rk3588-camera/apply-overlays.sh
sudo reboot
```

The port number is the CAM number on the board:

| Board | Ports |
|---|---|
| Orange Pi 5 / 5B | `port1` (CAM1), `port2` (CAM2), `port3` (CAM3) |
| ROCK 5B+ | `port0` (CAM0), `port1` (CAM1) |

Two cameras, or a Pi-style link-frequency override:

```bash
RK3588_CAMERA_OVERLAYS="imx708,port1 imx708,port2"
RK3588_CAMERA_OVERLAYS="imx708,port0,link-frequency=447000000"
RK3588_CAMERA_OVERLAYS="imx708,port1,isp1"
```

The first camera in that list enables isp0 and its IOMMU. The second
enables isp1. `isp0` or `isp1` on a camera overrides that. Two cameras
cannot share an ISP. On an Orange Pi 5B, `imx708,port1 imx708,port2`
puts CAM1 on isp0 and CAM2 on isp1.

`link-frequency` is in Hz. The imx708 driver accepts 447000000, 450000000
(the default), and 453000000, and only two data lanes. `4lane` is the same
knob the Pi has; the imx708 driver rejects it. `orientation` is 0 front,
1 rear, 2 external (default 2).

Sensors shipped: `imx708` (the DKMS driver), `imx219` (mainline binding;
needs the kernel's imx219 module), `imx519` (Raspberry Pi binding; no driver
in this repo), `imx415` (Radxa Camera 4K at 0x1a; Raspberry Pi modules such
as Arducam's B0569 answer at 0x37, so use `addr=0x37`. Needs the kernel's imx415 module.
Four lanes at 720 MHz, 3864x2192 at about 60 fps. `link-frequency=360000000`
gives about 30 fps). Adding another sensor is a new `.dtso` with the same
`cam_port_*` fixups.

`apply-overlays.sh` treats `overlays.conf` as the full camera list: it
replaces previously managed camera/ISP entries in `U_BOOT_FDT_OVERLAYS` and
keeps unrelated overlays. To switch cameras, edit the conf and re-run the
script. To disable them, set `RK3588_CAMERA_OVERLAYS=""` and re-run.

After reboot, `cat /proc/device-tree/isp@fdcb0000/status` should print
`okay`. The pipeline uses two media devices: `rockchip-cif` captures from the
sensor into memory, and `rkisp2` reads the frames back through
`rkisp2_rawrd0` for processing. Processed images need a libcamera build with
the rkisp2 pipeline handler, which Ubuntu's libcamera doesn't have yet. Build
it yourself for now. The upstream rkisp2 branch
(`git.ideasonboard.com/epaul/libcamera`, `epaul/dev/rkisp2/upstream-v3`) only
matches cameras on the csi2 port, so ROCK 5B+ cam1 (csi4) needs a libcamera
patch until that's fixed upstream; it also creates one camera per pipeline
handler, so two cameras at once isn't supported there yet. That patch is not
shipped in this repo.

Stock kernels' DTBs don't have the ISP nodes the camera overlays reference
(they come from kernel patch 0002), so `apply-overlays.sh` always puts
`rk3588-isp.dtbo` first. Port
overlays come after that, then the sensor. U-Boot
applies overlays in order and merges each one's labels into the base DTB, so
the sensor can resolve `cam_portN_*`. Overlays also need the base DTB to have
`__symbols__`:

| Board | Base DTB | Camera ports |
|---|---|---|
| Orange Pi 5B | Packaged (built with `-@`) | port1 tested on hardware (as the old cam1 IMX708 overlay); port2 (CAM2) and port3 (CAM3) tested on hardware |
| ROCK 5B+ | Ubuntu's (has `__symbols__`, since upstream ships overlays for it) | port0 and port1 together; tested on hardware as the old cam0/cam1 overlays. ISP follows list order now |
| Orange Pi 5 | Packaged (built with `-@`) | port1/port2/port3 can apply; not tested on hardware |

The generated sensor overlay enables the chosen ISP and leaves capture on
VICAP. It does not wire CSI straight into the ISP (that needed the
unapplied kernel patch 0003).
The RK3588's two MIPI DCPHYs (`mipidcphy0`/`mipidcphy1`) can receive CSI, but
Ubuntu's `phy-rockchip-samsung-dcphy` is transmitter-only. `rk3588-camera-dkms`
replaces it with the patched one from kernel patch 0001 on any board. A camera
port on a DCPHY then needs a CSI host and a PHY with two phy-cells in its
overlay. Only the Orange Pi 5/5B port2 (DCPHY0) and port3 (DCPHY1) overlays do
that so far, using the CSI hosts from patch 0005 that stock DTBs lack. CAM2
and CAM3 were both tested on the Orange Pi 5B.

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
- **GitHub rate limits.** The Orange Pi 5 and 5B package builds fetch
  device-tree sources from GitHub. The fetch is cached under each package's
  `build/` directory, but fresh clones and CI fetch every time and can hit
  HTTP 429.
- **Cosmetic.** `build-image.sh` passes `${SUITE}` to board hooks, but nothing
  sets it (the hooks don't use it). The release configs misspell
  `RELASE_NAME`/`RELASE_VERSION`; `RELASE_VERSION` is what selects dracut
  vs initramfs-tools.
