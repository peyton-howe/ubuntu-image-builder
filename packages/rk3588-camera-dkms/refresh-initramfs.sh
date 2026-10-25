#!/bin/sh
# DKMS POST_INSTALL. $1 is the kernel version just installed.
# The initrd can still hold the stock copy of a module this package replaces
# (the Samsung DCPHY is the one that matters: the stock module is
# transmitter-only and rejects the receiver's second phy cell), and the
# initrd copy is what the next boot loads. Rebuild that kernel's initrd from
# the modules just installed.
set -u

warn() {
    echo "rk3588-camera: WARNING: $*" >&2
}

kver=${1:-}
if [ -z "$kver" ]; then
    echo "rk3588-camera: refresh-initramfs called without a kernel version" >&2
    exit 0
fi

ours=0
for m in imx708 phy-rockchip-samsung-dcphy rockchip-cif rockchip-isp2; do
    for ext in ko ko.zst ko.xz; do
        [ -e "/lib/modules/$kver/updates/dkms/$m.$ext" ] && ours=1
    done
done
if [ "$ours" -eq 0 ]; then
    echo "rk3588-camera: no module installed for $kver" >&2
    exit 0
fi

# DKMS runs POST_INSTALL before its own depmod, so modules.dep does not list
# the modules yet; dracut and modprobe would both miss them.
depmod -a "$kver" || warn "depmod -a $kver failed; modules.dep may not list the DKMS modules"

# A failure here is reported but does not fail the DKMS install: that would
# leave dpkg and apt with a half-configured package on a kernel upgrade, or
# in an image-build chroot where the initrd tool cannot run. The warning says
# how to finish the job by hand.
if command -v dracut >/dev/null 2>&1; then
    dracut -f --kver "$kver" ||
        warn "dracut failed for $kver; the initrd may still hold the stock DCPHY module and CSI cameras will not work until you run: dracut -f --kver $kver"
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$kver" ||
        warn "update-initramfs failed for $kver; the initrd may still hold the stock DCPHY module and CSI cameras will not work until you run: update-initramfs -u -k $kver"
else
    warn "no dracut or update-initramfs; initrd left unchanged"
fi
