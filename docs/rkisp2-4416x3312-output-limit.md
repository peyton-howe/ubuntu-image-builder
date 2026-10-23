# rkisp2: the 4416x3312 limit on processed (ISP) streams

**Status: not fixed.** Observed on a ROCK 5B+ with an IMX708, stock Ubuntu
7.3.0-9 kernel, `rk3588-camera-dkms` 0.1.11, libcamera `rkisp2-upstream`.

## Symptom

A processed stream (`viewfinder` role, UYVY and so on) cannot use the
IMX708's full-resolution mode (4608x2592), so any processed output above
2304x1296 is refused. Raw streams are not affected.

```
$ cam -c1 -s role=viewfinder,width=3840,height=2160 --capture=10
Camera configuration invalid
Failed to create camera session
```

With `LIBCAMERA_LOG_LEVELS="CameraSensor:DEBUG"` the cause is visible:

```
'imx708': No supported format or size found
```

`cam -I` lists the processed formats as `(32x32)-(4416x3312)`. Processed
streams work at 2304x1296, 1536x864 and 1280x720 (the binned and 720p modes).
4608x2592 and 3840x2160 are rejected.

## Where the number comes from

4416x3312 is the maximum output of the ISP main-path resizer on the older
`rkisp1` ISP (RK3288, RK3399). It was copied into the rkisp2 code and is
not an RK3588 limit. It appears in two places we control:

| Where | What | Effect |
|---|---|---|
| kernel, [rkisp2-common.h](../packages/rk3588-camera-dkms/src/rkisp2/rkisp2-common.h) | `RKISP2_RSZ_MP_SRC_MAX_WIDTH/HEIGHT` = 4416 / 3312 | caps the main-path capture node's output size |
| libcamera, `src/libcamera/pipeline/rkisp2/rkisp2.cpp:47` | `ispMaxSize = Size(4416, 3312)` | caps the output size **and** is passed as the maximum when choosing a sensor mode, so the 4608-wide mode is never selected for a processed stream |

The ISP's input limit in the same kernel driver is correct:
`rk3588_isp_info.max_width/max_height` in `rkisp2-dev.c` is 4672 x 3504.

Rockchip's vendor driver (`armbian/linux-rockchip`, branch `rk-6.1-rkr5.1`)
has the same 4416x3312 as a default (`isp/capture.h`,
`STREAM_MAX_MP_RSZ_OUTPUT_*`). For ISP3.0 (RK3588) it then overrides the
main-path limit in `rkisp_register_stream_vdevs()` with
`CIF_ISP_INPUT_W/H_MAX_V30` = 4672 x 3504 (`isp/rkisp.h`), or the larger
"unite" values when both ISPs are used. So on RK3588 the vendor main path
outputs up to 4672x3504 with a single ISP; unite mode has larger limits.

## What it blocks

Any processed output that needs the 4608x2592 sensor mode, which for the
IMX708 means every size above 2304x1296. Full resolution is only usable as
raw.

## Possible fixes

1. **libcamera only.** Use the ISP *input* limit (4672x3504) as the maximum
   when choosing the sensor mode, and keep 4416x3312 as the output cap. That
   allows processed outputs up to 4416 wide (for example 3840x2160) from the
   full-resolution mode. Changes stay inside the rkisp2 pipeline handler.
2. **Kernel as well.** Raise `RKISP2_RSZ_MP_SRC_MAX_WIDTH/HEIGHT` to
   4672x3504 for RK3588, as the vendor driver does, and raise libcamera's
   output cap to match. That allows a full 4608x2592 processed output.

Fix 1 is enough for 3840x2160. Only fix 2 gives processed 4608x2592.

## Not verified

- That the ISP can take the 4608x2592 mode as input and scale it down on
  hardware. The kernel and vendor constants say it should; nobody has run it.
- Throughput. A single ISP is quoted at about 16 MP at 30 fps (4672x3504).
  4608x2592 at the 45 fps the sensor can deliver at 4-lane 750 MHz is
  about 12 MP x 45, slightly above that, so processed full resolution may
  be limited by the ISP rather than by the link.

## Reproducing

```sh
cam -c1 -I | grep -E "^[0-9]+:|\(32x32\)"            # shows the (32x32)-(4416x3312) range
cam -c1 -s role=viewfinder,width=2304,height=1296 --capture=30   # works
cam -c1 -s role=viewfinder,width=3840,height=2160 --capture=30   # Camera configuration invalid
cam -c1 -s role=raw,width=4608,height=2592 --capture=30          # works (raw bypasses the ISP)
```
