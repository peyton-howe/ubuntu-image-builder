#!/usr/bin/env bash
set -eE
trap 'echo "Error in $0 on line $LINENO"' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")"
# shellcheck source=/dev/null
source scripts/common.sh

usage() {
cat << HEREDOC
Usage: $0 --board=[orangepi-5|rock-5b-plus] --release=[questing|resolute|stonking] --flavor=[server|desktop]

Required arguments:
  -b, --board=BOARD           target board
  -r, --release=RELEASE       ubuntu release
  -f, --flavor=FLAVOR         ubuntu flavor

Optional arguments:
  -h,  --help                 show this help message and exit
  -c,  --clean                clean the entire build directory
  -rk, --rebuild-kernel       rebuild custom kernel from source (vendor/mainline; forces rootfs + image rebuild)
  -rd, --rebuild-debs         rebuild board/camera .debs (forces rootfs + image rebuild)
  -ru, --rebuild-uboot        rebuild u-boot (also forces image rebuild)
  -rr, --rebuild-rootfs       rebuild rootfs (also forces image rebuild)
  -kt, --kernel-type=TYPE     kernel type: stock (default), vendor, or mainline
                              stock = official ISO kernel + our .debs
                              vendor/mainline = build and install a custom linux-image
  -ko, --kernel-only          only compile the kernel (vendor/mainline)
  -do, --debs-only            only build board/camera .debs into build/debs/
  -uo, --uboot-only           only compile uboot
  -ro, --rootfs-only          only extract Ubuntu's official aarch64 ISO into a rootfs
       --compress             xz-compress the output image (default)
       --no-compress          leave the output image uncompressed
  -v,  --verbose              increase the verbosity of the bash script
HEREDOC
}

for _arg in "$@"; do
    case "${_arg}" in
        -h|--help)
            usage
            exit 0
            ;;
    esac
done

reexec_as_userns_root "$@"

cd "$(dirname -- "$(readlink -f -- "$0")")"

while [ "$#" -gt 0 ]; do
    case "${1}" in
        -h|--help)
            usage
            exit 0
            ;;
        -b=*|--board=*)
            export BOARD="${1#*=}"
            shift
            ;;
        -b|--board)
            export BOARD="${2}"
            shift 2
            ;;
        -r=*|--release=*)
            export RELEASE="${1#*=}"
            shift
            ;;
        -r|--release)
            export RELEASE="${2}"
            shift 2
            ;;
        -f=*|--flavor=*)
            export FLAVOR="${1#*=}"
            shift
            ;;
        -f|--flavor)
            export FLAVOR="${2}"
            shift 2
            ;;
        -kt=*|--kernel-type=*)
            export KERNEL_TYPE="${1#*=}"
            shift
            ;;
        -kt|--kernel-type)
            export KERNEL_TYPE="${2}"
            shift 2
            ;;
        -ko|--kernel-only)
            export KERNEL_ONLY=Y
            shift
            ;;
        -do|--debs-only)
            export DEBS_ONLY=Y
            shift
            ;;
        -uo|--uboot-only)
            export UBOOT_ONLY=Y
            shift
            ;;
        -ro|--rootfs-only)
            export ROOTFS_ONLY=Y
            shift
            ;;
        -c|--clean)
            export CLEAN=Y
            shift
            ;;
        -rk|--rebuild-kernel)
            export REBUILD_KERNEL=Y
            shift
            ;;
        -rd|--rebuild-debs)
            export REBUILD_DEBS=Y
            shift
            ;;
        -ru|--rebuild-uboot)
            export REBUILD_UBOOT=Y
            shift
            ;;
        -rr|--rebuild-rootfs)
            export REBUILD_ROOTFS=Y
            shift
            ;;
        --compress)
            export COMPRESS=Y
            shift
            ;;
        --compress=*)
            case "${1#*=}" in
                Y|y|yes|true|1) export COMPRESS=Y ;;
                N|n|no|false|0) export COMPRESS=N ;;
                *)
                    echo "Error: --compress expects true or false"
                    exit 1
                    ;;
            esac
            shift
            ;;
        --no-compress)
            export COMPRESS=N
            shift
            ;;
        -v|--verbose)
            set -x
            shift
            ;;
        -*)
            echo "Error: unknown argument \"${1}\""
            exit 1
            ;;
        *)
            shift
            ;;
    esac
done

export COMPRESS="${COMPRESS:-Y}"
export KERNEL_TYPE="${KERNEL_TYPE:-stock}"

case "${KERNEL_TYPE}" in
    stock|vendor|mainline) ;;
    *)
        echo "Error: unsupported --kernel-type=${KERNEL_TYPE} (use stock, vendor, or mainline)"
        exit 1
        ;;
esac

