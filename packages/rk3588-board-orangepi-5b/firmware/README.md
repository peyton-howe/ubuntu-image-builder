# AP6275P firmware (Orange Pi 5B WiFi/Bluetooth)

Installed to `/lib/firmware/brcm/` under the names upstream `brcmfmac` and
`hci_bcm` request; Ubuntu's `linux-firmware` ships none of them.

| File | Source (armbian/firmware @ 2a9e1c19460401443267926181191d57e3ff175d) |
|---|---|
| `brcmfmac43752-pcie.bin` | `brcm/brcmfmac43752-pcie.bin` |
| `brcmfmac43752-pcie.clm_blob` | `brcm/brcmfmac43752-pcie.clm_blob` |
| `brcmfmac43752-pcie.txt` | `ap6275p/nvram_AP6275P.txt` (the module's calibrated nvram) |
| `BCM4362A2.hcd` | `brcm/BCM4362A2.hcd` (AP6275P's BT half reports as BCM4362A2) |

To refresh, copy the same paths from a newer armbian/firmware checkout and
update the commit above.
