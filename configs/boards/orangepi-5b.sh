# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5B"
export BOARD_MAKER="Xunlong"
export BOARD_SOC="Rockchip RK3588S"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="orangepi-5b-rk3588s_defconfig"
export U_BOOT_FDT="device-tree/rockchip/rk3588s-orangepi-5b.dtb"
export U_BOOT_FDT_MAINLINE="rockchip/rk3588s-orangepi-5b.dtb"
export U_BOOT_FDT_OVERLAYS="rockchip-rk3588-panthor-gpu.dtbo"
export COMPATIBLE_SUITES=("questing" "resolute" "stonking")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__orangepi-5b() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

    # flash-kernel's bundled database (usr/share/flash-kernel/db/all.db) only
    # has old Allwinner-based "Xunlong Orange Pi" boards, not this RK3588S
    # one. Without a matching "Machine:" entry, check_supported() in
    # /usr/share/flash-kernel/functions calls error() -> exit 1, which fails
    # the kernel package's postinst (and any apt upgrade touching it) on the
    # real board -- systemd-detect-virt skips this same check inside our
    # build chroot, which is why it only ever showed up on-device. We don't
    # actually rely on flash-kernel (u-boot-menu/extlinux.conf drives boot),
    # so "generic" is enough to make it complete successfully.
    echo "[+] Registering board with flash-kernel"
    mkdir -p "${mount_point}/etc/flash-kernel"
    cat > "${mount_point}/etc/flash-kernel/db" <<'EOF'
Machine: Xunlong Orange Pi 5B
Method: generic
EOF

    if [[ "${KERNEL_TYPE:-stock}" == "stock" ]]; then
        echo "[+] Stock ISO path: firmware/flash-kernel come from rk3588-board-orangepi-5b"
        return 0
    fi

    if [[ "${KERNEL_TYPE}" == "vendor" ]]; then
        # Enable bluetooth for AP6275P
        echo "[+] Enabling AP6275P"
        mkdir -p "${mount_point}/usr/lib/scripts"
        cp "${overlay}/usr/lib/systemd/system/ap6275p-bluetooth.service" "${mount_point}/usr/lib/systemd/system/ap6275p-bluetooth.service"
        cp "${overlay}/usr/lib/scripts/ap6275p-bluetooth.sh" "${mount_point}/usr/lib/scripts/ap6275p-bluetooth.sh"
        cp "${overlay}/usr/bin/brcm_patchram_plus" "${mount_point}/usr/bin/brcm_patchram_plus"
        chroot "${mount_point}" systemctl enable ap6275p-bluetooth

        # Enable USB 2.0 port
        echo "[+] Enabling USB-C and USB 2.0 ports"
        cp "${overlay}/usr/lib/systemd/system/enable-usb2.service" "${mount_point}/usr/lib/systemd/system/enable-usb2.service"
        chroot "${mount_point}" systemctl --no-reload enable enable-usb2

        # Copy firmware
        echo "[+] Enabling Rockchip Firmware"
        cp -r "${overlay}/firmware/" "${mount_point}/lib/"

        echo '[+] Regenerating initramfs...'
        chroot "${mount_point}" update-initramfs -u -k all
    elif [[ "${KERNEL_TYPE}" == "mainline" ]]; then
        # The vendor kernel's brcmfmac fork reads firmware/nvram out of
        # ap6275p/ under vendor-specific names (fw_bcm43752a2_pcie_ag.bin,
        # nvram_AP6275P.txt, ...). Upstream brcmfmac (what the mainline
        # kernel uses) doesn't know that convention at all -- it looks for
        # /lib/firmware/brcm/brcmfmac<chip>-<bus>.{bin,txt,clm_blob}. AP6275P's
        # WiFi half (BCM43752) is wired up over PCIe on this board (confirmed
        # from dmesg: it was requesting brcmfmac43752-pcie.bin, and the vendor
        # firmware's own filenames -- fw_bcm43752a2_pcie_ag.bin,
        # clm_bcm43752a2_pcie_ag.blob -- say "pcie" too), so use the matching
        # brcmfmac43752-pcie files, with this module's own calibrated nvram
        # (nvram_AP6275P.txt) in place of the generic reference one.
        echo "[+] Copying AP6275P WiFi firmware (brcmfmac43752-pcie)"
        mkdir -p "${mount_point}/lib/firmware/brcm"
        cp "${overlay}/firmware/brcm/brcmfmac43752-pcie.bin" "${mount_point}/lib/firmware/brcm/"
        cp "${overlay}/firmware/brcm/brcmfmac43752-pcie.clm_blob" "${mount_point}/lib/firmware/brcm/"
        cp "${overlay}/firmware/ap6275p/nvram_AP6275P.txt" "${mount_point}/lib/firmware/brcm/brcmfmac43752-pcie.txt"

        # Bluetooth already works on mainline without any of the vendor
        # ap6275p-bluetooth.sh machinery (confirmed on-device) -- the mainline
        # devicetree evidently wires it up via the standard hci_uart/btbcm
        # serdev path, so nothing more to do here.
        echo "[+] Copying AP6275P firmware"
        mkdir -p "${mount_point}/lib/firmware/ap6275p"
        cp -r "${overlay}/firmware/ap6275p/." "${mount_point}/lib/firmware/ap6275p/"

        echo '[+] Regenerating initramfs...'
        chroot "${mount_point}" update-initramfs -u -k all
    fi

    return 0
}