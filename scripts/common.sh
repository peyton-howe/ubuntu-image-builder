# shellcheck shell=bash

reexec_as_userns_root() {
    if [ "$(id -u)" -eq 0 ]; then
        return 0
    fi
    if [ "${BUILDSH_USERNS:-}" = 1 ]; then
        echo "Error: still not uid 0 after unshare."
        echo "Enable unprivileged user namespaces, or run with sudo."
        exit 1
    fi
    if ! command -v unshare >/dev/null; then
        echo "Error: unshare not found (util-linux). Install it or run with sudo."
        exit 1
    fi
    echo "[+] Re-executing in a user namespace (no sudo)..."
    export BUILDSH_USERNS=1
    # --pid --mount-proc: inherited host /proc is locked to init_user_ns and
    # cannot be bind-mounted into the chroot ("bad superblock on /proc").
    exec unshare --map-root-user --mount --pid --fork --mount-proc -- \
        "$(readlink -f -- "$0")" "$@"
}

# User-ns CAP_SYS_ADMIN cannot mount on a host-owned superblock (e.g. /home).
# Bind the tree onto itself first so stacked mounts (proc/sys/dev) are allowed.
prepare_chroot_mounts() {
    local root="$1"
    mkdir -p "${root}/proc" "${root}/sys" "${root}/dev" "${root}/run"

    __chroot_self_bind=""
    if ! findmnt -n "${root}" >/dev/null 2>&1; then
        mount --bind "${root}" "${root}"
        mount --make-private "${root}" 2>/dev/null || true
        __chroot_self_bind="${root}"
    fi

    if ! mountpoint -q "${root}/proc"; then
        if ! mount -t proc -o nosuid,noexec,nodev proc "${root}/proc" 2>/dev/null; then
            mount --rbind /proc "${root}/proc"
        fi
    fi
    if ! mountpoint -q "${root}/sys"; then
        mount --rbind /sys "${root}/sys"
        mount --make-rslave "${root}/sys" 2>/dev/null || true
    fi
    if ! mountpoint -q "${root}/dev"; then
        mount --rbind /dev "${root}/dev"
        mount --make-rslave "${root}/dev" 2>/dev/null || true
    fi
    if ! mountpoint -q "${root}/run"; then
        mount --rbind /run "${root}/run"
        mount --make-rslave "${root}/run" 2>/dev/null || true
    fi
}

teardown_chroot_mounts() {
    local root="$1"
    umount -lf "${root}/proc" 2>/dev/null || true
    umount -lf "${root}/sys" 2>/dev/null || true
    umount -lf "${root}/dev" 2>/dev/null || true
    umount -lf "${root}/run" 2>/dev/null || true
    if [ -n "${__chroot_self_bind:-}" ]; then
        umount -lf "${__chroot_self_bind}" 2>/dev/null || true
        __chroot_self_bind=""
    fi
}

require_cmds() {
    local missing=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Error: missing host commands: ${missing[*]}"
        echo "Install them once with apt, then re-run ./build.sh (no sudo needed for the build itself)."
        exit 1
    fi
}

# Map BOARD → rk3588-board-* package name (empty if unknown).
board_support_package() {
    case "${1:-}" in
        orangepi-5) echo "rk3588-board-orangepi-5" ;;
        orangepi-5b) echo "rk3588-board-orangepi-5b" ;;
        rock-5b-plus) echo "rk3588-board-rock-5b-plus" ;;
        orangepi-5-max) echo "rk3588-board-orangepi-5-max" ;;
        orangepi-5-plus) echo "rk3588-board-orangepi-5-plus" ;;
        orangepi-5-pro) echo "rk3588-board-orangepi-5-pro" ;;
        rock-5a) echo "rk3588-board-rock-5a" ;;
        rock-5b) echo "rk3588-board-rock-5b" ;;
        rock-5c) echo "rk3588-board-rock-5c" ;;
        rock-5-itx) echo "rk3588-board-rock-5-itx" ;;
        *) echo "" ;;
    esac
}

