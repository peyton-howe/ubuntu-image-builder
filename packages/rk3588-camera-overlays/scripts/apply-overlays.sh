#!/usr/bin/env bash
# Sync /etc/rk3588-camera/overlays.conf into /etc/default/u-boot.
#
# overlays.conf is the full list of camera overlays. Entries already in
# U_BOOT_FDT_OVERLAYS that come from this package are replaced; other
# overlays (board GPU, etc.) are kept.
#
# A sensor is selected the way the Raspberry Pi does it:
#   imx708,port0
#   imx708,port1,isp1,link-frequency=447000000
#   imx415,port0,link-frequency=1188000000,clock-frequency=37125000
#   imx415,port0,addr=0x37
# The matching per-board port overlay is added automatically. Explicit
# ISP requests are reserved first; other cameras take the first
# free ISP in list order. Parameters are baked into a dtbo under
# /var/lib/rk3588-camera because U-Boot does not apply overlay parameters.
set -euo pipefail

CONF=${RK3588_CAMERA_CONF:-/etc/rk3588-camera/overlays.conf}
UBOOT_DEFAULT=${RK3588_U_BOOT_DEFAULT:-/etc/default/u-boot}
OVERLAY_DIR=${RK3588_CAMERA_OVERLAY_DIR:-/usr/share/rk3588-camera/overlays}
GEN_DIR=${RK3588_CAMERA_GEN_DIR:-/var/lib/rk3588-camera}
RESOLVER=${RK3588_CAMERA_RESOLVER:-/usr/lib/rk3588-camera/resolve-overlay.py}
BOARD_SHARE=${RK3588_BOARD_SHARE:-/usr/share}

if [[ ! -f ${CONF} ]]; then
    echo "No ${CONF}; nothing to apply"
    exit 0
fi

# shellcheck disable=SC1090
source "${CONF}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

is_uint() {
    [[ ${1:-} =~ ^[0-9]+$ ]]
}

board_prefix() {
    case "${1}" in
        orangepi-5|orangepi-5b) echo rk3588s-orangepi-5 ;;
        rock-5b-plus) echo rk3588-rock-5b-plus ;;
        *) return 1 ;;
    esac
}

detect_board() {
    if [[ -n ${RK3588_CAMERA_BOARD:-} ]]; then
        echo "${RK3588_CAMERA_BOARD}"
        return 0
    fi
    local d base
    # 5B before 5: both directories can exist only by mistake, and the
    # shorter name must not win by glob order.
    for base in rk3588-board-orangepi-5b rk3588-board-orangepi-5 rk3588-board-rock-5b-plus; do
        d="${BOARD_SHARE}/${base}"
        [[ -d ${d} ]] || continue
        case "${base}" in
            rk3588-board-orangepi-5b) echo orangepi-5b; return 0 ;;
            rk3588-board-orangepi-5) echo orangepi-5; return 0 ;;
            rk3588-board-rock-5b-plus) echo rock-5b-plus; return 0 ;;
        esac
    done
    if [[ -r /proc/device-tree/model ]]; then
        local model
        model="$(tr -d '\0' < /proc/device-tree/model)"
        case "${model}" in
            *"Orange Pi 5B"*) echo orangepi-5b; return 0 ;;
            *"Orange Pi 5"*) echo orangepi-5; return 0 ;;
            *"ROCK 5B+"*) echo rock-5b-plus; return 0 ;;
        esac
    fi
    return 1
}

