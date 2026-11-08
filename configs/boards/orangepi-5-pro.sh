# shellcheck shell=bash

export BOARD_NAME="Orange Pi 5 Pro"
export BOARD_MAKER="Xunlong"
export BOARD_SOC="Rockchip RK3588S"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="orangepi-5-pro-rk3588s_defconfig"
export U_BOOT_FDT="rockchip/rk3588s-orangepi-5-pro.dtb"
export U_BOOT_FDT_MAINLINE="rockchip/rk3588s-orangepi-5-pro.dtb"
export U_BOOT_FDT_OVERLAYS=""
export COMPATIBLE_SUITES=("questing" "resolute" "stonking")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__orangepi-5-pro() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

    if [[ "${KERNEL_TYPE:-stock}" == "stock" ]]; then
        echo "[+] Stock ISO path: flash-kernel comes from rk3588-board-orangepi-5-pro"
        return 0
    fi

    # flash-kernel's bundled database doesn't have this board (see
    # orangepi-5b.sh for the full explanation); without a matching "Machine:"
    # entry, apt upgrades touching the kernel package fail on-device.
    echo "[+] Registering board with flash-kernel"
    mkdir -p "${mount_point}/etc/flash-kernel"
    cat > "${mount_point}/etc/flash-kernel/db" <<'EOF'
Machine: Xunlong Orange Pi 5 Pro
Method: generic
EOF

    return 0
}