# Prebuilt .debs a board needs besides its board package, downloaded into
# build/debs/ by scripts/fetch-aic8800-debs.sh (empty if none).
board_fetched_debs() {
    case "${1:-}" in
        rock-5c) echo "aic8800-firmware aic8800-usb-dkms" ;;
        *) echo "" ;;
    esac
}

# True when we keep the ISO's kernel and install our board/camera debs.
is_stock_kernel() {
    [[ "${KERNEL_TYPE:-stock}" == "stock" ]]
}

# Repo root, whatever the caller's cwd (build-rootfs.sh runs in build/rootfs).
REPO_ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

# Version at the top of packages/$1/debian/changelog, e.g. 0.1.7-1.
package_version() {
    sed -n '1s/^[^ ]* (\([^)]*\)).*/\1/p' "${REPO_ROOT_DIR}/packages/$1/debian/changelog"
}

# Packages from packages/ that the stock-kernel rootfs installs for BOARD.
stock_packages() {
    echo rk3588-camera-overlays rk3588-camera-dkms
    board_support_package "${1:-${BOARD:-}}"
}

# True when build/debs has package $1 at its current changelog version, so a
# .deb left over from an older checkout is rebuilt instead of reused.
deb_is_current() {
    compgen -G "${REPO_ROOT_DIR}/build/debs/$1_$(package_version "$1")_*.deb" > /dev/null
}

# The rootfs directory is named <release>-<flavor>. A stamp of "board= ..."
# (nothing after the equals) is the shared stock rootfs: camera packages and
# apt, no board package. build-rootfs.sh can install one board into that tree.
# A stamp of "board=<name> ..." already has that board's package. Package
# versions are recorded so a changelog bump rebuilds a rootfs that has the
# old deb installed.
rootfs_stamp_id() {
    local id="board=${BOARD:-} kernel=${KERNEL_TYPE:-stock}" pkg
    if is_stock_kernel; then
        for pkg in $(stock_packages); do
            id+=" ${pkg}=$(package_version "${pkg}")"
        done
    fi
    echo "${id}"
}

# True when stamp file $1 is the shared stock rootfs for the current camera
# package versions. BOARD is ignored: a shared stamp has an empty board field.
rootfs_shared_is_current() {
    local stamp="${1:?}" current
    [[ -f ${stamp} ]] || return 1
    # Command substitution is a subshell, so clearing BOARD does not leak.
    current="$(BOARD=; rootfs_stamp_id)"
    [[ "$(cat "${stamp}")" == "${current}" ]]
}

# Archive of a shared rootfs, relative to build/rootfs/.
rootfs_tarball_name() {
    echo "ubuntu-${RELEASE:?}-preinstalled-${FLAVOR:?}-arm64.rootfs.tar.xz"
}

# True when stamp file $1 exists and matches the current BOARD/KERNEL_TYPE.
rootfs_is_current() {
    [[ -f $1 && "$(cat "$1")" == "$(rootfs_stamp_id)" ]]
}

# Per-board U-Boot binary. The shared u-boot/rkbin source trees stay under
# build/u-boot/; only the built blob is board-specific so switching boards
# does not reuse another board's image.
uboot_bin_path() {
    local board="${1:-${BOARD:?BOARD is required}}"
    echo "build/u-boot/${board}/u-boot-rockchip.bin"
}

# Ubuntu 25.10 (questing) and later default to dracut, which Conflicts with
# initramfs-tools. RELASE_VERSION comes from configs/releases/*.sh.
release_uses_dracut() {
    local ver="${1:-${RELASE_VERSION:-}}"
    [[ -n ${ver} ]] || return 1
    # True when ver >= 25.10 (sort -V, input already in order).
    printf '%s\n%s\n' "25.10" "${ver}" | sort -C -V
}
