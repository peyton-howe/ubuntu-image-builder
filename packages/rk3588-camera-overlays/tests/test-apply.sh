#!/usr/bin/env bash
# Compile the overlays, retarget a sensor onto a port, and apply the stack
# onto a stub board DTB. Requires gcc, dtc, and python3.
set -euo pipefail

cd "$(dirname -- "$(readlink -f -- "$0")")"
ROOT="$(cd ../../.. && pwd)"
PKG="${ROOT}/packages/rk3588-camera-overlays"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

compile_dtso() {
    local src="$1" dst="$2"
    gcc -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp -P \
        -I"${PKG}/include" "${src}" \
        | dtc -@ -I dts -O dtb -o "${dst}" -
}

dtc -@ -I dts -O dtb -o "${WORK}/stub.dtb" stub-base.dts
for src in "${PKG}/dts/"*.dtso; do
    base="$(basename "${src}" .dtso)"
    compile_dtso "${src}" "${WORK}/${base}.dtbo"
done

python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx708.dtbo" "${WORK}/imx708-port0.dtbo" \
    --port 0 --isp 0 --link-frequency 447000000 --rotation 180
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx708.dtbo" "${WORK}/imx708-port0-4lane.dtbo" \
    --port 0 --isp 0 --four-lane
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx219.dtbo" "${WORK}/imx219-port2.dtbo" --port 2 --isp 1
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx708.dtbo" "${WORK}/imx708-port1.dtbo" --port 1 --isp 0
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx708.dtbo" "${WORK}/imx708-port1-isp1.dtbo" --port 1 --isp 1
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx708.dtbo" "${WORK}/imx708-port3.dtbo" --port 3 --isp 0
python3 "${PKG}/scripts/resolve-overlay.py" \
    "${WORK}/imx519.dtbo" "${WORK}/imx519-port0.dtbo" --port 0 --isp 0

apply() {
    local out="$1"
    shift
    fdtoverlay -i "${WORK}/stub.dtb" -o "${out}" "$@"
}

apply "${WORK}/rock0.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port0.dtbo" \
    "${WORK}/imx708-port0.dtbo"
apply "${WORK}/rock-both.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port0.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port1.dtbo" \
    "${WORK}/imx708-port0.dtbo" \
    "${WORK}/imx708-port1-isp1.dtbo"
apply "${WORK}/rock-port1-first.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port1.dtbo" \
    "${WORK}/imx708-port1.dtbo"
apply "${WORK}/rock-4lane.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port0.dtbo" \
    "${WORK}/imx708-port0-4lane.dtbo"
apply "${WORK}/opi.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588s-orangepi-5-port1.dtbo" \
    "${WORK}/rk3588s-orangepi-5-port2.dtbo" \
    "${WORK}/imx708-port1.dtbo" \
    "${WORK}/imx219-port2.dtbo"
apply "${WORK}/opi3.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588s-orangepi-5-port3.dtbo" \
    "${WORK}/imx708-port3.dtbo"
apply "${WORK}/imx519.dtb" \
    "${WORK}/rk3588-isp.dtbo" \
    "${WORK}/rk3588-rock-5b-plus-port0.dtbo" \
    "${WORK}/imx519-port0.dtbo"
python3 - "${PKG}/scripts/resolve-overlay.py" "${WORK}" <<'PY'
import importlib.util
import struct
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("resolve_overlay", sys.argv[1])
resolve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolve)
work = Path(sys.argv[2])

def load(name):
    root, _, _ = resolve.parse_fdt((work / name).read_bytes())
    return root

def prop(root, path, name):
    node = root.find(path)
    assert node is not None, f"missing {path}"
    value = node.get(name)
    assert value is not None, f"missing {path} {name}"
    return value

def u32s(value):
    assert len(value) % 4 == 0
    return struct.unpack(f">{len(value) // 4}I", value)

def u64(value):
    assert len(value) == 8, value.hex()
    return struct.unpack(">Q", value)[0]

def phandle(root, path):
    node = root.find(path)
    assert node is not None, path
    raw = node.get("phandle") or node.get("linux,phandle")
    assert raw is not None, f"{path} has no phandle"
    return u32s(raw)[0]

rock0 = load("rock0.dtb")
assert prop(rock0, "/i2c@3/camera-port0", "compatible") == b"sony,imx708\0"
assert prop(rock0, "/i2c@3/camera-port0", "status") == b"okay\0"
assert prop(rock0, "/i2c@3/camera-port0", "reg") == struct.pack(">I", 0x1A)
assert u32s(prop(rock0, "/i2c@3/camera-port0", "rotation")) == (180,)
assert u64(prop(rock0, "/i2c@3/camera-port0/port/endpoint", "link-frequencies")) == 447000000
assert u64(prop(rock0, "/csi@2/port/endpoint", "link-frequencies")) == 447000000
assert u32s(prop(rock0, "/i2c@3/camera-port0/port/endpoint", "data-lanes")) == (1, 2)
assert prop(rock0, "/i2c@3", "status") == b"okay\0"
assert prop(rock0, "/isp@fdcb0000", "status") == b"okay\0"
assert prop(rock0, "/isp@fdcc0000", "status") == b"disabled\0"
assert prop(rock0, "/dphy@0", "status") == b"okay\0"
reg = u32s(prop(rock0, "/cam-port0-regulator", "phandle"))[0]
assert u32s(prop(rock0, "/i2c@3/camera-port0", "vdig-supply")) == (reg,)
# port0 must not create the port1 sensor node
assert rock0.find("/i2c@4/camera-port1") is None

