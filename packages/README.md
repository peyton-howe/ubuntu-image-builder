# RK3588 board / camera packages

Debian packages for the **stock Ubuntu ISO + U-Boot** path (`stock-iso-packages` branch).

| Package | Role |
|---------|------|
| `rk3588-camera-overlays` | IMX708 `.dtbo` overlays + enablement config |
| `rk3588-camera-dkms` | Out-of-tree camera modules (IMX708; rkisp2 + DCPHY staged) |
| `rk3588-board-orangepi-5` | Orange Pi 5 board glue (firmware, flash-kernel, u-boot-menu) |
| `rk3588-board-orangepi-5b` | Orange Pi 5B board glue |
| `rk3588-board-rock-5b-plus` | ROCK 5B+ board glue |

Build all (on arm64, or with cross tooling as needed):

```bash
./scripts/build-debs.sh
# artifacts → build/debs/
```

Driver / overlay sources were extracted from `patches/kernel/mainline/`. Re-extract after series changes:

```bash
./scripts/extract-oot-from-patches.sh
```
