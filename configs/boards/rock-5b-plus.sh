# shellcheck shell=bash

export BOARD_NAME="Rock 5B+"
export BOARD_MAKER="Radxa"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="rock5b-rk3588_defconfig"
export U_BOOT_FDT="rockchip/rk3588-rock-5b-plus.dtb"
export U_BOOT_FDT_MAINLINE="rockchip/rk3588-rock-5b-plus.dtb"
export U_BOOT_FDT_OVERLAYS=""
export COMPATIBLE_SUITES=("questing" "resolute")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__rock-5b-plus() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

    if [[ "${KERNEL_TYPE:-vendor}" == "vendor" ]]; then
        echo "[+] Copying Rockchip firmware"
        cp -r "${overlay}/firmware/" "${mount_point}/lib/"

        echo "[+] Enabling Radxa A8 Bluetooth service"
        mkdir -p "${mount_point}/usr/lib/scripts"
        cp "${overlay}/usr/lib/systemd/system/radxa-a8-bluetooth.service" \
           "${mount_point}/usr/lib/systemd/system/radxa-a8-bluetooth.service"
        chroot "${mount_point}" systemctl enable radxa-a8-bluetooth

        echo "[+] Regenerating initramfs..."
        chroot "${mount_point}" update-initramfs -u -k all
    fi

    return 0
}