both = load("rock-both.dtb")
assert prop(both, "/i2c@3/camera-port0", "compatible") == b"sony,imx708\0"
assert prop(both, "/i2c@4/camera-port1", "compatible") == b"sony,imx708\0"
assert prop(both, "/isp@fdcb0000", "status") == b"okay\0"
assert prop(both, "/isp@fdcc0000", "status") == b"okay\0"
first = load("rock-port1-first.dtb")
assert prop(first, "/i2c@4/camera-port1", "compatible") == b"sony,imx708\0"
assert prop(first, "/isp@fdcb0000", "status") == b"okay\0"
assert prop(first, "/isp@fdcc0000", "status") == b"disabled\0"
assert prop(both, "/csi@4", "status") == b"okay\0"
assert u32s(prop(both, "/i2c@4/camera-port1", "reset-gpios"))[0] == phandle(both, "/gpio@2")

four = load("rock-4lane.dtb")
assert u32s(prop(four, "/i2c@3/camera-port0/port/endpoint", "data-lanes")) == (1, 2, 3, 4)
assert u32s(prop(four, "/csi@2/port/endpoint", "data-lanes")) == (1, 2, 3, 4)
assert u64(prop(four, "/csi@2/port/endpoint", "link-frequencies")) == 450000000

opi = load("opi.dtb")
assert prop(opi, "/i2c@7/camera-port1", "compatible") == b"sony,imx708\0"
assert prop(opi, "/i2c@7/camera-port1", "reg") == struct.pack(">I", 0x1A)
assert prop(opi, "/i2c@7/camera-port2", "compatible") == b"sony,imx219\0"
assert prop(opi, "/i2c@7/camera-port2", "reg") == struct.pack(">I", 0x10)
assert u64(prop(opi, "/i2c@7/camera-port2/port/endpoint", "link-frequencies")) == 456000000
assert prop(opi, "/csi@0", "status") == b"okay\0"
assert prop(opi, "/csi@2", "status") == b"okay\0"
assert prop(opi, "/i2c@7", "status") == b"okay\0"

opi3 = load("opi3.dtb")
assert prop(opi3, "/i2c@2/camera-port3", "compatible") == b"sony,imx708\0"
assert prop(opi3, "/csi@1", "status") == b"okay\0"
assert opi3.find("/i2c@7/camera-port1") is None

imx519 = load("imx519.dtb")
assert prop(imx519, "/i2c@3/camera-port0", "compatible") == b"sony,imx519\0"
assert prop(imx519, "/i2c@3/camera-port0", "reg") == struct.pack(">I", 0x1A)
assert u64(prop(imx519, "/i2c@3/camera-port0/port/endpoint", "link-frequencies")) == 408000000

print("overlay apply checks passed")
PY

# apply-overlays.sh: board detection, port selection, parameter file name.
FAKE="${WORK}/root"
mkdir -p "${FAKE}/usr/share/rk3588-camera/overlays" \
    "${FAKE}/usr/share/rk3588-board-rock-5b-plus" \
    "${FAKE}/usr/lib/rk3588-camera" \
    "${FAKE}/etc/rk3588-camera" \
    "${FAKE}/etc/default"
cp "${WORK}/"*.dtbo "${FAKE}/usr/share/rk3588-camera/overlays/"
# The resolved outputs are not shipped overlays.
rm -f "${FAKE}/usr/share/rk3588-camera/overlays/imx708-port"*.dtbo \
    "${FAKE}/usr/share/rk3588-camera/overlays/imx219-port"*.dtbo
cp "${PKG}/scripts/resolve-overlay.py" "${FAKE}/usr/lib/rk3588-camera/"
printf 'U_BOOT_FDT_OVERLAYS="/lib/firmware/panthor.dtbo /usr/share/rk3588-camera/overlays/old.dtbo /lib/firmware/rk3588-rock-5b-plus-imx708-cam0-isp.dtbo /lib/firmware/rk3588-rock-5b-plus-imx708-cam0-isp-custom.dtbo"\n' \
    > "${FAKE}/etc/default/u-boot"
# old.dtbo is not in OVERLAY_DIR, so it must be kept. panthor too.
# The legacy camera overlay must be removed, but its custom variant kept.
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port0,4lane,link-frequency=447000000 imx708,port1"
EOF

RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh"

