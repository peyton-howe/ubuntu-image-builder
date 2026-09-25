# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5"
export BOARD_MAKER="Xunlong"
export BOARD_SOC="Rockchip RK3588S"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="orangepi-5-rk3588s_defconfig"
export U_BOOT_FDT="device-tree/rockchip/rk3588s-orangepi-5.dtb"
export U_BOOT_FDT_MAINLINE="rockchip/rk3588s-orangepi-5.dtb"
export U_BOOT_FDT_OVERLAYS="rockchip-rk3588-panthor-gpu.dtbo"
export COMPATIBLE_SUITES=("questing" "resolute" "stonking")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__orangepi-5() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

    # flash-kernel's bundled database doesn't have this board either (see
    # orangepi-5b.sh for the full explanation); without a matching "Machine:"
    # entry, apt upgrades touching the kernel package fail on-device.
    echo "[+] Registering board with flash-kernel"
    mkdir -p "${mount_point}/etc/flash-kernel"
    cat > "${mount_point}/etc/flash-kernel/db" <<'EOF'
Machine: Xunlong Orange Pi 5
Method: generic
EOF

    if [[ "${KERNEL_TYPE:-vendor}" == "vendor" ]]; then
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
    fi

    return 0
}