#!/bin/sh
# DKMS POST_INSTALL. $1 is the kernel version just installed.
# The previous imx708.ko can still be inside the initrd, and that copy is
# what the next boot loads. Rebuild that kernel's initrd from the modules
# just installed. If this kernel is running and imx708 is already loaded,
# reload it so the new driver probes without a reboot.
set -u

kver=${1:-}
if [ -z "$kver" ]; then
    echo "rk3588-camera: refresh-initramfs called without a kernel version" >&2
    exit 0
fi

if [ ! -e "/lib/modules/$kver/updates/dkms/imx708.ko" ] && \
   [ ! -e "/lib/modules/$kver/updates/dkms/imx708.ko.zst" ] && \
   [ ! -e "/lib/modules/$kver/updates/dkms/imx708.ko.xz" ]; then
    echo "rk3588-camera: no imx708 module installed for $kver" >&2
    exit 0
fi

# DKMS runs POST_INSTALL before its own depmod, so modules.dep does not list
# the module yet; dracut and modprobe would both miss it.
depmod -a "$kver" || true

if command -v dracut >/dev/null 2>&1; then
    dracut -f --kver "$kver" || true
elif command -v update-initramfs >/dev/null 2>&1; then
    update-initramfs -u -k "$kver" || true
else
    echo "rk3588-camera: no dracut or update-initramfs; initrd left unchanged" >&2
fi

# Skip the image-build chroot, where uname is the build host.
if [ "$(uname -r)" != "$kver" ] || [ ! -d /sys/module/imx708 ]; then
    exit 0
fi

modprobe -r imx708 || true
modprobe imx708 || true
