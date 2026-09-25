# Samsung DCPHY CSI-RX (replacement module)

`phy-rockchip-samsung-dcphy.c` is the patched driver from patch `0001` (copied
from a patched mainline tree). When enabled in `dkms.conf`, this module
installs under `/updates/dkms` and should override the in-tree module of the
same name.

Still needed before enabling:

- Confirm Ubuntu’s headers export the symbols this file needs
- Blacklist / softdep so the stock module is not preferred
- Rebase onto each Ubuntu ABI bump
