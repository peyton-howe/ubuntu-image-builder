# SPDX-License-Identifier: GPL-2.0
# Replacement module for Ubuntu's in-tree rockchip-cif (VICAP capture).
# DKMS installs it under updates/, which depmod searches before kernel/.
obj-m += rockchip-cif.o

rockchip-cif-objs += rkcif-capture-dvp.o
rockchip-cif-objs += rkcif-capture-mipi.o
rockchip-cif-objs += rkcif-dev.o
rockchip-cif-objs += rkcif-interface.o
rockchip-cif-objs += rkcif-stream.o
