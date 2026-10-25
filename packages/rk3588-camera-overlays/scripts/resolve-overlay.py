#!/usr/bin/env python3
"""Bake port and bus parameters into a camera sensor dtbo.

U-Boot applies dtbo files as-is. It does not implement Raspberry Pi
__overrides__, so apply-overlays.sh calls this before boot.

Sensor dtbos are written against the generic labels cam_port_sensor,
cam_port_sensor_ep, cam_port_csi_ep, and cam_port_reg. A port overlay
exports those labels with a port number (cam_port0_sensor, ...). This
rewrites the sensor dtbo's __fixups__ so it attaches to that port, and
points cam_isp / cam_isp_mmu at isp0 or isp1. It also
applies the same knobs the Pi exposes: 4lane, link-frequency, rotation,
orientation.
"""

import argparse
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 0x1
FDT_END_NODE = 0x2
FDT_PROP = 0x3
FDT_NOP = 0x4
FDT_END = 0x9

REQUIRED_FIXUPS = (
    "cam_port_sensor",
    "cam_port_sensor_ep",
    "cam_port_csi_ep",
    "cam_port_reg",
    "cam_isp",
    "cam_isp_mmu",
)


class FdtError(Exception):
    pass


class Node:
    def __init__(self, name):
        self.name = name
        self.props = []  # list[(str, bytes)]
        self.children = []

    def get(self, name):
        for prop, value in self.props:
            if prop == name:
                return value
        return None

    def set(self, name, value):
        for i, (prop, _) in enumerate(self.props):
            if prop == name:
                self.props[i] = (name, value)
                return
        self.props.append((name, value))

    def rename(self, old, new):
        for i, (prop, value) in enumerate(self.props):
            if prop == old:
                self.props[i] = (new, value)
                return True
        return False

    def child(self, name):
        for node in self.children:
            if node.name == name:
                return node
        return None

    def walk(self):
        yield self
        for child in self.children:
            yield from child.walk()

    def find(self, path):
        path = path.strip("/")
        node = self
        if not path:
            return node
        for part in path.split("/"):
            node = node.child(part)
            if node is None:
                return None
        return node


def _u32(blob, off):
    return struct.unpack_from(">I", blob, off)[0]


def _align4(off):
    return (off + 3) & ~3


def _cstring(blob, off):
    end = blob.index(b"\0", off)
    return blob[off:end].decode("ascii"), end + 1


def parse_fdt(blob):
    if len(blob) < 40 or _u32(blob, 0) != FDT_MAGIC:
        raise FdtError("not a device-tree blob")
    off_struct = _u32(blob, 8)
    off_strings = _u32(blob, 12)
    off_rsv = _u32(blob, 16)
    version = _u32(blob, 20)
    rsv = []
    off = off_rsv
    while True:
        if off + 16 > len(blob):
            raise FdtError("truncated memory reserve map")
        addr, size = struct.unpack_from(">QQ", blob, off)
        rsv.append((addr, size))
        off += 16
        if addr == 0 and size == 0:
            break

    def parse_node(off):
        while True:
            token = _u32(blob, off)
            off += 4
            if token == FDT_NOP:
                continue
            if token != FDT_BEGIN_NODE:
                raise FdtError(f"expected BEGIN_NODE at {off - 4}, got {token}")
            break
        name, off = _cstring(blob, off)
        off = _align4(off)
        node = Node(name)
        while True:
            token = _u32(blob, off)
            off += 4
            if token == FDT_NOP:
                continue
            if token == FDT_PROP:
                length = _u32(blob, off)
                nameoff = _u32(blob, off + 4)
                off += 8
                value = blob[off:off + length]
                off = _align4(off + length)
                prop_name, _ = _cstring(blob, off_strings + nameoff)
                node.props.append((prop_name, value))
            elif token == FDT_BEGIN_NODE:
                off -= 4
                child, off = parse_node(off)
                node.children.append(child)
            elif token == FDT_END_NODE:
                return node, off
            else:
                raise FdtError(f"unexpected token {token}")

    root, off = parse_node(off_struct)
    token = _u32(blob, off)
    if token != FDT_END:
        raise FdtError("missing FDT_END")
    return root, rsv, version


def emit_fdt(root, rsv, version=17):
    strings = {}
    blob_parts = []

    def intern(name):
        if name not in strings:
            strings[name] = None  # filled once we know the order
        return name

    def collect(node):
        for prop, _ in node.props:
            intern(prop)
        for child in node.children:
            collect(child)

    collect(root)
    string_blob = bytearray()
    for name in strings:
        strings[name] = len(string_blob)
        string_blob += name.encode("ascii") + b"\0"

    def emit(node):
        blob_parts.append(struct.pack(">I", FDT_BEGIN_NODE))
        raw = node.name.encode("ascii") + b"\0"
        blob_parts.append(raw)
        if len(raw) % 4:
            blob_parts.append(b"\0" * (4 - len(raw) % 4))
        for prop, value in node.props:
            blob_parts.append(struct.pack(">III", FDT_PROP, len(value), strings[prop]))
            blob_parts.append(value)
            if len(value) % 4:
                blob_parts.append(b"\0" * (4 - len(value) % 4))
        for child in node.children:
            emit(child)
        blob_parts.append(struct.pack(">I", FDT_END_NODE))

    emit(root)
    blob_parts.append(struct.pack(">I", FDT_END))
    struct_blob = b"".join(blob_parts)

    rsv_blob = b"".join(struct.pack(">QQ", addr, size) for addr, size in rsv)
    if not rsv or rsv[-1] != (0, 0):
        rsv_blob += struct.pack(">QQ", 0, 0)

    header_size = 40
    off_rsv = header_size
    off_struct = off_rsv + len(rsv_blob)
    off_strings = off_struct + len(struct_blob)
    total = off_strings + len(string_blob)
    header = struct.pack(
        ">10I",
        FDT_MAGIC,
        total,
        off_struct,
        off_strings,
        off_rsv,
        version if version >= 17 else 17,
        16,  # last compatible version
        0,  # boot cpuid
        len(string_blob),
        len(struct_blob),
    )
    return header + rsv_blob + struct_blob + bytes(string_blob)


