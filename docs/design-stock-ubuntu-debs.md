# Design: Stock Ubuntu ISO + U-Boot + `.deb` packages

**Status:** proposal (branch `stock-iso-packages`)  
**Goal:** Download Ubuntu’s official server/desktop arm64 ISO, use that rootfs as-is (including Ubuntu’s kernel), write our U-Boot to the image, and install our board/camera `.deb` packages. No full custom kernel in the default path.

---

## Working plan (locked in)

1. **Rootfs** = extract from official Ubuntu `server` / `desktop` arm64 ISO  
   (`scripts/build-rootfs.sh` already does this via `UBUNTU_*_ISO_URL` in `configs/releases/*.sh`).
2. **Keep** the kernel that came with that ISO (do not `dpkg -i` `linux-image-*-mainline-rk3588`).
3. **Image** = GPT + root partition from that rootfs; **dd** our U-Boot (`idbloader` + `u-boot.itb`/`u-boot.img`) at the usual Rockchip seeks.
4. **Packages** installed into the rootfs (chroot or first boot):
   - board support (firmware, services, flash-kernel, `u-boot-menu`)
   - camera overlays (`.dtbo`)
   - camera drivers (DKMS: imx708, rkisp2, DCPHY replacement as needed)

Custom `KERNEL_TYPE=mainline` `bindeb-pkg` stays available as a developer escape hatch, not the default on this branch.

---

## Short answer

**Yes for board overlays, firmware, boot config, and most camera drivers — with DKMS.**  
**No for “just a .deb of our current kernel patches as-is” without restructuring.** Several patches edit in-tree files (Samsung DCPHY, tiny V4L2 fourccs, SoC DT). Those need to be turned into out-of-tree modules / overlay DTBs / a replacement PHY module before they track Ubuntu’s kernel.

---

## What we ship today (relevant surface)

From `patches/kernel/mainline/series` (applied in `scripts/build-kernel.sh` when `KERNEL_TYPE=mainline`):

| Patch | Nature | Deb-friendly? |
|-------|--------|----------------|
| `0001` Samsung DCPHY CSI RX | Modifies in-tree `phy-rockchip-samsung-dcphy.c` (~500 LOC) | Hard — needs replacement-module DKMS or wait for Ubuntu |
| `0002` rkisp2 | Mostly new `drivers/media/platform/rockchip/rkisp2/` + SoC DT nodes; also tiny fourcc hooks in `videodev2.h` / `v4l2-ioctl.c` | Yes as out-of-tree DKMS if fourccs live in a local header |
| `0007` rkisp2 V4L2 ISP compat | Local to rkisp2 | Bundled with rkisp2 DKMS |
| `0004` IMX708 | New `imx708.c` only | Ideal DKMS |
| `0005` DCPHY CSI hosts + OPi5 PHY enable | SoC / board DT | Prefer overlays or ship board `.dtb` |
| `0006` IMX708 camera overlays | New `.dtso` → `.dtbo` | Ideal plain `.deb` |
| `0003` shared media graph | Disabled in series | Skip for now |

Board glue already lives outside the kernel (`configs/boards/*.sh`, `overlay/`): firmware, bluetooth services, flash-kernel db, `u-boot-menu` / `extlinux` FDT + overlays. That is the other half of the packaging work.

---

## Builder flow (this repo)

```text
Ubuntu arm64 ISO  ──build-rootfs.sh──►  rootfs tarball (stock kernel)
                                              │
U-Boot build  ──────────────────────────────┐ │
Our .debs (board / overlays / DKMS) ────────┼─┤
                                            ▼ ▼
                                    build-image.sh
                                            │
                                            ▼
                         board .img  (GPT rootfs + U-Boot in raw sectors)
```

Changes vs current `mainline` default:

| Step | Today | This branch |
|------|--------|-------------|
| `build-kernel.sh` | Required; installs custom kernel debs into rootfs | Optional / off by default |
| `build-rootfs.sh` | ISO extract **plus** `dpkg -i` custom kernel | ISO extract; install **our** packages instead |
| `build-u-boot.sh` | Required | Required (unchanged) |
| `build-image.sh` | Partition, hooks, `u-boot-update`, dd U-Boot | Same, pointed at stock FDT paths |

### On-device / chroot package install

```bash
apt install rk3588-board-orangepi-5 \
            rk3588-camera-overlays \
            rk3588-camera-dkms
```

