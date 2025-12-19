# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5B"
export BOARD_MAKER="Xulong"
export BOARD_SOC="Rockchip RK3588S"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="orangepi-5-rk3588s_defconfig"
export U_BOOT_FDT="device-tree/rockchip/rk3588s-orangepi-5b.dtb"
export COMPATIBLE_SUITES=("questing" "resolute")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__orangepi-5b() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

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

    return 0
}