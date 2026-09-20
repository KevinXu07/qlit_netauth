#
# QLIT认证 — LuCI 界面（JS 版，适用于 OpenWrt 21.02 及以上）
#
# 纯前端资源，无需编译。依赖核心包 qlit-netauth 提供 /usr/bin/qlit-netauth。
#
# 在 OpenWrt 源码树或 SDK 中：
#
#   cp -r qlit-netauth        package/
#   cp -r luci-app-qlit-netauth package/
#   make package/luci-app-qlit-netauth/compile V=s
#
include $(TOPDIR)/rules.mk

PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=kevinxu

LUCI_TITLE:=LuCI app for QLIT campus network (Dr.COM) authentication
LUCI_DEPENDS:=+luci-base +qlit-netauth
LUCI_PKGARCH:=all

# luci.mk 依据目录名推导包名（LUCI_NAME?=$(notdir $(CURDIR))），故本目录
# 必须命名为 luci-app-qlit-netauth。该文件同时负责将 htdocs/ 安装至 /www、
# 将 root/ 安装至 /，并自动添加用于清理 LuCI 缓存的 postinst，无需自行编写安装规则。
#
# 包位于 luci 源码树之外时，luci.mk 位于 feeds/luci/；若整个包放入
# luci 树内（applications/ 目录下），则改用相对的 ../../luci.mk。
ifneq ($(wildcard $(TOPDIR)/feeds/luci/luci.mk),)
  include $(TOPDIR)/feeds/luci/luci.mk
else
  include ../../luci.mk
endif

# call BuildPackage - OpenWrt buildroot signature
