# AP6256 firmware (Orange Pi 5 Pro WiFi/Bluetooth)

The AP6256 (BCM43456 WiFi on SDIO, BCM4345C5 Bluetooth on a UART) is described
by the stock kernel's device tree, but Ubuntu's `linux-firmware` ships none of
the files its drivers request. They are installed to `/lib/firmware/brcm/`
under the names upstream `brcmfmac` and `hci_bcm` ask for.

| File | Source (armbian/firmware @ 2a9e1c19460401443267926181191d57e3ff175d) |
|---|---|
| `brcmfmac43456-sdio.bin` | `brcm/brcmfmac43456-sdio.bin` |
| `brcmfmac43456-sdio.clm_blob` | `brcm/brcmfmac43456-sdio.clm_blob` |
| `brcmfmac43456-sdio.xunlong,orangepi-5-pro.txt` | `brcm/brcmfmac43456-sdio.txt` (the AP6256 nvram; the board-specific name keeps it from being used by other BCM43456 boards) |
| `BCM4345C5.hcd` | `brcm/BCM4345C5.hcd` |

To refresh, copy the same paths from a newer armbian/firmware checkout and
update the commit above.
