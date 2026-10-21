/* SPDX-License-Identifier: GPL-2.0+ */
/*
 * Patch 0001 adds the second phy-cell values to dt-bindings/phy/phy.h.
 * Kernels without the series lack them; the values must match the
 * overlays that select the DCPHY receiver.
 */
#ifndef DCPHY_COMPAT_H
#define DCPHY_COMPAT_H

#include <dt-bindings/phy/phy.h>

#ifndef PHY_DIRECTION_TX
#define PHY_DIRECTION_TX	0
#endif
#ifndef PHY_DIRECTION_RX
#define PHY_DIRECTION_RX	1
#endif

#endif
