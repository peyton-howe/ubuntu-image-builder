# rkcif (replacement module)

`drivers/media/platform/rockchip/rkcif/` from Linux v7.3, which is also
what Ubuntu's 7.3.0-9 kernel builds (`linux-source-7.3.0` 7.3.0-9.9, same
files), with these changes:

- The `Makefile` builds the module out of tree instead of keying off
  `CONFIG_VIDEO_ROCKCHIP_CIF`, and the upstream `Kconfig` is left out.
- A stream stops in a different order: the capture at a frame end, then
  the source, then the buffers are freed, and the interrupt handler uses a
  spinlock instead of the subdev state mutex.
- Where `mipi_soft_reset` is set in the match data (RK3588) the CRU reset in
  runtime suspend is skipped, and the MIPI host's capture logic is reset with
  a register soft reset when a stream stops.

[docs/rk3588-camera-streaming-hangs.md](../../../../docs/rk3588-camera-streaming-hangs.md)
has the reasons.

DKMS installs it under `updates/dkms`. Ubuntu's depmod searches `updates`
before `kernel`, so it replaces the stock `rockchip-cif` without a
blacklist.
