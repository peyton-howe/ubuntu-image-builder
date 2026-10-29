# Camera bring-up status, 2026-10-28

Handoff for whoever continues the RK3588 camera work. Everything below was
verified on one ROCK 5B+ with an Arducam IMX415 (B0569, Raspberry Pi style, 24
MHz oscillator, 4 lanes) on CAM0, unless it says otherwise.

## Where things stand

All of this is merged to `main` (PRs #10 to #14, plus the IMX415 native size
selection target pushed straight to `main`).

- **IMX415 4K60** (1440 Mbps per lane, one ISP) works.
- **IMX415 4K90** (2376 Mbps per lane, both ISPs: "unite") works at
  3864x2192, about 94 fps, with auto exposure, auto white balance, correct
  colours and no seam, green bar or tearing.
- Asking for any other size in unite mode fails cleanly at configure time
  (`cam` exits non-zero; no hang).
- The 24 MHz / 2376 Mbps row is **outside Sony's data sheet** and opt-in
  (`allow_24mhz_2376=1`). A documented 27, 37.125 or 74.25 MHz oscillator
  board has not been tried.
- A 4K live preview in a GNOME/Wayland window tops out near 42 fps. That is the
  compositor, not the camera: GNOME imports each camera dmabuf into the GPU and
  composites it into a single XR30 plane (no direct scanout of the UYVY buffer),
  and 1080p keeps up with a 60 Hz display. `cam` without a display delivers
  93.8 fps from the same stream. Unite cannot scale, so for a live view use a
  smaller stream on the single-ISP overlay.

## What landed, by PR

| PR | What it adds |
|---|---|
| #10 | IMX415 overlay, `addr=` overlay parameter |
| #11 | 2376 Mbps lane rate, opt-in 24 MHz row, `clock-frequency=`, DKMS imx415, patch 0011, **exposure-range fix** |
| #12 | rkisp2 unite (both ISP cores), `unite` overlay parameter |
| #13 | pads processed output lines to 64 bytes; unsupported unite sizes fail at configure time |
| #14 | Orange Pi 5B WiFi/BT/eMMC moved into its own kernel patch (0010) |
| (direct) | IMX415 reports `NATIVE_SIZE` (patch 0012) |

## What the main changes fix

