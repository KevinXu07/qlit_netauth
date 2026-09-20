#
# QLIT认证 — LuCI 界面（Lua CBI 版）
#
# 适用于 19.07 系的 Lua 版 LuCI（含 QWRT、iStoreOS 等第三方固件）。
# 若为 21.02 及以上的 JS 版 LuCI，请使用同仓库的 luci-app-qlit-netauth。
#
# 判别方法：路由器上是否存在 /usr/share/luci/menu.d/ 目录？
#   存在   → JS 版 LuCI，使用 luci-app-qlit-netauth
#   不存在 → Lua 版 LuCI，使用本包
#
# 本包刻意不使用 feeds/luci/luci.mk：该文件会为包添加 +luci-lua-runtime 依赖，
# 而该包在 19.07 系固件上并不存在，会导致无法安装。直接采用普通包定义更为可靠。
#
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-qlit-netauth-lua
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=kevinxu

include $(INCLUDE_DIR)/package.mk

define Package/luci-app-qlit-netauth-lua
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI (Lua CBI) app for QLIT campus network authentication
  PKGARCH:=all
  DEPENDS:=+luci-base +qlit-netauth
endef

define Package/luci-app-qlit-netauth-lua/description
  齐鲁理工学院校园网 Dr.COM 门户自动认证的 LuCI 配置界面。

  适用于 19.07 系的 Lua 版 LuCI。提供状态显示、立即认证 / 注销 / 自检
  三个操作按钮，以及账号与高级参数的图形化配置。
endef

define Build/Compile
endef

define Package/luci-app-qlit-netauth-lua/install
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/controller
	$(INSTALL_DATA) ./luasrc/controller/qlit-netauth.lua \
		$(1)/usr/lib/lua/luci/controller/qlit-netauth.lua

	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/model/cbi/qlit-netauth
	$(INSTALL_DATA) ./luasrc/model/cbi/qlit-netauth/settings.lua \
		$(1)/usr/lib/lua/luci/model/cbi/qlit-netauth/settings.lua
endef

# LuCI 会缓存菜单索引与已编译模板，未清理时新页面不会出现在菜单中
define Package/luci-app-qlit-netauth-lua/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/
	echo "luci-app-qlit-netauth-lua 已安装。入口: 服务 -> QLIT认证"
}
exit 0
endef

define Package/luci-app-qlit-netauth-lua/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] || {
	rm -f /tmp/luci-indexcache
	rm -rf /tmp/luci-modulecache/
}
exit 0
endef

$(eval $(call BuildPackage,luci-app-qlit-netauth-lua))