def _retarget_name(name, port):
    if name == "cam_port" or name.startswith("cam_port_"):
        return f"cam_port{port}" + name[len("cam_port"):]
    return None


def _fragment_nodes(root):
    """Nodes that are part of an overlay fragment, not fixup metadata."""
    for node in root.children:
        if not node.name.startswith("fragment@"):
            continue
        yield from node.walk()


def retarget_overlay(blob, port, isp=None, four_lane=False, link_frequency=None,
                     rotation=None, orientation=None, addr=None):
    root, rsv, version = parse_fdt(blob)
    fixups = root.child("__fixups__")
    if fixups is None:
        raise FdtError("sensor overlay has no __fixups__")

    present = {name for name, _ in fixups.props}
    missing = [name for name in REQUIRED_FIXUPS if name not in present]
    if missing:
        raise FdtError(
            "sensor overlay is missing fixups: " + ", ".join(missing)
        )

    renamed = []
    for name, value in list(fixups.props):
        new = _retarget_name(name, port)
        if new is None:
            continue
        if not fixups.rename(name, new):
            raise FdtError(f"could not rename fixup {name}")
        renamed.append(new)
    if not renamed:
        raise FdtError("no cam_port fixups to retarget")
    if isp not in (0, 1):
        raise FdtError(f"isp must be 0 or 1, got {isp}")
    isp_names = (("cam_isp", f"isp{isp}"), ("cam_isp_mmu", f"isp{isp}_mmu"))
    for old, new in isp_names:
        if not fixups.rename(old, new):
            raise FdtError(f"sensor overlay is missing fixup {old}")

    def props_named(prop_name):
        found = []
        for node in _fragment_nodes(root):
            if node.get(prop_name) is not None:
                found.append(node)
        return found

    if four_lane:
        lanes = struct.pack(">4I", 1, 2, 3, 4)
        nodes = props_named("data-lanes")
        if len(nodes) < 1:
            raise FdtError("4lane: overlay has no data-lanes property")
        for node in nodes:
            node.set("data-lanes", lanes)

    if link_frequency is not None:
        if link_frequency < 0 or link_frequency > 0xFFFFFFFFFFFFFFFF:
            raise FdtError(f"link-frequency out of range: {link_frequency}")
        value = struct.pack(">Q", link_frequency)
        nodes = props_named("link-frequencies")
        if len(nodes) < 1:
            raise FdtError("link-frequency: overlay has no link-frequencies property")
        for node in nodes:
            node.set("link-frequencies", value)

    sensors = [
        node for node in _fragment_nodes(root) if node.get("compatible") is not None
    ]
    if len(sensors) != 1:
        raise FdtError(f"expected one sensor node, found {len(sensors)}")
    sensor = sensors[0]

    if rotation is not None:
        if rotation < 0 or rotation > 0xFFFFFFFF:
            raise FdtError(f"rotation out of range: {rotation}")
        sensor.set("rotation", struct.pack(">I", rotation))

    if orientation is not None:
        if orientation < 0 or orientation > 0xFFFFFFFF:
            raise FdtError(f"orientation out of range: {orientation}")
        sensor.set("orientation", struct.pack(">I", orientation))

    if addr is not None:
        # 7-bit I2C address of the sensor, replacing the overlay's reg.
        if addr < 0x03 or addr > 0x77:
            raise FdtError(f"addr must be a 7-bit I2C address, got {addr:#x}")
        sensor.set("reg", struct.pack(">I", addr))

    return emit_fdt(root, rsv, version)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("src")
    parser.add_argument("dst")
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--isp", type=int, choices=(0, 1), required=True)
    parser.add_argument("--four-lane", action="store_true")
    parser.add_argument("--link-frequency", type=int)
    parser.add_argument("--rotation", type=int)
    parser.add_argument("--orientation", type=int)
    parser.add_argument("--addr", type=lambda s: int(s, 0),
                        help="sensor I2C address (7-bit, e.g. 0x37)")
    args = parser.parse_args(argv)
    if args.port < 0:
        parser.error("port must be >= 0")
    try:
        with open(args.src, "rb") as fh:
            blob = fh.read()
        out = retarget_overlay(
            blob,
            args.port,
            args.isp,
            four_lane=args.four_lane,
            link_frequency=args.link_frequency,
            rotation=args.rotation,
            orientation=args.orientation,
            addr=args.addr,
        )
    except (OSError, FdtError) as exc:
        print(f"resolve-overlay: {exc}", file=sys.stderr)
        return 1
    with open(args.dst, "wb") as fh:
        fh.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