# spec is sensor,param,param... with no spaces (Pi dtoverlay syntax).
# On success, sets SPEC_SENSOR SPEC_PORT SPEC_FOUR SPEC_LINK SPEC_CLK
# SPEC_ADDR SPEC_ROT SPEC_ORI SPEC_ISP.
parse_spec() {
    local spec="$1"
    local -a parts
    local tok key val addr
    IFS=',' read -ra parts <<< "${spec}"
    [[ ${#parts[@]} -ge 1 && -n ${parts[0]} ]] || die "empty overlay spec"
    SPEC_SENSOR="${parts[0]}"
    SPEC_PORT=""
    SPEC_ISP=""
    SPEC_FOUR=0
    SPEC_LINK=""
    SPEC_CLK=""
    SPEC_ADDR=""
    SPEC_ROT=""
    SPEC_ORI=""
    [[ ${SPEC_SENSOR} =~ ^[A-Za-z0-9][A-Za-z0-9_+-]*$ ]] \
        || die "bad sensor name '${SPEC_SENSOR}' in '${spec}'"
    local i
    for ((i = 1; i < ${#parts[@]}; i++)); do
        tok="${parts[i]}"
        [[ -n ${tok} ]] || die "empty parameter in '${spec}'"
        if [[ ${tok} == *=* ]]; then
            key="${tok%%=*}"
            val="${tok#*=}"
        else
            key="${tok}"
            val=""
        fi
        case "${key}" in
            port[0-9]|port[0-9][0-9])
                [[ -z ${val} || ${val} == on || ${val} == 1 ]] \
                    || die "${key}=${val} is not valid in '${spec}' (port selects a connector)"
                [[ -z ${SPEC_PORT} ]] || die "more than one port in '${spec}'"
                SPEC_PORT="${key#port}"
                ;;
            4lane)
                if [[ -z ${val} || ${val} == on || ${val} == 1 ]]; then
                    SPEC_FOUR=1
                elif [[ ${val} == off || ${val} == 0 ]]; then
                    SPEC_FOUR=0
                else
                    die "bad 4lane value '${val}' in '${spec}'"
                fi
                ;;
            link-frequency)
                is_uint "${val}" || die "link-frequency must be Hz, got '${val}'"
                SPEC_LINK="${val}"
                ;;
            addr)
                [[ ${val} =~ ^(0[xX][0-9a-fA-F]+|[0-9]+)$ ]] \
                    || die "addr must be an I2C address such as 0x37, got '${val}'"
                addr="${val}"
                if is_uint "${val}"; then
                    addr="$((10#${val}))"
                fi
                (( addr >= 3 && addr <= 119 )) \
                    || die "addr must be a 7-bit I2C address (0x03 to 0x77), got '${val}'"
                SPEC_ADDR="$(printf '0x%x' "$((addr))")"
                ;;
            clock-frequency)
                is_uint "${val}" || die "clock-frequency must be Hz, got '${val}'"
                SPEC_CLK="${val}"
                ;;
            rotation)
                is_uint "${val}" || die "rotation must be a number of degrees, got '${val}'"
                SPEC_ROT="${val}"
                ;;
            orientation)
                is_uint "${val}" || die "orientation must be a number, got '${val}'"
                SPEC_ORI="${val}"
                ;;
            isp0|isp1)
                [[ -z ${val} || ${val} == on || ${val} == 1 ]] \
                    || die "${key}=${val} is not valid in '${spec}'"
                [[ -z ${SPEC_ISP} ]] || die "more than one isp in '${spec}'"
                SPEC_ISP="${key#isp}"
                ;;
            isp)
                is_uint "${val}" || die "isp must be 0 or 1, got '${val}'"
                [[ -z ${SPEC_ISP} ]] || die "more than one isp in '${spec}'"
                SPEC_ISP="${val}"
                ;;
            *)
                die "unknown parameter '${key}' in '${spec}'"
                ;;
        esac
    done
    [[ -n ${SPEC_PORT} ]] || die "'${spec}' needs a port, for example ${SPEC_SENSOR},port0"
}

