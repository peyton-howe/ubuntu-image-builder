# SPDX-License-Identifier: GPL-2.0+
# Replacement module for Ubuntu's in-tree phy-rockchip-samsung-dcphy (CSI RX).
# DKMS installs it under updates/, which depmod searches before kernel/.
obj-m += phy-rockchip-samsung-dcphy.o

# phy-rockchip-samsung-dcphy.c is copied verbatim from the patched tree, so
# definitions the stock headers lack come in through this header.
ccflags-y += -include $(src)/dcphy-compat.h