On every later `linux-image-*` upgrade, DKMS rebuilds the camera modules against the new headers. Overlays and board files stay put.

---

## Package split

### 1. `rk3588-board-<board>` (arch: all or arm64)

Plain data + scripts package. No kernel build.

Contents (lift from `configs/boards/<board>.sh` + `overlay/`):

- `/lib/firmware/...` board Wi‑Fi/BT blobs (AP6275P, etc.)
- systemd units (`ap6275p-bluetooth`, `enable-usb2`, growpart, media-group fixups)
- `/etc/flash-kernel/db` Machine entry (stops apt kernel upgrades failing)
- `/etc/default/u-boot` fragments or a drop-in that sets:
  - `U_BOOT_FDT=.../rk3588s-orangepi-5.dtb` (or ROCK 5B+ equivalent)
  - `U_BOOT_FDT_OVERLAYS=...` (panthor, camera, …)
- `postinst`: `systemctl enable …`, `u-boot-update`

One binary package per board (`orangepi-5`, `orangepi-5b`, `rock-5b-plus`), or one package with board-detect — per-board is clearer.

### 2. `rk3588-camera-overlays` (arch: all)

Build `.dtbo` from the `.dtso` in patch `0006` (and any enablement overlays extracted from `0005`) **against the DT bindings of the target Ubuntu kernel**, then install to a stable path, e.g.:

- `/usr/share/rk3588-camera/overlays/*.dtbo`
- Symlink or copy into the path `u-boot-menu` / extlinux expects  
  (today: under `/lib/firmware/<kver>/device-tree/...` or next to the board `.dtb`)

`postinst` / `u-boot-update` hook: append selected overlays to `U_BOOT_FDT_OVERLAYS` (or write `extlinux.conf` `fdtoverlays` lines). Keep camera selection configurable (`/etc/rk3588-camera/overlays.conf`: `cam1-imx708`, etc.).

**Important:** overlays that only fragment *existing* nodes work on stock DT. Nodes that **do not exist** in Ubuntu’s `rk3588-base.dtsi` (ISP, CSI hosts from `0002`/`0005`) need either:

- overlays that **add** those nodes (preferred), or  
- a shipped board `.dtb` built from mainline+patches (fallback package `rk3588-dtbs`).

Prefer additive overlays so we stay on Ubuntu’s FDT.

### 3. `rk3588-camera-dkms` (arch: all, builds on device)

Out-of-tree sources under `/usr/src/rk3588-camera-<ver>/` with `dkms.conf`.

| Module | Source strategy |
|--------|-----------------|
| `imx708` | Lift `imx708.c` + Kbuild from `0004` unchanged |
| `rockchip-isp2` (or whatever `VIDEO_ROCKCHIP_ISP2` builds) | Lift `rkisp2/` from `0002`+`0007`; define `V4L2_META_FMT_RKISP2_*` in a local header instead of patching `videodev2.h`; skip the two `v4l_fill_fmtdesc` lines or copy a tiny shim |
| `phy-rockchip-samsung-dcphy` | **Replacement module**: vendor a full copy of the patched `.c` from `0001`, DKMS-build it, install to `updates/`, and blacklist or `softdep` so it overrides Ubuntu’s in-tree module |

`dkms.conf` sketch:

```text
PACKAGE_NAME="rk3588-camera"
PACKAGE_VERSION="0.1"
AUTOINSTALL="yes"
BUILT_MODULE_NAME[0]="imx708"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="rkisp2"          # actual .ko name from Makefile
DEST_MODULE_LOCATION[1]="/updates/dkms"
BUILT_MODULE_NAME[2]="phy-rockchip-samsung-dcphy"
DEST_MODULE_LOCATION[2]="/updates/dkms"
```

Depends: `dkms`, `linux-headers-generic` (or the headers package matching the running image).

**Rebuild story:** Ubuntu ships a new kernel → `linux-image` postinst triggers DKMS → modules appear under `/lib/modules/$(uname -r)/updates/`. No full kernel compile in our CI for end users.

### 4. `rk3588-uboot-<board>` (optional)

Ships `idbloader.img` + `u-boot.itb` under `/usr/lib/u-boot/<board>/` plus `/usr/sbin/rk3588-install-uboot` that `dd`s to the correct seeks. Flashing U-Boot is still a **disk** operation; a `.deb` can hold the bits and the tool, but cannot safely auto-flash in `postinst` on every upgrade.

