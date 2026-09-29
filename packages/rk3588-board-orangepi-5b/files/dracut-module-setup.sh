#!/bin/bash
# Force Rockchip MMC (and heartbeat LED) into the initramfs on Ubuntu 25.10+
# (dracut). hostonly builds on a foreign build host would otherwise omit them.

check() {
	return 0
}

depends() {
	return 0
}

installkernel() {
	hostonly='' instmods \
		dw_mmc dw_mmc_pltfm dw_mmc_rockchip \
		sdhci-of-dwcmshc mmc_block ledtrig-heartbeat
}
