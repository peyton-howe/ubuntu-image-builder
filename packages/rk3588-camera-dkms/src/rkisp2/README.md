# rkisp2 out-of-tree staging

Sources extracted from `0002-media-rockchip-rkisp2.patch` plus
`0007-media-rkisp2-v4l2-isp-compat.patch`.

Before enabling in `dkms.conf`:

1. Use `Makefile.oot` (or merge it into `Makefile`) so the module builds
   without in-tree `CONFIG_VIDEO_ROCKCHIP_ISP2`.
2. Ensure `V4L2_META_FMT_RKISP2_*` fourccs are available via the local
   `uapi/rkisp2-config.h` / compat header (do not patch Ubuntu’s `videodev2.h`).
3. Ship additive DT overlays that create ISP nodes if the stock board DT
   lacks them.
