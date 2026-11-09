# shellcheck shell=bash

export BOARD_NAME="ROCK 5B"
export BOARD_MAKER="Radxa"
export BOARD_SOC="Rockchip RK3588"
export BOARD_CPU="ARM Cortex A76 / A55"
export UBOOT_PACKAGE="u-boot"
export UBOOT_RULES_TARGET="rock5b-rk3588_defconfig"
export U_BOOT_FDT="rockchip/rk3588-rock-5b.dtb"
export U_BOOT_FDT_MAINLINE="rockchip/rk3588-rock-5b.dtb"
export U_BOOT_FDT_OVERLAYS=""
export COMPATIBLE_SUITES=("questing" "resolute" "stonking")
export COMPATIBLE_FLAVORS=("server" "desktop")

function build_image_hook__rock-5b() {
    local overlay="$1"
    local mount_point="$2"
    local suite="$3"
    local root_id="$4"

    if [[ "${KERNEL_TYPE:-stock}" == "stock" ]]; then
        echo "[+] Stock ISO path: flash-kernel comes from rk3588-board-rock-5b"
        return 0
    fi

    # flash-kernel's bundled database doesn't have this board (see
    # orangepi-5b.sh for the full explanation); without a matching "Machine:"
    # entry, apt upgrades touching the kernel package fail on-device.
    echo "[+] Registering board with flash-kernel"
    mkdir -p "${mount_point}/etc/flash-kernel"
    cat > "${mount_point}/etc/flash-kernel/db" <<'EOF'
Machine: Radxa ROCK 5B
Method: generic
EOF

    return 0
}
