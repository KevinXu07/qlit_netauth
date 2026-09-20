# QLIT认证 (qlit-netauth)

齐鲁理工学院校园网 Dr.COM 门户自动认证的 OpenWrt 插件。由路由器完成 Portal 认证，
其下所有设备无需单独登录；守护进程按间隔探测在线状态，掉线后自动重新认证。

* 零第三方依赖：RC4 由 busybox awk 实现，HTTP 使用系统自带的 uclient-fetch
  （已安装 curl 时优先使用，可获取状态码，探测更精确）
* 提供命令行、UCI 配置与网页界面三种使用方式
* 附抓包分析工具，可自行还原门户协议

---

## 1. 认证协议

认证流程来自对门户登录流量的抓包分析。登录请求：

```
POST http://<portal>/ac_portal/login.php
Content-Type: application/x-www-form-urlencoded; charset=UTF-8

opr=pwdLogin&userName=<账号>&pwd=<RC4 密文>&auth_tag=<毫秒时间戳>&rememberPwd=0
```

关键点：

* `auth_tag` 是毫秒时间戳，与响应头 `Date` 一致。
* `pwd` 是密码经 RC4 加密后的十六进制串，**RC4 的密钥即 `auth_tag` 本身**。
  门户页面 JS 中为 `rckey = +(new Date()) + ''` 与 `do_encrypt_rc4(pwd, rckey)`，
  即密钥由客户端生成并随请求一并提交，服务端据此解密。
* `rc4.js` 中的 `do_encrypt_rc4` 即标准 RC4（KSA + PRGA），输出为逐字节的两位十六进制，
  因此密文长度恒为明文的两倍。

注销使用 `GET http://<portal>/homepage/logout`。

若需核对本机实现与抓包数据是否一致（从登录请求中取出 `pwd` 与 `auth_tag`）：

```sh
qlit-netauth verify <密码> <auth_tag> <请求里的 pwd>
```

输出 `ok` 即表示一致。另可用 `tooling/har_login_dump.py <抓包.har>` 打印上述各字段
并直接解密出密码。

---

## 2. 安装

### 2.1 安装已编译的 ipk