managed_path() {
    local item="$1" base
    base="$(basename "${item}")"
    base="${base%.dtbo}.dtbo"
    [[ -f ${OVERLAY_DIR}/${base} ]] && return 0
    case "${item}" in
        "${GEN_DIR}"/*) return 0 ;;
    esac
    case "${base}" in
        rk3588-rock-5b-plus-imx708-cam[01].dtbo|\
        rk3588-rock-5b-plus-imx708-cam[01]-isp.dtbo|\
        rk3588s-orangepi-5-cam[123]-imx708.dtbo) return 0 ;;
    esac
    return 1
}

declare -a literals=()
declare -a sensors=()
declare -a sensor_ports=()
declare -a sensor_isp_req=()
declare -a sensor_four=()
declare -a sensor_link=()
declare -a sensor_clk=()
declare -a sensor_addr=()
declare -a sensor_rot=()
declare -a sensor_ori=()
declare -a sensor_args=()
declare -a sensor_tags=()
declare -a sensor_isps=()

board=""
need_board=0

for name in ${RK3588_CAMERA_OVERLAYS:-}; do
    name="${name%.dtbo}"
    if [[ ${name} == *,* ]]; then
        parse_spec "${name}"
        src="${OVERLAY_DIR}/${SPEC_SENSOR}.dtbo"
        if [[ ! -f ${src} ]]; then
            die "no sensor overlay ${src}"
        fi
        need_board=1
        sensors+=("${SPEC_SENSOR}")
        sensor_ports+=("${SPEC_PORT}")
        sensor_isp_req+=("${SPEC_ISP}")
        sensor_four+=("${SPEC_FOUR}")
        sensor_link+=("${SPEC_LINK}")
        sensor_clk+=("${SPEC_CLK}")
        sensor_addr+=("${SPEC_ADDR}")
        sensor_rot+=("${SPEC_ROT}")
        sensor_ori+=("${SPEC_ORI}")
    else
        [[ ${name} =~ ^[A-Za-z0-9][A-Za-z0-9_+-]*$ ]] \
            || die "bad overlay name '${name}'"
        f="${OVERLAY_DIR}/${name}.dtbo"
        if [[ ! -f ${f} ]]; then
            echo "WARNING: missing overlay ${f}" >&2
            case "${name}" in
                *imx708*|*imx219*|*imx519*|*imx415*)
                    echo "Sensor overlays take a port parameter, for example imx708,port0 (see ${CONF})." >&2
                    ;;
            esac
            continue
        fi
        literals+=("${f}")
    fi
done

for ((i = 0; i < ${#sensor_ports[@]}; i++)); do
    for ((j = i + 1; j < ${#sensor_ports[@]}; j++)); do
        if [[ ${sensor_ports[i]} == "${sensor_ports[j]}" ]]; then
            die "port${sensor_ports[i]} is listed more than once"
        fi
    done
done

# Reserve explicit ISP requests before assigning free ISPs in list order.
# Two cameras cannot share one.

used_isp=" "
for isp in "${sensor_isp_req[@]}"; do
    [[ -n ${isp} ]] || continue
    [[ ${isp} == 0 || ${isp} == 1 ]] || die "isp${isp} is not available (use isp0 or isp1)"
    [[ ${used_isp} != *" ${isp} "* ]] || die "isp${isp} is assigned to more than one camera"
    used_isp+=" ${isp} "
done

for ((i = 0; i < ${#sensors[@]}; i++)); do
    tag="${sensors[i]}-port${sensor_ports[i]}"
    [[ ${sensor_four[i]} -eq 1 ]] && tag+="-4lane"
    [[ -n ${sensor_link[i]} ]] && tag+="-link-${sensor_link[i]}"
    [[ -n ${sensor_clk[i]} ]] && tag+="-clk-${sensor_clk[i]}"
    [[ -n ${sensor_addr[i]} ]] && tag+="-addr-${sensor_addr[i]}"
    [[ -n ${sensor_rot[i]} ]] && tag+="-rot-${sensor_rot[i]}"
    [[ -n ${sensor_ori[i]} ]] && tag+="-ori-${sensor_ori[i]}"
    isp="${sensor_isp_req[i]}"
    if [[ -z ${isp} ]]; then
        if [[ ${used_isp} != *" 0 "* ]]; then
            isp=0
        elif [[ ${used_isp} != *" 1 "* ]]; then
            isp=1
        else
            die "only isp0 and isp1 exist; ${sensors[i]},port${sensor_ports[i]} needs an explicit isp that is still free"
        fi
        used_isp+=" ${isp} "
    fi
    sensor_isps+=("${isp}")
    tag+="-isp${isp}"
    sensor_tags+=("${tag}")
    args=(--port "${sensor_ports[i]}" --isp "${isp}")
    [[ ${sensor_four[i]} -eq 1 ]] && args+=(--four-lane)
    [[ -n ${sensor_link[i]} ]] && args+=(--link-frequency "${sensor_link[i]}")
    [[ -n ${sensor_clk[i]} ]] && args+=(--clock-frequency "${sensor_clk[i]}")
    [[ -n ${sensor_addr[i]} ]] && args+=(--addr "${sensor_addr[i]}")
    [[ -n ${sensor_rot[i]} ]] && args+=(--rotation "${sensor_rot[i]}")
    [[ -n ${sensor_ori[i]} ]] && args+=(--orientation "${sensor_ori[i]}")
    sensor_args+=("${args[*]}")
done

if [[ ${need_board} -eq 1 ]]; then
    board="$(detect_board)" || die "could not tell which board this is. Set RK3588_CAMERA_BOARD in ${CONF} to orangepi-5, orangepi-5b, or rock-5b-plus."
    prefix="$(board_prefix "${board}")" || die "unknown RK3588_CAMERA_BOARD '${board}'"
fi

if [[ -n ${RK3588_CAMERA_OVERLAYS:-} && ${#literals[@]} -eq 0 && ${#sensors[@]} -eq 0 ]]; then
    echo "No valid overlays to enable" >&2
    exit 1
fi

# Validate port overlays before replacing anything already enabled.
declare -a port_files=()
declare -a port_seen=()
if [[ ${need_board} -eq 1 ]]; then
    for ((i = 0; i < ${#sensors[@]}; i++)); do
        p="${sensor_ports[i]}"
        already=0
        for seen in "${port_seen[@]:-}"; do
            [[ -z ${seen} ]] && continue
            if [[ ${seen} == "${p}" ]]; then
                already=1
                break
            fi
        done
        port_file="${OVERLAY_DIR}/${prefix}-port${p}.dtbo"
        if [[ ! -f ${port_file} ]]; then
            die "${board} has no port${p} (${port_file} is not installed). Orange Pi 5/5B connectors are port1, port2, and port3. ROCK 5B+ connectors are port0 and port1."
        fi
        if [[ ${already} -eq 0 ]]; then
            port_seen+=("${p}")
            port_files+=("${port_file}")
        fi
    done
fi

case "${GEN_DIR}" in
    */rk3588-camera|*/rk3588-camera/*) ;;
    *) die "refusing to clear unexpected GEN_DIR ${GEN_DIR}" ;;
esac

# Resolve into a staging directory so a failure leaves the previous dtbos
# and U_BOOT_FDT_OVERLAYS alone.
stage="$(mktemp -d "${TMPDIR:-/tmp}/rk3588-camera.XXXXXX")"
cleanup_stage() { rm -rf "${stage}"; }
trap cleanup_stage EXIT

declare -a resolved=()
if [[ ${#sensors[@]} -gt 0 ]]; then
    command -v python3 >/dev/null || die "python3 is required to apply sensor parameters"
    [[ -f ${RESOLVER} ]] || die "missing ${RESOLVER}"
    for ((i = 0; i < ${#sensors[@]}; i++)); do
        # shellcheck disable=SC2206
        args=(${sensor_args[i]})
        dst="${stage}/${sensor_tags[i]}.dtbo"
        python3 "${RESOLVER}" "${OVERLAY_DIR}/${sensors[i]}.dtbo" "${dst}" "${args[@]}"
        resolved+=("${GEN_DIR}/${sensor_tags[i]}.dtbo")
    done
fi
mkdir -p "$(dirname "${GEN_DIR}")"
rm -rf "${GEN_DIR}"
mv "${stage}" "${GEN_DIR}"
trap - EXIT

mkdir -p "$(dirname "${UBOOT_DEFAULT}")"
touch "${UBOOT_DEFAULT}"

existing=""
if grep -q '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}"; then
    existing="$(grep '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}" | tail -n1 \
        | sed 's/^U_BOOT_FDT_OVERLAYS=//; s/^"//; s/"$//')"
fi

kept=()
for item in ${existing}; do
    [[ -z ${item} ]] && continue
    if managed_path "${item}"; then
        continue
    fi
    kept+=("${item}")
done

# Unrelated overlays stay in front. Then isp (stock DTBs have no isp
# labels), the port overlays (they publish cam_portN_*), and the sensors.
merged=()
for item in "${kept[@]:-}"; do
    [[ -z ${item} ]] && continue
    merged+=("${item}")
done
camera_selected=0
[[ ${#literals[@]} -gt 0 || ${#resolved[@]} -gt 0 ]] && camera_selected=1
if [[ ${camera_selected} -eq 1 ]]; then
    isp="${OVERLAY_DIR}/rk3588-isp.dtbo"
    [[ -f ${isp} ]] && merged+=("${isp}")
fi
for item in "${port_files[@]:-}" "${resolved[@]:-}" "${literals[@]:-}"; do
    [[ -z ${item} ]] && continue
    skip=0
    for m in "${merged[@]:-}"; do
        [[ -z ${m} ]] && continue
        if [[ ${m} == "${item}" ]]; then
            skip=1
            break
        fi
    done
    [[ ${skip} -eq 1 ]] && continue
    merged+=("${item}")
done

overlay_line="U_BOOT_FDT_OVERLAYS=\"${merged[*]}\""

if grep -q '^U_BOOT_FDT_OVERLAYS=' "${UBOOT_DEFAULT}"; then
    sed -i "s|^U_BOOT_FDT_OVERLAYS=.*|${overlay_line}|" "${UBOOT_DEFAULT}"
else
    printf '\n# Managed by rk3588-camera-overlays\n%s\n' "${overlay_line}" \
        >> "${UBOOT_DEFAULT}"
fi

if command -v u-boot-update >/dev/null; then
    u-boot-update
fi

if [[ ${camera_selected} -eq 0 ]]; then
    echo "Camera overlays cleared; U_BOOT_FDT_OVERLAYS=${merged[*]:-<empty>}"
else
    echo "Enabled overlays: ${merged[*]}"
fi
