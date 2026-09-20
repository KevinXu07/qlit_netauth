#!/bin/sh
# =============================================================================
#  手动安装到路由器（不想编译 ipk 时用这个）
#
#  用法:
#      sh install.sh root@192.168.1.1
#      sh install.sh root@192.168.1.1 --no-luci     # 只装命令行部分
#
#  脚本会自动判断路由器上是哪种 LuCI 并装对应的界面：
#      有 /usr/share/luci/menu.d/            -> JS 版 LuCI（21.02+），装 luci-app-qlit-netauth
#      有 /usr/lib/lua/luci/controller/      -> Lua 版 LuCI（19.07/QWRT），装 luci-app-qlit-netauth-lua
#
#  安装完成后需填写账号与密码：
#      ssh root@192.168.1.1
#      vi /etc/config/qlit-netauth     # 填 username / password，把 enabled 改 1
#      /etc/init.d/qlit-netauth restart
# =============================================================================
set -e

HOST="$1"
[ -n "$HOST" ] || { echo "用法: sh install.sh root@<路由器IP> [--no-luci]" >&2; exit 2; }

WANT_LUCI=1
[ "$2" = "--no-luci" ] && WANT_LUCI=0

HERE=$(cd "$(dirname "$0")" && pwd)

# 传文件使用 ssh + cat 而非 scp。
# 老固件（如 QWRT / 19.07）上的 dropbear 不含 sftp-server，新版 scp 默认使用
# SFTP 协议会直接失败；ssh + cat 对任何 sshd 均有效。
put() {
	ssh "$HOST" "cat > '$2'" < "$1"
}

exists() {
	ssh "$HOST" "[ -e '$1' ] && echo yes || echo no"
}

echo "==> 复制核心文件到 $HOST"
put "$HERE/files/usr/bin/qlit-netauth"    /usr/bin/qlit-netauth
put "$HERE/files/etc/init.d/qlit-netauth" /etc/init.d/qlit-netauth

# 配置文件可能已存在（升级场景），不要覆盖用户填好的账号密码
if [ "$(exists /etc/config/qlit-netauth)" = "yes" ]; then
	echo "==> /etc/config/qlit-netauth 已存在，保留原配置不覆盖"
else
	put "$HERE/files/etc/config/qlit-netauth" /etc/config/qlit-netauth
fi

ssh "$HOST" 'chmod 755 /usr/bin/qlit-netauth /etc/init.d/qlit-netauth
             [ -s /etc/config/qlit-netauth ] || chmod 600 /etc/config/qlit-netauth
             /etc/init.d/qlit-netauth enable'
echo "==> 服务已启用开机自启"

if [ "$WANT_LUCI" -eq 1 ]; then
	if [ "$(exists /usr/share/luci/menu.d)" = "yes" ]; then
		echo "==> 检测到 JS 版 LuCI（21.02+），安装网页界面"
		ssh "$HOST" 'mkdir -p /www/luci-static/resources/view/qlit-netauth \
		                     /usr/share/luci/menu.d /usr/share/rpcd/acl.d'
		put "$HERE/luci-app-qlit-netauth/htdocs/luci-static/resources/view/qlit-netauth/settings.js" \
		    /www/luci-static/resources/view/qlit-netauth/settings.js
		put "$HERE/luci-app-qlit-netauth/root/usr/share/luci/menu.d/luci-app-qlit-netauth.json" \
		    /usr/share/luci/menu.d/luci-app-qlit-netauth.json
		put "$HERE/luci-app-qlit-netauth/root/usr/share/rpcd/acl.d/luci-app-qlit-netauth.json" \
		    /usr/share/rpcd/acl.d/luci-app-qlit-netauth.json
		ssh "$HOST" 'rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache/; /etc/init.d/rpcd reload 2>/dev/null; true'

	elif [ "$(exists /usr/lib/lua/luci/controller)" = "yes" ]; then
		echo "==> 检测到 Lua 版 LuCI（19.07 / QWRT 等），安装网页界面"
		ssh "$HOST" 'mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi/qlit-netauth'
		put "$HERE/luci-app-qlit-netauth-lua/luasrc/controller/qlit-netauth.lua" \
		    /usr/lib/lua/luci/controller/qlit-netauth.lua
		put "$HERE/luci-app-qlit-netauth-lua/luasrc/model/cbi/qlit-netauth/settings.lua" \
		    /usr/lib/lua/luci/model/cbi/qlit-netauth/settings.lua
		ssh "$HOST" 'chmod 644 /usr/lib/lua/luci/controller/qlit-netauth.lua \
		                          /usr/lib/lua/luci/model/cbi/qlit-netauth/settings.lua'
		# Lua 版 LuCI 会缓存菜单索引（且为字节码形式），必须清理
		ssh "$HOST" 'rm -f /tmp/luci-indexcache*; rm -rf /tmp/luci-modulecache/'

	else
		echo "==> 路由器上未找到 LuCI，跳过网页界面"
	fi
fi

echo "==> 在路由器上运行自检"
ssh "$HOST" '/usr/bin/qlit-netauth selftest' || true

cat <<EOF

安装完成。还需填写账号与密码：

    ssh $HOST
    vi /etc/config/qlit-netauth      # 填写 username / password，并将 enabled 设为 1
    /etc/init.d/qlit-netauth restart
    logread -f -e qlit-netauth       # 查看日志

或在网页界面中填写：服务 -> QLIT认证

EOF
