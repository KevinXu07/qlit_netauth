#
# QLIT认证 — 齐鲁理工学院校园网 Dr.COM 门户自动认证
#
# 纯脚本包，无需编译。在 OpenWrt SDK 或源码树中：
#
#   cp -r qlit-netauth package/
#   make package/qlit-netauth/compile V=s
#
# 生成的 ipk 位于 bin/packages/<arch>/base/qlit-netauth_*.ipk
#
include $(TOPDIR)/rules.mk

PKG_NAME:=qlit-netauth
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=kevinxu

include $(INCLUDE_DIR)/package.mk

define Package/qlit-netauth
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Captive Portals
  TITLE:=QLIT campus network (Dr.COM) authentication
  PKGARCH:=all
  # 无第三方依赖：RC4 由 busybox awk 实现，HTTP 请求由 busybox 自带的
  # uclient-fetch 完成；若系统已安装 curl 则优先使用（可获取状态码，探测更精确）。
  DEPENDS:=
endef

define Package/qlit-netauth/description
  齐鲁理工学院校园网 Dr.COM 门户自动认证。

  由路由器完成 Portal 认证，认证后其下所有设备无需单独登录。
  守护进程按可配置的间隔探测在线状态，掉线后自动重新认证。
endef

define Package/qlit-netauth/conffiles
/etc/config/qlit-netauth
endef

define Build/Compile
endef

define Package/qlit-netauth/install
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/etc/config/qlit-netauth $(1)/etc/config/qlit-netauth
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/qlit-netauth $(1)/etc/init.d/qlit-netauth
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/qlit-netauth $(1)/usr/bin/qlit-netauth
endef

define Package/qlit-netauth/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	/etc/init.d/qlit-netauth enable
	echo "QLIT认证 已安装。请编辑 /etc/config/qlit-netauth 填写账号与密码，"
	echo "并将 enabled 设为 1，然后执行 /etc/init.d/qlit-netauth restart"
}
exit 0
endef

$(eval $(call BuildPackage,qlit-netauth))
