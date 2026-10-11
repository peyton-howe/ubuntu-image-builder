# SPDX-License-Identifier: GPL-2.0
obj-m += imx708.o

# linux-rockchip imx708.c includes <linux/rk-camera-module.h>, which stock
# Ubuntu headers do not ship.
ccflags-y += -I$(src)/include
