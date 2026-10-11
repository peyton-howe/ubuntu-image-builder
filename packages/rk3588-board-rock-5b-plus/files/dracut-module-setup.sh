#!/bin/bash
# Force Rockchip MMC (and heartbeat LED) into the initramfs on Ubuntu 25.10+
# (dracut). hostonly builds on a foreign build host would otherwise omit them.

# Always return success so dracut includes this module on any build host.
check() {
	return 0
}

# Declare no dracut module dependencies: emit nothing and return success.
depends() {
	return 0
}

# Install Rockchip MMC and heartbeat LED drivers into the initramfs,
# disabling host-only filtering so foreign build hosts include them too.
installkernel() {
	hostonly='' instmods \
		dw_mmc dw_mmc_pltfm dw_mmc_rockchip \
		sdhci-of-dwcmshc mmc_block ledtrig-heartbeat
}
