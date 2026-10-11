# RK3588 board / camera packages

Debian packages installed into the rootfs on the **stock** kernel path
(`--kernel-type=stock`, the default). See the top-level
[README](../README.md#how-the-stock-path-works) for how they fit into an image.

| Package | Contents |
|---|---|
| `rk3588-board-orangepi-5b` | Board glue (below), plus its own DTB (upstream DTS + the 5B hunk of kernel patch 0006 + `files/rk3588s-orangepi-5b-*.dtsi`) and the AP6275P WiFi/BT firmware |
| `rk3588-board-orangepi-5` | Board glue, plus its own DTB (upstream DTS built with `-@` so camera overlays can apply) |
| `rk3588-board-rock-5b-plus` | Board glue |
| `rk3588-camera-dkms` | DKMS: `imx708` sensor + `rkisp2` ISP (`rockchip-isp2`). DCPHY is staged in `src/dcphy`, not built |
| `rk3588-camera-overlays` | IMX708 `.dtbo`s, `rk3588-isp.dtbo` (ISP nodes from patch 0002, applied first by `apply-overlays.sh`), `/etc/rk3588-camera/overlays.conf`, `apply-overlays.sh` (treats the conf as the full camera-overlay list) |

**Board glue**, shared by all three board packages:

| File | Purpose |
|---|---|
| `files/unwrap-kernel` → `/etc/kernel/postinst.d/zz-rk3588-unwrap-kernel` | Replaces Ubuntu's wrapped `vmlinuz` with a raw ARM64 Image for U-Boot `booti`. Also runs from `postinst` for already-installed kernels |
| `files/initramfs-hook` → `/etc/initramfs-tools/hooks/rk3588-mmc` | Rockchip MMC drivers in the initramfs (pre-25.10) |
| `files/dracut-module-setup.sh` → `/usr/lib/dracut/modules.d/50rk3588-mmc/module-setup.sh` | Same MMC modules for dracut (Ubuntu 25.10+) |
| `files/flash-kernel.db` | Merged into `/etc/flash-kernel/db` between `# BEGIN/END <pkg>` markers (`postinst`/`postrm`); flash-kernel owns that file |
| `files/u-boot.default` | Keys merged into `/etc/default/u-boot` on every install/upgrade, then `u-boot-update` |
| `files/modules-load.conf` | Loads `ledtrig_heartbeat` for the status LED |

## Building

```bash
sudo apt install debhelper dh-dkms dkms dpkg-dev device-tree-compiler gcc git
sudo ./scripts/build-debs.sh                          # all packages → build/debs/
sudo ./scripts/build-debs.sh rk3588-board-orangepi-5b # just one
```

Build with sudo, the same way as the image. Package builds leave root-owned
files in `packages/*/build/`, so a later build without sudo fails to clean
them. `build-debs.sh` keeps only the newest `.deb` of each package in
`build/debs/`. Bump `debian/changelog` when you change a package; a plain
`./build.sh` then rebuilds the `.deb`s and the rootfs (use `-rd` to force a
rebuild without a version bump).

To test a change on a running board without reflashing:
`scp build/debs/<pkg>.deb board:/tmp/ && ssh board sudo dpkg -i /tmp/<pkg>.deb`.

## Rules worth knowing

- **Don't set `U_BOOT_FDT_OVERLAYS` in a `u-boot.default`.** `postinst`
  merges every key on each upgrade, which would wipe camera overlays that
  `apply-overlays.sh` enabled. Camera selection belongs in
  `/etc/rk3588-camera/overlays.conf`; `apply-overlays.sh` replaces managed
  camera/ISP entries and keeps unrelated overlays.
- **`U_BOOT_FDT` for Ubuntu's own DTBs is `device-tree/rockchip/<board>.dtb`**,
  relative to `/lib/firmware/<kernel version>/`, so each kernel boots its
  own DTB. A DTB shipped by the board package (Orange Pi 5 / 5B) uses an
  absolute path under `/usr/lib/rk3588-board-*/dtbs/`.
- **Don't ship files another package owns** (e.g. `/etc/flash-kernel/db`).
  dpkg refuses to unpack the package, and the image then won't boot.
  `build-rootfs.sh` now fails loudly if the board package doesn't install.

## Regenerating camera sources

`rk3588-camera-dkms/src/` and `rk3588-camera-overlays/dts/` (including
`rk3588-isp.dtso`) are generated from `patches/kernel/mainline/` and committed;
edit the patches, not the generated files. After changing the patch series:

```bash
./scripts/extract-oot-from-patches.sh
```

Kernel API differences for the stock kernel go in patch **0007**
(`rkisp2-v4l2-compat.h`), feature-tested rather than version-tested, so the
same source builds for the 7.2-based mainline tree and Ubuntu's 7.3.
