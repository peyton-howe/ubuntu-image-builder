# rk3588-aic8800-dkms

DKMS package for the AIC8800 USB Wi-Fi and Bluetooth module on the Radxa
ROCK 5C. The mainline kernel has no driver for it.

## Source

- Upstream: [radxa-pkg/aic8800](https://github.com/radxa-pkg/aic8800), commit
  `e31c031` ("fix building on kernel 7.4"), the `src/USB/driver_fw/drivers/aic8800`
  and `aic_btusb` directories.
- Radxa's `debian/patches` series applied in order. The upstream sources have CRLF
  line endings and two of the patches only apply to LF files, so the files were
  converted to LF first. The series includes the Linux 7.1 to 7.4 build fixes.
- Build artifacts (`*.o`, `*.ko`, `Module.symvers`, ...) are not included.
- `src/aic8800` builds `aic_load_fw` and `aic8800_fdrv`; `src/aic_btusb` builds
  `aic_btusb`. Built against Ubuntu 7.3.0-9 with no errors.

## Firmware

Not vendored here. The package depends on Radxa's `aic8800-firmware` .deb
(release `5.0+git20260123.5f7be68d-10` of radxa-pkg/aic8800), which installs
the files to `/lib/firmware/aic8800_fw/USB/`, the path the patched driver reads.
`scripts/fetch-aic8800-firmware.sh` downloads it into `build/debs/`, pinned by
release asset and SHA-256, and the ROCK 5C image build installs it with this
package. To update it, change the version, asset id and checksum in that script.

To refresh, repeat the steps above with a newer radxa-pkg/aic8800 checkout.
