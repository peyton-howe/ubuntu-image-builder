"""Round-trip the FDT rewriter without dtc."""

import importlib.util
import struct
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[1] / "scripts" / "resolve-overlay.py"
spec = importlib.util.spec_from_file_location("resolve_overlay", MODULE)
resolve = importlib.util.module_from_spec(spec)
spec.loader.exec_module(resolve)


def sensor_tree():
    root = resolve.Node("")
    fixups = resolve.Node("__fixups__")
    fixups.props = [
        ("cam_port_sensor", b"/fragment@0:target:0\0"),
        ("cam_port_sensor_ep", b"/fragment@1:target:0\0"),
        ("cam_port_csi_ep", b"/fragment@2:target:0\0"),
        (
            "cam_port_reg",
            b"/fragment@0/__overlay__:vdig-supply:0\0"
            b"/fragment@0/__overlay__:vana1-supply:4\0",
        ),
        ("cam_isp", b"/fragment@3:target:0\0"),
        ("cam_isp_mmu", b"/fragment@4:target:0\0"),
        ("cru", b"/fragment@0/__overlay__:clocks:0\0"),
    ]
    frag0 = resolve.Node("fragment@0")
    ov0 = resolve.Node("__overlay__")
    ov0.props = [
        ("compatible", b"sony,imx708\0"),
        ("reg", struct.pack(">I", 0x1A)),
        ("status", b"okay\0"),
        ("orientation", struct.pack(">I", 2)),
        ("vdig-supply", struct.pack(">I", 0xFFFFFFFF)),
    ]
    frag0.children = [ov0]
    frag1 = resolve.Node("fragment@1")
    ov1 = resolve.Node("__overlay__")
    ov1.props = [
        ("data-lanes", struct.pack(">2I", 1, 2)),
        ("clock-noncontinuous", b""),
        ("link-frequencies", struct.pack(">Q", 450000000)),
    ]
    frag1.children = [ov1]
    frag2 = resolve.Node("fragment@2")
    ov2 = resolve.Node("__overlay__")
    ov2.props = [
        ("data-lanes", struct.pack(">2I", 1, 2)),
        ("link-frequencies", struct.pack(">Q", 450000000)),
    ]
    frag2.children = [ov2]
    root.children = [frag0, frag1, frag2, fixups]
    return root


class ResolveTests(unittest.TestCase):
    def blob(self):
        return resolve.emit_fdt(sensor_tree(), [(0, 0)])

    def test_roundtrip_preserves_properties(self):
        root, rsv, _ = resolve.parse_fdt(self.blob())
        self.assertEqual(rsv, [(0, 0)])
        sensor = root.find("/fragment@0/__overlay__")
        self.assertEqual(sensor.get("compatible"), b"sony,imx708\0")
        self.assertEqual(sensor.get("reg"), struct.pack(">I", 0x1A))
        self.assertEqual(
            root.child("__fixups__").get("cam_port_reg").split(b"\0")[0],
            b"/fragment@0/__overlay__:vdig-supply:0",
        )

    def test_retarget_port_and_parameters(self):
        out = resolve.retarget_overlay(
            self.blob(),
            port=0,
            isp=0,
            four_lane=True,
            link_frequency=447000000,
            rotation=180,
            orientation=1,
        )
        root, _, _ = resolve.parse_fdt(out)
        fixups = root.child("__fixups__")
        names = [name for name, _ in fixups.props]
        self.assertIn("cam_port0_sensor", names)
        self.assertIn("cam_port0_reg", names)
        self.assertIn("cru", names)
        self.assertIn("isp0", names)
        self.assertIn("isp0_mmu", names)
        self.assertNotIn("cam_port_sensor", names)
        self.assertNotIn("cam_isp", names)
        reg = fixups.get("cam_port0_reg")
        self.assertIn(b"vana1-supply:4", reg)
        sensor = root.find("/fragment@0/__overlay__")
        self.assertEqual(sensor.get("rotation"), struct.pack(">I", 180))
        self.assertEqual(sensor.get("orientation"), struct.pack(">I", 1))
        lanes = struct.pack(">4I", 1, 2, 3, 4)
        self.assertEqual(root.find("/fragment@1/__overlay__").get("data-lanes"), lanes)
        self.assertEqual(root.find("/fragment@2/__overlay__").get("data-lanes"), lanes)
        link = struct.pack(">Q", 447000000)
        self.assertEqual(
            root.find("/fragment@1/__overlay__").get("link-frequencies"), link
        )
        self.assertEqual(
            root.find("/fragment@1/__overlay__").get("clock-noncontinuous"), b""
        )

    def test_addr_sets_reg(self):
        out = resolve.retarget_overlay(self.blob(), port=0, isp=0, addr=0x37)
        root, _, _ = resolve.parse_fdt(out)
        sensor = root.find("/fragment@0/__overlay__")
        self.assertEqual(sensor.get("reg"), struct.pack(">I", 0x37))

    def test_addr_rejects_out_of_range(self):
        for bad in (0, 2, 0x78, 0x100):
            with self.assertRaises(resolve.FdtError):
                resolve.retarget_overlay(self.blob(), port=0, isp=0, addr=bad)

    def test_port1_leaves_unrelated_fixup(self):
        out = resolve.retarget_overlay(self.blob(), port=1, isp=1)
        root, _, _ = resolve.parse_fdt(out)
        fixups = root.child("__fixups__")
        self.assertIsNotNone(fixups.get("cam_port1_csi_ep"))
        self.assertIsNotNone(fixups.get("isp1"))
        self.assertIsNotNone(fixups.get("isp1_mmu"))
        self.assertIsNone(fixups.get("isp0"))
        self.assertIsNotNone(fixups.get("cru"))
        lanes = root.find("/fragment@1/__overlay__").get("data-lanes")
        self.assertEqual(lanes, struct.pack(">2I", 1, 2))


if __name__ == "__main__":
    unittest.main()