**imx415 exposure range (#11).** The 2376 row defaults VBLANK to 151, above
the control minimum (58). When libcamera lowers VBLANK (to 143) the driver
shrank the exposure range but passed the old default (2335) as the new
default, above the new maximum. `__v4l2_ctrl_modify_range()` returns -ERANGE
for that (`check_range()` in v4l2-ctrls-core.c) and the driver ignored it, so
the maximum stayed stale and `SHR0 = VMAX - exposure` reached 0 (minimum 8).
Images came out about 50x too dark. Mainline does not hit it because its
default VBLANK is the minimum. Fix: keep the default inside the new range,
clamp to `VMAX - IMX415_EXPOSURE_OFFSET` when writing SHR0, and use the new
VMAX when VBLANK itself changes. Patch 0011 is regenerated against v7.3-rc4.

**unite (#12).** Design copied from Rockchip's vendor driver
(`armbian/linux-rockchip`, branch `rk-6.1-rkr5.1`,
`drivers/media/platform/rockchip/isp/`). In the vendor driver userspace (rkaiq)
gives each core its own parameters; here the IPA gives one set, so the kernel
splits them.

- Each core takes part of the frame plus 128 overlap columns
  (`RKMOUDLE_UNITE_EXTEND_PIXEL`). The cut is half the width rounded up to 16
  pixels (`rkisp2_unite_split()`: 1936 for 3864), because the right core's
  output must start on a 16 byte boundary. Cutting at exactly half left the
  last 4 pixels of each row unwritten (all-zero YUV, a green bar).
- Per-core widths for ISP acquisition/output/IS, the raw read (rawrd), the MI
  write width, the dual crop (left keeps the first `cut` columns, right skips
  128). The right core reads from `cut - 128` pixels in and writes from `cut`.
- Interrupts and status come from the right core; the left core's flags are
  cleared separately. A frame is handled only when **both** cores have flagged
  its end (ISP block and MI). Acting on the right core alone let the left half
  land in another buffer (tearing at the cut when things move).
- AE, histogram and AWB windows are split (half-width cells, right window +128,
  weight grids remapped) and the stats of both cores are put back together
  (means averaged, histogram bins and AWB counts added).
- **Scaling the output and horizontal cropping are not supported in unite
  mode**, by decision: unite exists for streams that do not fit on one core, at
  the sensor's size. A per-core scale factor was tried (each core scaling its own
  part of the line) and did not work: 1080p showed many artifacts and 2560x1440
  and 3840x2160 gave no frames at all, so it was removed again. The driver rejects
  such sizes at configure time. Use the single-ISP
  overlay for scaled streams.

**stride padding (#13).** The processed output's line length was
`width * bpp` (7728 bytes for 3864 UYVY). Mesa's Vulkan WSI refused to present a
buffer whose pitch is not 64-byte aligned (`MESA: error: WSI pitch not properly
aligned`, one per frame). The IMX708's sizes happen to be aligned, which is why
it never showed. Lines are now padded to 64 bytes (7744). The unite right-buffer
offsets use the visible width, not the stride.

## What else the board needs

libcamera needs an IMX415 tuning file in its rkisp2 IPA data
(`/usr/share/libcamera/ipa/rkisp2/imx415.yaml`: Crop, ColorSpaceConversion, Agc,
Awb, BlackLevelSubtraction, GammaOutCorrection). Without one it falls back to
`uncalibrated.yaml`, which only subtracts the black level: no AGC, AWB or stats.
It is not part of this repo.

## Board setup for 4K90

```
# /etc/rk3588-camera/overlays.conf
RK3588_CAMERA_OVERLAYS="imx415,port0,addr=0x37,link-frequency=1188000000,unite"
# /etc/modprobe.d/imx415.conf
options imx415 allow_24mhz_2376=1
```
Then `sudo /usr/lib/rk3588-camera/apply-overlays.sh`, `sudo update-initramfs -u`,
reboot. 4K60: `imx415,port0,addr=0x37` (no unite, default 720 MHz link).
`apply-overlays.sh` keeps literal entries in `/etc/default/u-boot` that it does
not manage (a stale imx708 overlay once shadowed the sensor address). The
initrd must be rebuilt for modprobe options to apply.

## Verified numbers

- `cam -c1 -s role=viewfinder,width=3864,height=2192 --capture=300`: 93.8 fps,
  no gaps (use no `--file`: writing 16 MB frames drops it to about 23 fps).
- Image (unite, 3864x2192): mean luma 94, R/G 1.03, B/G 0.97, luma step at the cut equal
  to neighbouring columns, 0 rows with a torn seam, last column never zero.
- 4K60 raw (720 MHz link) and 4K90 raw both show about 43 counts above black at
  11 ms and gain 0 in the same scene. The 2376 mode is not less sensitive.
- Libcamera pipeline rule: each request spends about 33 ms in the pipeline, so
  at 90 fps **at least 3 requests must be in flight**. With the default pool of
  4, a client holding 2 buffers gets 60 fps, one holding 3 gets 30. The pool
  maximum is 8 (`kRkISP2IpaFrameContexts / 2`, `rkisp2.cpp:633`).

## Things that cost time, so you do not repeat them

- Black frames were **not** a kernel bug: libcamera had no IMX415 tuning file, so
  it fell back to `uncalibrated.yaml` (black level only: no AGC, AWB or stats; the
  params buffers held one block, then nothing).
- "The room is dark" was the exposure bug above. Compare raw counts at a fixed
  exposure *time* across modes, and read the sensor controls with
  `v4l2-ctl --list-ctrls` after libcamera has changed VBLANK.
- rkcif counts only real buffers in `sequence`: frames lost to a slow consumer
  are not visible as gaps. Compare the delivered rate to the sensor rate.
- Packed raw (`pGAA`) from rkcif at 3864 wide is not in V4L2's byte order and
  the line starts are misaligned in a period-4 pattern. Use unpacked `GB10`
  for image analysis (value in bits 9:0 of a 16-bit word).
- `apply-overlays.sh` once dropped `--addr` and `--clock-frequency` in its unite
  branch after a conflict merge. The test now reads the generated dtbo.
- Scaling in unite mode does not work, with one factor mirrored to both cores
  or with per-core factors: 1080p has artifacts, 2560x1440 and 3840x2160 produce
  no frames. Not pursued (see above).

## Open

1. A start/stop stress test of unite has not been run.
2. Soak and temperature test of the 24 MHz / 2376 row; documented-oscillator
   test of the 2376 row.
3. The rare rkcif hang (one in about 430 starts) is unexplained.
4. Whether to keep the custom mainline kernel path. The rkisp2 patch (0002) has
   drifted from the DKMS sources; the DKMS sources are the maintained copy, and
   patches 0011/0012 are kept in sync with the DKMS imx415 driver by hand.
