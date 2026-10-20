# rkcif (replacement module)

`drivers/media/platform/rockchip/rkcif/` from Linux v7.3, which is also
what Ubuntu's 7.3.0-9 kernel builds (`linux-source-7.3.0` 7.3.0-9.9, same
files). Only the `Makefile` differs: it builds the module out of tree
instead of keying off `CONFIG_VIDEO_ROCKCHIP_CIF`, and the upstream
`Kconfig` is left out.

DKMS installs it under `updates/dkms`. Ubuntu's depmod searches `updates`
before `kernel`, so it replaces the stock `rockchip-cif` without a
blacklist.
