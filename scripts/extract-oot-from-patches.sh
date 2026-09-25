#!/usr/bin/env bash
# Re-extract out-of-tree sources for packages/ from patches/kernel/mainline/.
set -eE
trap 'echo Error: in $0 on line $LINENO' ERR

cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
REPO_ROOT="$(pwd)"
PATCH_DIR="${REPO_ROOT}/patches/kernel/mainline"

python3 <<'PY'
from pathlib import Path
import re
import subprocess

repo = Path('.').resolve()
patch_dir = repo / 'patches/kernel/mainline'

def extract_new_files(patch_path: Path, want_suffixes=None, want_prefixes=None):
    text = patch_path.read_text()
    parts = re.split(r'(?=^diff --git )', text, flags=re.M)
    out = {}
    for part in parts:
        if not re.search(r'^new file mode', part, re.M):
            continue
        m = re.search(r' b/(.+)$', part.splitlines()[0])
        if not m:
            continue
        rel = m.group(1)
        if want_suffixes and not any(rel.endswith(s) for s in want_suffixes):
            continue
        if want_prefixes and not any(rel.startswith(p) for p in want_prefixes):
            continue
        content = []
        in_body = False
        for line in part.splitlines():
            if line.startswith('+++'):
                in_body = True
                continue
            if not in_body:
                continue
            if line.startswith('+'):
                content.append(line[1:])
        out[rel] = '\n'.join(content) + ('\n' if content else '')
    return out

# Overlays
ov = extract_new_files(patch_dir / '0006-arm64-dts-rockchip-imx708-camera-overlays.patch',
                       want_suffixes=['.dtso'])
dts_dir = repo / 'packages/rk3588-camera-overlays/dts'
dts_dir.mkdir(parents=True, exist_ok=True)
for rel, content in ov.items():
    (dts_dir / Path(rel).name).write_text(content)
    print(f'overlays: {Path(rel).name}')

# IMX708
imx = extract_new_files(patch_dir / '0004-media-i2c-imx708.patch', want_suffixes=['.c'])
imx_dir = repo / 'packages/rk3588-camera-dkms/src/imx708'
imx_dir.mkdir(parents=True, exist_ok=True)
for rel, content in imx.items():
    if rel.endswith('imx708.c'):
        (imx_dir / 'imx708.c').write_text(content)
        print('dkms: imx708/imx708.c')

# rkisp2
rk = extract_new_files(patch_dir / '0002-media-rockchip-rkisp2.patch',
                       want_prefixes=['drivers/media/platform/rockchip/rkisp2/',
                                      'include/uapi/linux/media/rockchip/'])
rk_root = repo / 'packages/rk3588-camera-dkms/src/rkisp2'
for rel, content in rk.items():
    if rel.startswith('drivers/media/platform/rockchip/rkisp2/'):
        dest = rk_root / Path(rel).relative_to('drivers/media/platform/rockchip/rkisp2')
    else:
        dest = rk_root / 'uapi' / Path(rel).name
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(content)
    print(f'dkms: rkisp2/{dest.relative_to(rk_root)}')

# Apply compat patch 0007 with remapped paths
compat = (patch_dir / '0007-media-rkisp2-v4l2-isp-compat.patch').read_text()
compat = compat.replace('drivers/media/platform/rockchip/rkisp2/', 'rkisp2/')
compat = compat.replace('include/uapi/linux/media/rockchip/', 'rkisp2/uapi/')
tmp = Path('/tmp/0007-remapped.patch')
tmp.write_text(compat)
subprocess.run(
    ['git', 'apply', '--whitespace=nowarn',
     '--directory=packages/rk3588-camera-dkms/src', str(tmp)],
    check=False,
)
print('applied 0007 compat (best-effort)')

# DCPHY: prefer copy from a patched mainline tree if present
dcphy_src = repo / 'build/kernel/linux-mainline/drivers/phy/rockchip/phy-rockchip-samsung-dcphy.c'
dcphy_dst = repo / 'packages/rk3588-camera-dkms/src/dcphy/phy-rockchip-samsung-dcphy.c'
dcphy_dst.parent.mkdir(parents=True, exist_ok=True)
if dcphy_src.is_file():
    dcphy_dst.write_bytes(dcphy_src.read_bytes())
    print(f'dkms: dcphy from {dcphy_src}')
else:
    print('dkms: dcphy source missing — build mainline kernel once or vendor the .c')
PY

echo "[✓] Extract complete"