到 [Releases](https://github.com/KevinXu07/qlit_netauth/releases) 下载后传到路由器：

| 文件 | 说明 |
|---|---|
| `qlit-netauth_*.ipk` | 核心包，必需 |
| `luci-app-qlit-netauth_*.ipk` | 网页界面，JS 版 LuCI（OpenWrt 21.02 及以上） |
| `luci-app-qlit-netauth-lua_*.ipk` | 网页界面，Lua 版 LuCI（19.07 / QWRT 等） |
| `qlit-netauth-files.tar.gz` | 散装文件，配合 `install.sh` 使用 |

```sh
scp qlit-netauth_*.ipk root@192.168.1.1:/tmp/
opkg install /tmp/qlit-netauth_1.0.0-1_all.ipk
opkg install /tmp/luci-app-qlit-netauth-lua_1.0.0-1_all.ipk   # 按 LuCI 版本二选一
```

界面包只装其一，判别方法见第 4 节。所有包的 `Architecture` 均为 `all`，任何架构的
路由器均可安装。

### 2.2 免 opkg

```sh
sh install.sh root@192.168.1.1            # 核心 + 网页界面（自动判断版本）
sh install.sh root@192.168.1.1 --no-luci  # 仅命令行
```

脚本会判断路由器上是 JS 版还是 Lua 版 LuCI 并安装对应界面。文件经 `ssh + cat` 传输
而非 `scp`：老固件的 dropbear 不含 `sftp-server`，新版 `scp` 默认使用 SFTP 协议会失败。

### 2.3 从源码编译

仓库根目录本身即核心包（`Makefile` + `files/`），两个界面包各自独立成目录：

```sh
git clone https://github.com/KevinXu07/qlit_netauth && cd qlit_netauth

mkdir -p <SDK>/package/qlit-netauth
cp Makefile <SDK>/package/qlit-netauth/
cp -r files <SDK>/package/qlit-netauth/
cp -r luci-app-qlit-netauth luci-app-qlit-netauth-lua <SDK>/package/

cd <SDK>
./scripts/feeds update -a && ./scripts/feeds install -a
make defconfig
make package/qlit-netauth/compile V=s
make package/luci-app-qlit-netauth/compile V=s          # 或 -lua
```

产物位于 `bin/packages/<arch>/`。`luci-app-qlit-netauth` 的目录名不可更改：
`luci.mk` 按目录名推导包名。CI 使用同一流程，参见 `.github/workflows/build.yml`。

### 2.4 启用

```sh
uci set qlit-netauth.settings.username='学号'
uci set qlit-netauth.settings.password='密码'
uci set qlit-netauth.settings.enabled=1
uci commit qlit-netauth
/etc/init.d/qlit-netauth restart
logread -f -e qlit-netauth
```

正常时日志输出：

```
qlit-netauth: 启动: portal=10.2.2.82 user=... 探测间隔=60s
qlit-netauth: 认证成功: 用户 ...
qlit-netauth: 网络在线
```

部署前建议先执行一次 `/usr/bin/qlit-netauth selftest`：它以参考向量校验本机的 RC4
与时间戳实现。若报告 RC4 不一致，程序会拒绝登录，以免以错误的密码反复尝试。

---

## 3. 配置

配置文件为 `/etc/config/qlit-netauth`，各选项亦可在网页界面中修改。

| 选项 | 默认值 | 说明 |
|---|---|---|
| `enabled` | `0` | 总开关 |
| `username` / `password` | 空 | 校园网账号与密码，密码以明文填写 |
| `portal` | `10.2.2.82` | 认证门户地址 |
| `interval` | `60` | 在线状态探测间隔（秒） |
| `retry_interval` | `15` | 认证失败后的重试间隔（秒） |
| `timeout` | `8` | 单次 HTTP 请求超时（秒） |
| `probe` | 见下 | 在线探测列表 |
| `bind_interface` | 空 | 认证流量的出口接口，仅 curl 支持 |
| `log_level` | `info` | `error` / `warn` / `info` / `debug` |

### 在线探测

判断是否需要认证依据响应体特征，而非 HTTP 状态码：`uclient-fetch` 无法输出状态码；
且未认证时门户会将请求劫持至认证页，返回内容为一段 HTML，既不等于期望的特征串
也不为空，据此判定为离线。

`probe` 以空格分隔多条，每条形如 `URL|MARKER`：

| 写法 | 含义 |
|---|---|
| `URL\|=TEXT` | 响应体须恰好等于 `TEXT` |
| `URL\|=` | 响应体须为空（即 HTTP 204），仅在已安装 curl 时采信 |
| `URL\|TEXT` | 响应体须包含 `TEXT` |

任意一条匹配即判定为在线。MARKER 中允许含空格，默认值中的
`=Microsoft Connect Test` 即属此情况。

若日志中持续出现反复认证，说明所列探测地址在本网络下均不可达，请替换为本网络内
可访问的地址。

---

## 4. 网页界面

LuCI 有两代，界面互不兼容。判别方法：

```sh
[ -d /usr/share/luci/menu.d ] && echo "JS 版（21.02 及以上）" || echo "Lua 版（19.07 / QWRT 等）"
```

也可由 `install.sh` 自动判断。注意不可仅依据版本号：部分第三方固件（如 QWRT）会把
`DISTRIB_RELEASE` 一直写作 `19.07-SNAPSHOT`，但实际使用的是新版 LuCI，且仍属 Lua 版。
应以 `/usr/share/luci/menu.d` 是否存在为准。

对应关系：

| 路由器上的 LuCI | 安装的包 |
|---|---|
| JS 版 | `luci-app-qlit-netauth` |
| Lua 版 | `luci-app-qlit-netauth-lua` |

安装后在 **服务 → QLIT认证** 使用，提供状态显示，以及立即认证 / 注销下线 / 自检
三个按钮。

`luci-app-qlit-netauth-lua` 刻意未使用 `luci.mk`：该文件会引入 `+luci-lua-runtime`
依赖，而该包在 19.07 系固件上并不存在，会导致无法安装。

状态显示读取守护进程写入的 `/var/run/qlit-netauth.state`，而非实时执行探测
（后者最长可能阻塞二十余秒）。因此界面显示的是最近一次探测结果，并标注距上次检测
经过的时间。守护进程未运行时显示「暂无状态」，属正常现象。

---

## 5. 常用命令

```
/etc/init.d/qlit-netauth start | stop | restart | enable | disable

qlit-netauth selftest      自检：以参考向量校验 RC4、时间戳与 URL 编码
qlit-netauth verify P K C  以指定向量校验本机 RC4 实现
qlit-netauth status        输出 online 或 offline（执行一次真实探测）
qlit-netauth state         输出缓存的最近状态，不产生网络请求
qlit-netauth check         探测一次，未认证时登录（daemon 每轮执行的操作）
qlit-netauth login         强制执行一次认证
qlit-netauth logout        注销
qlit-netauth rc4 TEXT      输出 TEXT 以当前时间戳加密后的结果
qlit-netauth help          输出帮助
```

选项：`-c FILE` 指定配置文件，`-v` 输出详细日志。

---

## 6. 已知限制

* **认证绑定在路由器 WAN 口的 MAC 上。** 更换路由器或改动 WAN 口 MAC 后需重新认证，
  守护进程会自动完成。
* **`interval` 不宜过小。** 门户对频繁登录可能存在风控，60 秒足够。
* **`bind_interface` 仅 curl 支持**（`opkg install curl`）。使用 uclient-fetch 时该选项
  不生效，程序会记录一条警告。
* **密码含非 ASCII 字符时**，逐字节的 RC4 实现可能与浏览器端 UTF-16 `charCodeAt`
  的语义不一致；ASCII 密码不受影响。
* **代理工具**（passwall、openclash 等）默认只重定向 LAN 客户端的 PREROUTING 流量，
  不影响路由器自身发起的认证请求。若固件额外配置了 `nat OUTPUT` 重定向，探测可能
  经代理返回成功而被误判为在线。
* **网页界面需与 LuCI 版本匹配**，装错则菜单中不会出现，判别方法见第 4 节。
* **门户协议变更后**，可用 `tooling/har_login_dump.py` 重新分析抓包，并据此调整脚本中
  `do_login()` 的请求构造。

---

## 7. 开发

测试方法与开发过程中遇到的问题及其成因，见 [docs/dev-notes.md](docs/dev-notes.md)。
