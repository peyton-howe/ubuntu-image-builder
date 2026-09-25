# RK3588 board / camera packages

Debian packages for the **stock Ubuntu ISO + U-Boot** path (`stock-iso-packages` branch).

| Package | Role |
|---------|------|
| `rk3588-camera-overlays` | IMX708 `.dtbo` overlays + enablement config |
| `rk3588-camera-dkms` | Out-of-tree camera modules (IMX708; rkisp2 + DCPHY staged) |
| `rk3588-board-orangepi-5` | Orange Pi 5 board glue (firmware, flash-kernel, u-boot-menu) |
| `rk3588-board-orangepi-5b` | Orange Pi 5B board glue |
| `rk3588-board-rock-5b-plus` | ROCK 5B+ board glue |

### Host build deps

```bash
sudo apt install debhelper dh-dkms device-tree-compiler dpkg-dev dkms
```

### Build packages

```bash
./scripts/build-debs.sh
# or via the image builder:
./build.sh --debs-only
# artifacts → build/debs/
```

### Full stock-ISO image

Default `--kernel-type=stock` keeps the Ubuntu ISO kernel, builds these
packages, writes U-Boot, and installs the matching board + camera debs:

```bash
./build.sh --board=orangepi-5b --release=questing --flavor=desktop
# equivalent: --kernel-type=stock
```

Custom kernels remain available: `--kernel-type=mainline` or `vendor`.

Driver / overlay sources were extracted from `patches/kernel/mainline/`. Re-extract after series changes:

```bash
./scripts/extract-oot-from-patches.sh
```