---

## What this deliberately does *not* do

- Replace Ubuntu’s `vmlinuz` / initramfs with our `linux-image-*-mainline-rk3588`.
- Require `bindeb-pkg` of the whole tree for camera bring-up.
- Carry patch `0003` (shared media graph) until libcamera needs it.

If Ubuntu’s kernel is missing Kconfig pieces we currently force on (`CONFIG_VIDEO_ROCKCHIP_CIF`, media controller, etc.), DKMS modules that *depend* on those symbols will fail to build or load. Then we either:

- document a minimum Ubuntu kernel / enablement package, or  
- fall back to a thin custom kernel meta-package only for those boards until Ubuntu catches up.

First milestone should **probe a real stock image**: `zcat /proc/config.gz` / `/boot/config-$(uname -r)` for the Rockchip media / PHY / V4L2 symbols and whether `rk3588s-orangepi-5.dtb` already has the CSI/ISP nodes we need.

---

## Repo layout (scaffolded on `stock-iso-packages`)

```text
packages/
  README.md
  rk3588-camera-dkms/          # debian/ + src/{imx708,rkisp2,dcphy}
  rk3588-camera-overlays/      # debian/ + dts/*.dtso + apply-overlays.sh
  rk3588-board-orangepi-5/     # flash-kernel, u-boot fragment, AP6275P fw
  rk3588-board-orangepi-5b/
  rk3588-board-rock-5b-plus/
scripts/
  build-debs.sh                # dpkg-buildpackage → build/debs/
  extract-oot-from-patches.sh  # refresh oot trees from patches/kernel/mainline
```

`rk3588-uboot-*` not scaffolded yet (U-Boot remains via `build-u-boot.sh` + raw `dd`).

Keep `patches/kernel/mainline/` as the source of truth for upstreaming; the DKMS tree is a **packaging extract**, refreshed with `extract-oot-from-patches.sh`.

Next: wire `build-rootfs.sh` / `build-image.sh` to install these `.deb`s into the stock ISO rootfs instead of `linux-image-*-mainline-rk3588*.deb`.

---

## Risks and mitigations

| Risk | Mitigation |
|------|------------|
| DCPHY replacement diverges from Ubuntu’s in-tree driver | Rebase `0001` onto each Ubuntu ABI; CI builds DKMS against current `-generic` / board kernel headers |
| Ubuntu DT lacks ISP / CSI host nodes | Ship additive overlays that create the nodes; verify on hardware |
| Secure Boot / module signing | Disable SB on these SBCs, or sign DKMS modules with a MOK enrolled at first boot |
| DKMS build fails after kernel update | `dkms status` in a smoke test; pin or provide a fallback meta-package |
| fourcc / uAPI mismatch with libcamera | Keep local uAPI header identical to lore series; version the DKMS package with the libcamera IPA |

---

## Phased plan

1. **Inventory stock Ubuntu kernel** on target board image (config + DT nodes + loaded modules).
2. **Package overlays + board support** first — zero DKMS risk; validates U-Boot + FDT path on stock kernel.
3. **DKMS IMX708 only** — prove camera sensor path with CIF/bypass if ISP not ready.
4. **Extract rkisp2 out-of-tree** with local fourccs; DKMS + ISP overlays.
5. **DCPHY replacement module** last; needed for CAM2/CAM3 (DCPHY CSI RX) on Orange Pi 5.
6. **Switch image builder** to stock kernel + these debs; keep full mainline `bindeb-pkg` as a `KERNEL_TYPE=mainline` escape hatch until steps 4–5 are solid.

---

## Success criteria

- Stock Ubuntu kernel remains the running `uname -r` after install.
- `apt upgrade` of `linux-image-*` leaves camera modules loading (DKMS rebuild succeeds).
- IMX708 on at least one CSI port works with the same overlay names we use today.
- Board Wi‑Fi/BT and flash-kernel registration behave as in current `build_image_hook__*`.
- Full custom kernel build is optional for development / upstreaming only.

---

## Open questions

1. Which exact “stock” image? Ubuntu’s official Rockchip preinstalled images vs generic arm64 + our partition layout.
2. Do we need CAM2/CAM3 (DCPHY) in v1, or is CAM1 (Inno CSI) enough to land packages first?
3. Private apt repo vs shipping `.deb` files next to images in `build/debs/`?
4. Keep building mainline kernel in CI as a reference, or only DKMS + overlay packages?