grep -q 'panthor.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'old.dtbo' "${FAKE}/etc/default/u-boot"
grep -Fq 'rk3588-rock-5b-plus-imx708-cam0-isp-custom.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'rk3588-isp.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'rk3588-rock-5b-plus-port0.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'rk3588-rock-5b-plus-port1.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'imx708-port0-4lane-link-447000000-isp0.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'imx708-port1-isp1.dtbo' "${FAKE}/etc/default/u-boot"
test -f "${FAKE}/var/lib/rk3588-camera/imx708-port0-4lane-link-447000000-isp0.dtbo"

# ISP before the port, port before the sensor that uses it.
line="$(grep '^U_BOOT_FDT_OVERLAYS=' "${FAKE}/etc/default/u-boot")"
python3 - "${line}" <<'PY'
import sys
line = sys.argv[1]
order = ["rk3588-isp.dtbo", "rk3588-rock-5b-plus-port0.dtbo",
         "rk3588-rock-5b-plus-port1.dtbo", "imx708-port0-4lane-link-447000000-isp0.dtbo",
         "imx708-port1-isp1.dtbo", "panthor.dtbo"]
positions = [line.index(name) for name in order[:5]]
assert positions == sorted(positions), line
assert "panthor.dtbo" in line
assert "rk3588-rock-5b-plus-imx708-cam0-isp.dtbo" not in line
# kept overlays stay ahead of the camera stack
assert line.index("panthor.dtbo") < line.index("rk3588-isp.dtbo")
print("apply-overlays.sh checks passed")
PY

# Missing port fails without rewriting a good config.
cp "${FAKE}/etc/default/u-boot" "${FAKE}/etc/default/u-boot.good"
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port3"
EOF
set +e
RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh" >"${WORK}/bad.out" 2>&1
status=$?
set -e
test "${status}" -ne 0
grep -q 'no port3' "${WORK}/bad.out"
cmp "${FAKE}/etc/default/u-boot" "${FAKE}/etc/default/u-boot.good"

# Two cameras asking for isp0 fail without rewriting the boot line.
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port0,isp0 imx708,port1,isp0"
EOF
set +e
RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh" >"${WORK}/isp.out" 2>&1
status=$?
set -e
test "${status}" -ne 0
grep -q 'isp0 is assigned to more than one camera' "${WORK}/isp.out"
cmp "${FAKE}/etc/default/u-boot" "${FAKE}/etc/default/u-boot.good"

# An invalid explicit ISP fails without rewriting the boot line.
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port0 imx708,port1,isp=2"
EOF
set +e
RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh" >"${WORK}/invalid-isp.out" 2>&1
status=$?
set -e
test "${status}" -ne 0
grep -q 'isp2 is not available (use isp0 or isp1)' "${WORK}/invalid-isp.out"
cmp "${FAKE}/etc/default/u-boot" "${FAKE}/etc/default/u-boot.good"

# A later explicit isp0 request takes priority over an earlier implicit one.
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port0 imx708,port1,isp0"
EOF
RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh"
grep -q 'imx708-port0-isp1.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'imx708-port1-isp0.dtbo' "${FAKE}/etc/default/u-boot"
apply "${WORK}/rock-explicit-isp.dtb" \
    "${FAKE}/usr/share/rk3588-camera/overlays/rk3588-isp.dtbo" \
    "${FAKE}/usr/share/rk3588-camera/overlays/rk3588-rock-5b-plus-port0.dtbo" \
    "${FAKE}/usr/share/rk3588-camera/overlays/rk3588-rock-5b-plus-port1.dtbo" \
    "${FAKE}/var/lib/rk3588-camera/imx708-port0-isp1.dtbo" \
    "${FAKE}/var/lib/rk3588-camera/imx708-port1-isp0.dtbo"

# Reversed list: first entry gets isp0 even when that port is port1.
cat > "${FAKE}/etc/rk3588-camera/overlays.conf" <<'EOF'
RK3588_CAMERA_OVERLAYS="imx708,port1 imx708,port0"
EOF
RK3588_CAMERA_CONF="${FAKE}/etc/rk3588-camera/overlays.conf" \
RK3588_U_BOOT_DEFAULT="${FAKE}/etc/default/u-boot" \
RK3588_CAMERA_OVERLAY_DIR="${FAKE}/usr/share/rk3588-camera/overlays" \
RK3588_CAMERA_GEN_DIR="${FAKE}/var/lib/rk3588-camera" \
RK3588_CAMERA_RESOLVER="${FAKE}/usr/lib/rk3588-camera/resolve-overlay.py" \
RK3588_BOARD_SHARE="${FAKE}/usr/share" \
    bash "${PKG}/scripts/apply-overlays.sh"
grep -q 'imx708-port1-isp0.dtbo' "${FAKE}/etc/default/u-boot"
grep -q 'imx708-port0-isp1.dtbo' "${FAKE}/etc/default/u-boot"

echo "all camera overlay tests passed"
