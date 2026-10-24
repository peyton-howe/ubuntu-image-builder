/* SPDX-License-Identifier: GPL-2.0-only */
/*
 * Minimal subset of phy/phy.h used by the DCPHY CSI overlays.
 * PHY_DIRECTION_TX and PHY_DIRECTION_RX come from the DCPHY RX v5 series
 * (kernel patch 0001); the rk3588-camera-dkms DCPHY module must use the
 * same values.
 */
#ifndef _DT_BINDINGS_PHY
#define _DT_BINDINGS_PHY
#define PHY_TYPE_DPHY 10
#define PHY_DIRECTION_TX 0
#define PHY_DIRECTION_RX 1
#endif
