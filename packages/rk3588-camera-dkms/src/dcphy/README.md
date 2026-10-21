# Samsung DCPHY CSI-RX (replacement module)

The RK3588 has two MIPI DCPHYs (`mipidcphy0`, `mipidcphy1`). This module adds
CSI reception to them for any board; it is not specific to one board. Which
camera ports use it is decided by the board's overlays.

`phy-rockchip-samsung-dcphy.c` is the patched driver from kernel patch `0001`
(DCPHY RX v5), copied from a patched mainline tree by
`scripts/extract-oot-from-patches.sh`. Don't edit it here.

DKMS installs it under `updates/dkms`. Ubuntu's depmod searches `updates`
before `kernel`, so it replaces the stock module of the same name without a
blacklist. The stock module only has the DSI transmitter.

`dcphy-compat.h` is force-included by the `Makefile`. It supplies the
`PHY_DIRECTION_TX` (0) and `PHY_DIRECTION_RX` (1) second phy-cell values,
which patch `0001` adds to `dt-bindings/phy/phy.h` but stock headers lack. The
Orange Pi 5 port2/port3 overlays in `rk3588-camera-overlays` use the same
values; change both together.

The binding is not settled upstream. In the v5 review (Rob Herring, Heiko
Stuebner, Michael Riesch) the two-cell form was called an ABI break, and the
direction discussed for the next version is one cell
(`PHY_DIRECTION_TX`/`PHY_DIRECTION_RX`) plus the standard `phy-type`
property to pick D-PHY or C-PHY. Expect to update the driver, this header and
the overlays together when that lands.