if [ "${RELEASE}" == "help" ]; then
    for file in configs/releases/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${RELEASE}" ]; then
    while :; do
        for file in configs/releases/*; do
            if [ "${RELEASE}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${RELEASE}\" is an unsupported Ubuntu release"
        exit 1
    done
fi

if [ "${FLAVOR}" == "help" ]; then
    for file in configs/flavors/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${FLAVOR}" ]; then
    while :; do
        for file in configs/flavors/*; do
            if [ "${FLAVOR}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${FLAVOR}\" is an unsupported flavor"
        exit 1
    done
fi

if [ "${BOARD}" == "help" ]; then
    for file in configs/boards/*; do
        basename "${file%.sh}"
    done
    exit 0
fi

if [ -n "${BOARD}" ]; then
    while :; do
        for file in configs/boards/*; do
            if [ "${BOARD}" == "$(basename "${file%.sh}")" ]; then
                # shellcheck source=/dev/null
                source "${file}"
                break 2
            fi
        done
        echo "Error: \"${BOARD}\" is an unsupported board"
        exit 1
    done
fi

unmount_rootfs() {
    if [ -d build ]; then
        BUILD_ABS="$(readlink -f build)"
        for mnt_dir in build/rootfs/*/sys build/rootfs/*/dev build/rootfs/*/proc build/rootfs/*/run; do
            [ -d "${mnt_dir}" ] && umount -R -lf "${mnt_dir}" 2>/dev/null || true
        done
        while read -r _ mnt _; do
            case "${mnt}" in
                "${BUILD_ABS}/rootfs/"*) umount -lf "${mnt}" 2>/dev/null || true ;;
            esac
        done < <(awk '{print $1, $2, $3}' /proc/mounts | sort -rk2)
    fi
}

if [ "${CLEAN}" == "Y" ]; then
    if [ -d build ]; then
        BUILD_ABS="$(readlink -f build)"

        unmount_rootfs

        # Catch anything else under build/ by reading /proc/mounts deepest-first
        while read -r _ mnt _; do
            case "${mnt}" in
                "${BUILD_ABS}/"*) umount -lf "${mnt}" 2>/dev/null || true ;;
            esac
        done < <(awk '{print $1, $2, $3}' /proc/mounts | sort -rk2)

        # Detach loop devices pointing at image files inside build/
        losetup --list --output NAME,BACK-FILE --noheadings \
            | awk -v p="${BUILD_ABS}" '$2 ~ p {print $1}' \
            | while read -r loop; do
                losetup -d "${loop}" 2>/dev/null || true
              done
    fi
    rm -rf build
fi

if [ "${REBUILD_UBOOT}" == "Y" ]; then
    echo "[+] Clearing u-boot build artifacts..."
    rm -f build/u-boot/u-boot-rockchip.bin 2>/dev/null || true
    rm -f images/*.img images/*.img.xz 2>/dev/null || true
fi

if [ "${REBUILD_KERNEL}" == "Y" ]; then
    echo "[+] Clearing kernel debs (keeping source tree)..."
    find build/kernel -maxdepth 1 -name "*.deb" -delete 2>/dev/null || true
    rm -rf build/kernel/linux-mainline-build build/kernel/linux-vendor-build 2>/dev/null || true
    # Cascade: rootfs and image must also rebuild
    REBUILD_ROOTFS=Y
fi

if [ "${REBUILD_DEBS}" == "Y" ]; then
    echo "[+] Clearing board/camera debs..."
    rm -rf build/debs
    REBUILD_ROOTFS=Y
fi

if [ "${REBUILD_ROOTFS}" == "Y" ]; then
    echo "[+] Clearing rootfs..."
    unmount_rootfs
    rm -rf build/rootfs
    # Cascade: image must also rebuild
    rm -f images/*.img images/*.img.xz 2>/dev/null || true
fi

mkdir -p build/logs
logfile="build/logs/build-$(date +"%Y%m%d%H%M%S").log"
exec > >(tee "$logfile") 2>&1

echo "[+] Kernel type: ${KERNEL_TYPE}"

if [ "${KERNEL_ONLY}" == "Y" ]; then
    if is_stock_kernel; then
        echo "Error: --kernel-only requires --kernel-type=vendor or mainline"
        exit 1
    fi
    ./scripts/build-kernel.sh
    exit 0
fi

if [ "${DEBS_ONLY}" == "Y" ]; then
    ./scripts/build-debs.sh
    exit 0
fi

if [ "${ROOTFS_ONLY}" == "Y" ]; then
    if [ -z "${RELEASE}" ] || [ -z "${FLAVOR}" ]; then
        usage
        exit 1
    fi
    if is_stock_kernel; then
        ./scripts/build-debs.sh
    fi
    ./scripts/build-rootfs.sh
    exit 0
fi

if [ "${UBOOT_ONLY}" == "Y" ]; then
    if [ -z "${BOARD}" ]; then
        usage
        exit 1
    fi
    ./scripts/build-u-boot.sh
    exit 0
fi

# No board param passed
if [ -z "${BOARD}" ] || [ -z "${RELEASE}" ] || [ -z "${FLAVOR}" ]; then
    usage
    exit 1
fi

if is_stock_kernel; then
    # Board/camera packages for the stock ISO path
    need_debs=0
    if ! compgen -G "build/debs/rk3588-camera-overlays_*.deb" > /dev/null; then
        need_debs=1
    elif ! compgen -G "build/debs/rk3588-camera-dkms_*.deb" > /dev/null; then
        need_debs=1
    else
        board_pkg="$(board_support_package "${BOARD}")"
        if [[ -n ${board_pkg} ]] && ! compgen -G "build/debs/${board_pkg}_*.deb" > /dev/null; then
            need_debs=1
        fi
    fi
    if [[ ${need_debs} -eq 1 ]]; then
        ./scripts/build-debs.sh
    fi
else
    # Build the custom Linux kernel if not found
    if [[ ! -e "$(find build/kernel/linux-image-*.deb 2>/dev/null | sort | tail -n1)" || ! -e "$(find build/kernel/linux-headers-*.deb 2>/dev/null | sort | tail -n1)" ]]; then
        ./scripts/build-kernel.sh
    fi
fi

# Build U-Boot if not found
if [[ ! -e "$(find build/u-boot/u-boot-rockchip.bin 2>/dev/null | sort | tail -n1)" ]]; then
    ./scripts/build-u-boot.sh
fi

# Create the root filesystem
if [[ ! -e "$(find build/rootfs/ubuntu-${RELEASE}-preinstalled-${FLAVOR}-arm64.tar.gz 2>/dev/null | sort | tail -n1)" ]]; then
    ./scripts/build-rootfs.sh
fi

# Create the disk image
./scripts/build-image.sh

exit 0