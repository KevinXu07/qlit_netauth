# QLIT认证 (qlit-netauth)

齐鲁理工学院（QLIT）校园网 Dr.COM 门户自动认证的 OpenWrt 插件。

路由器自己完成 Portal 认证，**其下所有设备（手机、电脑、平板）都不再需要单独登录**；
守护进程按间隔探测在线状态，掉线后自动重新认证。

认证流程来自对门户登录流量的抓包分析，不是推测。

```
files/usr/bin/qlit-netauth        主程序（busybox ash + awk，无第三方依赖）
files/etc/init.d/qlit-netauth     procd 服务脚本
files/etc/config/qlit-netauth     UCI 配置
Makefile                          核心包的 OpenWrt 包定义（可编 ipk）
luci-app-qlit-netauth/            网页界面 —— JS 版 LuCI（OpenWrt 21.02+）
luci-app-qlit-netauth-lua/        网页界面 —— Lua 版 LuCI（19.07 / QWRT 等）
install.sh                        免编译，直接传到路由器（自动选对界面）
tests/                            端到端测试（用模拟门户，不碰真实网络）
tooling/har_login_dump.py         抓包分析：重新还原登录协议
```

核心包负责实际认证，两个 `luci-app-*` 只是界面，都依赖核心包。**界面二选一**，
选哪个取决于路由器上的 LuCI 是哪一代（见第 3 节）。只想跑命令行就只装核心包。

---

## 1. 从抓包里还原出的协议

门户 `10.2.2.82` 是 Dr.COM（城市热点）。登录是一个 POST：

```
POST http://10.2.2.82/ac_portal/login.php
Content-Type: application/x-www-form-urlencoded; charset=UTF-8

opr=pwdLogin&userName=<账号>&pwd=<RC4 密文>&auth_tag=<毫秒时间戳>&rememberPwd=0
```

关键在 `pwd` 和 `auth_tag` 的关系：

* `auth_tag` 是一个**毫秒时间戳**，与响应头 `Date` 完全对得上（抓包样本中两者的
  时间差在毫秒级）。
* `pwd` 是密码经 **RC4 加密后的十六进制串**，而 **`auth_tag` 本身即为 RC4 的密钥**。

门户页面的 JS 里写得很直白：

```js
var rckey = +(new Date()) + '';
var pwd  = do_encrypt_rc4($("#passwd").val(), rckey);   // auth_tag = rckey
```

`rc4.js` 中的 `do_encrypt_rc4` 即标准 RC4（KSA + PRGA），输出为逐字节的两位十六进制。
密钥由**客户端**生成并随请求一起送出去，服务端拿它来解密 `pwd` —— 所以这个值是自描述的。

验证方式：密文长度恒为明文的两倍（逐字节转两位 hex）。例如内置参考向量
`example-password` + 密钥 `1700000000000` 得到密文
`6dd4f823a554faf3c5e62d27b5983c91`（16 字节明文 → 32 个 hex 字符）。

**核对你自己的抓包**：从门户登录请求里取出 `userName`、`pwd`、`auth_tag`，
用你实际使用的密码代入：

```sh
qlit-netauth verify <你的密码> <auth_tag> <请求里的 pwd>
```

输出 `ok` 即表明本机实现与你的门户一致。这比依赖某个写死的向量更有意义 ——
它对任何学校、任何账号都适用。

注销和查状态用另外两个接口：

```
GET  http://10.2.2.82/homepage/logout        注销，返回 {'success':true,...}
POST http://10.2.2.82/homepage/info.php      查用户信息，body: opr=list
```

想自己复核上面的每一步，跑：

```sh
python3 tooling/har_login_dump.py <你自己的抓包.har>
```

---

## 2. 安装

三种方式，选一种。

### 方式 A：下载已编译好的 ipk（最省事）

到 [Releases](https://github.com/KevinXu07/qlit_netauth/releases) 下载最新版本：

| 文件 | 用途 |
|---|---|
| `qlit-netauth_*.ipk` | 核心包，必需 |
| `luci-app-qlit-netauth_*.ipk` | JS 版界面（OpenWrt 21.02 及以上） |
| `luci-app-qlit-netauth-lua_*.ipk` | Lua 版界面（19.07 / QWRT 等） |
| `qlit-netauth-files.tar.gz` | 散装文件，配合 `install.sh` 使用（不想用 opkg 时） |

把 ipk 传到路由器安装（界面包二选一，见第 3 节）：

```sh
scp qlit-netauth_*.ipk root@192.168.1.1:/tmp/
opkg install /tmp/qlit-netauth_1.0.0-1_all.ipk
opkg install /tmp/luci-app-qlit-netauth-lua_1.0.0-1_all.ipk   # 按你的 LuCI 版本选
```

三个包的 `Architecture` 均为 `all`，任何架构的路由器都可安装
（已在 aarch64 设备上核对过元数据）。

### 方式 B：从源码编译 ipk

仓库根目录本身即核心包（`Makefile` + `files/`），两个界面包各自独立成目录：

```sh
git clone https://github.com/KevinXu07/qlit_netauth
cd qlit_netauth

# 在 OpenWrt SDK 或源码树里
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

产物在 `bin/packages/<arch>/`。CI 用的就是这套流程，见
`.github/workflows/build.yml`。

> `luci-app-qlit-netauth` 的目录名不能改 —— `luci.mk` 按目录名推导包名。
> `-lua` 那个刻意没有使用 `luci.mk`（原因见第 3 节），故无此限制。

### 方式 C：直接 scp（免 opkg）

```sh
sh install.sh root@192.168.1.1            # 核心 + 网页界面（自动选对版本）
sh install.sh root@192.168.1.1 --no-luci  # 只要命令行
```

脚本会探测路由器上是 JS 版还是 Lua 版 LuCI，装对应的那个；没装 LuCI 就跳过。
传文件用的是 `ssh + cat` 而不是 `scp` —— 老固件（19.07 / QWRT）上的 dropbear
没有 `sftp-server`，新版 `scp` 默认走 SFTP 会直接失败。

### 填账号密码并启动（三种方式都一样）

安装网页界面后，可直接在浏览器中进入 **服务 → QLIT认证** 填写（见下一节）。
只用命令行则是：

```sh
ssh root@192.168.1.1
vi /etc/config/qlit-netauth
```

```uci
config qlit-netauth 'settings'
	option enabled '1'          # <- 改成 1
	option username 'your-account'   # <- 填写学号 / 账号
	option password 'xxxxxxxx'  # <- 明文即可，脚本自己负责加密
	option portal '10.2.2.82'
	...
```

```sh
/etc/init.d/qlit-netauth restart
logread -f -e qlit-netauth
```

正常的话日志里会出现：

```
qlit-netauth: 启动: portal=10.2.2.82 user=your-account 探测间隔=60s
qlit-netauth: 认证成功: 用户 your-account
qlit-netauth: 网络在线
```

---

## 3. 网页界面

### 先判断该装哪个

LuCI 有两代，界面互不兼容。看路由器上有没有这个目录：

```sh
[ -d /usr/share/luci/menu.d ] && echo "JS 版 LuCI（21.02+）" || echo "Lua 版 LuCI（19.07/QWRT 等）"
```

| 路由器上的 LuCI | 装哪个包 | 菜单/权限怎么定义 |
|---|---|---|
| **JS 版**（OpenWrt 21.02 及以上） | `luci-app-qlit-netauth` | `menu.d` + `rpcd/acl.d` 的 JSON |
| **Lua 版**（19.07、QWRT、iStoreOS 等） | `luci-app-qlit-netauth-lua` | `luci/controller/*.lua` |

判断方法不止看版本号：有些第三方固件（例如 QWRT）会把 `DISTRIB_RELEASE`
一直写成 `19.07-SNAPSHOT`，但实际装的是 2024 年的新版 LuCI，**还是 Lua 版**——
真正决定的是那个目录在不在。`install.sh` 会自动判断。

`-lua` 那个包刻意没有用 `feeds/luci/luci.mk`：`luci.mk` 会给包加上
`+luci-lua-runtime` 依赖，而 19.07 系固件上并没有这个包，会直接装不上。

### 界面长什么样

安装对应界面后，在 LuCI 中进入 **服务 → QLIT认证**（已在 QWRT 上实测通过）：

```
┌─ 服务状态 ─────────────────────────────────────┐
│  当前状态： [在线]  （每 5 秒自动刷新）          │
│                                                │
│  [ 立即认证 ]  [ 注销下线 ]  [ 自检 ]            │
└────────────────────────────────────────────────┘

┌─ 设置 ────────────────────────────────────────┐
│  [ 账号 ] [ 高级 ]        ← 两个标签页          │
│                                                │
│  启用自动认证    [x]                            │
│  账号            your-account                 │
│  密码            ••••••••                      │
│  认证门户        10.2.2.82                     │
└────────────────────────────────────────────────┘
```

* **立即认证** / **注销下线** / **自检** 会把命令的实际输出显示出来（JS 版弹窗，
  Lua 版显示在按钮下方）。
* JS 版的状态每 5 秒自动刷新；Lua 版刷新页面时更新。
* 密码字段是密码框，不回显明文。
* 权限最小化：JS 版只有那三个按钮通过 rpcd 执行 `/usr/bin/qlit-netauth`，授权范围在
  `acl.d` 里限定为这一个可执行文件；Lua 版是服务端 Lua 直接执行，天然只有管理员可达。

### 为什么状态是读缓存而不是实时探测

界面**不会**为了显示状态去跑 `qlit-netauth status` —— 那个命令要做真实的网络探测
（最多 3 个地址 × 每次最多 `timeout` 秒），足以让页面卡二十多秒。

改成守护进程每轮把结果写到 `/var/run/qlit-netauth.state`（内容为
`online|offline <unix时间戳>`），界面只读这个文件，瞬时返回。因此界面显示的是
**最近一次探测的结果**，并会标出「多少秒前」，而不是此刻的实时状态。

守护进程没在跑时（例如 `enabled=0`），界面会显示「暂无状态」，这是正常的。

---

## 4. 先自检，再部署

`selftest` 会用**抓包里的真实向量**验证路由器本机的 RC4 实现是否正确：

```sh
/usr/bin/qlit-netauth selftest
```

```
ok   RC4 与参考向量一致 (example-password + 1700000000000 -> 6dd4f823a554faf3c5e62d27b5983c91)
ok   毫秒时间戳: 1789894494000
ok   URL 编码: a%20b%26c%3Dd%2B1
ok   HTTP 客户端: uclient-fetch/wget
ok   配置: user=your-account portal=10.2.2.82 probe 条目数=3
warn 当前网络状态: 离线（或探测地址都不可达，检查 probe 配置）
```

第一行必须是 `ok`。如果它是 `FAIL`，说明本机 awk 行为不对，
**此时登录会被主动拒绝**（程序不会拿算错的密码去反复撞门户），
按提示排查 `awk` 是否可用即可。

之所以要这道防线：RC4 是用 busybox awk 实现的（这样零依赖），
而不同 awk 实现的边角行为理论上可能有差异。自检 + 登录前校验把
「静默地算出错误密码」这种最难查的故障变成了明确的报错。

---

## 5. 常用命令

```sh
/etc/init.d/qlit-netauth start | stop | restart | enable | disable

qlit-netauth selftest      # 自检
qlit-netauth status        # 打印 online / offline（会做一次真实的网络探测）
qlit-netauth state         # 打印守护进程缓存的状态，不发网络请求（界面用）
qlit-netauth check         # 探测一次，未认证则登录（daemon 每轮执行的操作）
qlit-netauth login         # 强制认证一次
qlit-netauth logout        # 注销下线
qlit-netauth rc4 Hello     # 调试：用当前时间戳加密并打印 hex
qlit-netauth -v check      # 带详细日志
qlit-netauth help
```

---

## 6. 配置说明

| 选项 | 默认 | 说明 |
|---|---|---|
| `enabled` | `0` | 总开关 |
| `username` / `password` | 空 | 校园网账号密码，明文填写 |
| `portal` | `10.2.2.82` | 门户地址，可写 `http://10.2.2.82` |
| `interval` | `60` | 在线时的探测间隔（秒） |
| `retry_interval` | `15` | 登录失败后的重试间隔（秒） |
| `timeout` | `8` | 单次 HTTP 超时（秒） |
| `probe` | 见下 | 在线探测列表 |
| `bind_interface` | 空 | 多 WAN 时指定出口接口（仅 curl 支持） |
| `log_level` | `info` | `error` / `warn` / `info` / `debug` |

### 在线探测（`probe`）

判断「是否需要认证」靠的是探测请求的**响应体特征**，不是状态码 —— 因为未认证时
门户会把 HTTP 请求劫持到认证页，拿到的是一段 HTML，既不是期望的特征串、
也不会是空，于是正确判为离线。

格式为空格分隔的 `URL|MARKER`：

| 写法 | 含义 |
|---|---|
| `URL\|=TEXT` | 响应体必须**恰好等于** `TEXT` |
| `URL\|=` | 响应体必须为空（即 HTTP 204），**仅装了 curl 时采信** |
| `URL\|TEXT` | 响应体**包含** `TEXT` |

任意一条命中即认为在线。默认值：

```
http://detectportal.firefox.com/success.txt|=success
http://captive.apple.com/hotspot-detect.html|<TITLE>Success</TITLE>
http://www.msftconnecttest.com/connecttest.txt|=Microsoft Connect Test
```

三条互相独立，任何一条通得了就说明在线。

> 如果日志里出现**反复认证**（每隔一分钟就登录一次），说明这些探测地址在你
> 的网络下都不可达。换成本网络内能访问的地址即可，例如校园网自己的主页配
> `URL|某个固定字符串`。

---

## 7. 测试

有两套测试：核心逻辑的端到端测试，和网页界面的静态一致性测试。

### 7.1 核心逻辑（`sh tests/run_tests.sh`）

不碰真实校园网，用 `tests/mock_portal.py` 起一个模拟门户。这个模拟门户会
**像真门户那样用收到的 `auth_tag` 解密 `pwd` 再比对密码**，所以能真正验证
加密链路、请求格式与状态机，而非仅验证「程序未崩溃」。

36 项检查，覆盖：自检向量、离线→认证→在线、已在线不重复认证、强制登录、
注销、密码错误必须报错、含特殊字符的密码（`P@ss w0rd&x=1+2`，验证 URL 编码）、
daemon 常驻与 SIGTERM 响应、探测地址不可达时的容错、probe 配置写错时的告警，
以及标记中含空格的探测条目（默认配置里就有一条如此，见第 9.5 节）。

这套测试在 **macOS sh 和真正的 busybox ash 下都是 36/36 通过**
（busybox ash 即路由器上实际使用的 shell）。

### 7.2 网页界面（`node tests/test_luci_view.js`）

用一套最小的 LuCI 运行时替身**真正执行** `settings.js`（按 LuCI 实际的方式
解析 `'require xxx'` 指令并注入模块），然后检查界面与周边文件是否对得上：

* 视图能加载，`load()` / `render()` 都能跑通
* 界面里每个 UCI 选项名都真实存在于 `files/etc/config/qlit-netauth`
* 每个选项都有说明文字、密码是密码框、日志级别下拉项齐全
* `menu.d` 的 `action.path` 指向真实存在的视图文件
* `acl.d` 给视图执行的那个可执行文件授了 exec 权限、给 uci 配置授了读写权限
* 三个操作按钮都在

这类跨文件错位（选项名拼错、菜单指向不存在的视图、ACL 漏授权）不会报错，
只会表现为「点了没反应」或「设置了不生效」，最难查，所以单独测。

30 项检查。这套检查做过变异验证 —— 故意拼错选项名、把菜单指向不存在的文件、
去掉 ACL 的 exec 授权，三者都能被抓出来，不是空转。

### 7.3 Lua 版界面（在路由器上跑）

```sh
lua tests/test_cbi_model.lua /usr/lib/lua/luci/model/cbi/qlit-netauth/settings.lua \
    /etc/config/qlit-netauth
```

63 项检查。会真正加载 CBI 模型、构建表单，检查：

* 段映射（`settings` / `qlit-netauth`）与标签页
* 界面里每个选项名都真实存在于 UCI 配置文件中（反向也查：配置里没有界面上改不到的项）
* 每个选项用的控件类正确（是 Flag 还是 Value、是 Button 还是 DummyValue）
* 密码框、`rawhtml`、按钮 `inputtitle`/`inputstyle`、数值型 `datatype` 等渲染属性
* **状态渲染的功能测试**：写一个「42 秒前的 online」到状态文件，真的调用
  `cfgvalue()`，断言页面上显示的是「42 秒前」而不是一串 unix 时间戳

最后那条是必须真跑一遍才能发现的 —— 它就抓到过一个真实 bug（见第 9 节）。
这个测试只能在装了 LuCI 的路由器上跑，本机（macOS）没有 LuCI。

> 关于抓包文件：`.gitignore` 已排除 `*.har`。抓包内含可直接解出的账号与密码
> （RC4 密钥就写在同一个请求里，因此密文等同于明文），以及个人信息，
> 请勿提交到仓库。测试用例中的账号与密码均为虚构值。

---

## 8. 已知边界

* **认证绑定在路由器 WAN 口的 MAC 上。** 换路由器、换 WAN 口网线、
  或改了 WAN 的 MAC，都需要重新认证（守护进程会自动做）。
* **`interval` 不要设得太小。** 门户对频繁登录可能有风控。60 秒足够，
  掉线感知最多慢 1 分钟；想更快可以把 `interval` 降到 20。
* **多 WAN / 策略路由**需要设 `bind_interface`，且只有 `curl` 支持该选项
  （`opkg install curl`）。用 uclient-fetch 时程序会打一条 warn 提醒你。
* **密码含非 ASCII 字符**（中文等）时 RC4 的逐字节实现可能与浏览器端
  的 UTF-16 `charCodeAt` 语义不一致。ASCII 密码没问题。
* **网页界面要选对版本。** JS 版（21.02+）和 Lua 版（19.07/QWRT 等）是两套
  互不兼容的界面，装错了菜单里不会出现。判断方法见第 3 节，或直接让
  `install.sh` 自动判断。
* **认证流量不会被代理工具劫持。** 本项目从路由器自身发起请求，走 OUTPUT 链；
  passwall / openclash 这类工具默认只重定向 LAN 客户端的 PREROUTING 流量，
  不影响路由器自身。但若固件额外配置了 `nat OUTPUT` 重定向，则需留意
  —— 那时探测地址可能经由代理返回成功，导致误判为在线。
* 如果学校改了门户版本或加密方式，用 `tooling/har_login_dump.py`
  重新抓包分析，再对照改 `do_login()` 里的请求构造即可。

---

## 9. 开发笔记（已知问题与成因）

都是真机调试时撞上、且从源码里确认过原因的。改这个项目时值得先看一眼。

### 9.1 LuCI 控制器的模块级 local 会失效

Lua 版 LuCI 会把每个控制器的 `index()` 用 `string.dump` 编译成**字节码**塞进
`/tmp/luci-indexcache`（缓存内容为 `loadstring("LuaQ\000...")`），而**字节码不保留
upvalue**。所以这样写：

```lua
local fs = require "nixio.fs"      -- 模块级 local
function index()
    if not fs.access(...) then     -- 从缓存加载后 fs 是 nil
```

会导致整棵菜单树构建失败、全站返回 500：`attempt to index upvalue 'fs' (a nil value)`。
必须用全局名（`nixio.fs.access`，运行时沿环境链解析）或在函数内部 require。
官方应用（如 `luci-app-arpbind`）都是这么写的。

### 9.2 `local a, b = x and f()` 只会拿到一个值

Lua 里 `and`/`or` 表达式会把多返回值**截断成一个**。写状态解析时：

```lua
local st, ts = raw and raw:match("^(%S+)%s+(%d+)")   -- ts 永远是 nil
```

`ts` 恒为 nil，于是 `age` 退化成 `os.time()`，界面上把 unix 时间戳当秒数显示。
正确写法是先兜底再直接调用（`raw` 用 `or ""` 保证非 nil）：

```lua
local raw = fs.readfile(STATE) or ""
local st, ts = raw:match("^(%S+)%s+(%d+)")
```

### 9.3 老固件上没有 sftp-server

19.07 / QWRT 的 dropbear 不带 `sftp-server`，而新版 `scp` 默认走 SFTP 协议，
会报 `ash: /usr/libexec/sftp-server: not found` 然后连接关闭。用
`ssh host 'cat > 路径' < 本地文件` 代替 `scp`，对任何 sshd 都有效。
`install.sh` 即采用该方式传输文件。

### 9.4 判断进程状态时不应使用 `pgrep -f`

`pgrep -f "qlit-netauth daemon"` 会匹配到你自己那条命令行里含有该字符串的 shell，
产生「明明没启动却报告在运行」的假阳性。用 `ubus call service list '{"name":"..."}'`
或 `ps w | grep "[q]lit-netauth"`（方括号技巧）来判断。

### 9.5 按空白切分配置值时，要留意标记本身可能含空格

`probe` 选项以空格分隔多条，但 MARKER 里可以含空格，默认配置中的
`=Microsoft Connect Test` 即是如此。若直接 `for x in $CFG_PROBE` 切分，该条目会
被拆成三段，其中两段缺少 `|` 分隔符，于是每个探测周期都往 syslog 写两条警告。

正确做法是先按空白切分，再把不以 `http://` 或 `https://` 开头的片段并回前一条
（探测地址必须带协议头，否则 curl 与 uclient-fetch 均无法使用，该判据是可靠的）。

这个问题只有在真实配置上跑才会暴露：测试用例最初用的标记不含空格，全部通过。
现在第 12 节专门固化了这个场景。

### 9.6 日志不要同时写 stderr 与 syslog

`log()` 原本既 `echo >&2`（便于命令行观察）又调用 `logger`（写入 syslog）。
由 procd 启动时 stderr 会被一并转入 syslog，且优先级恒为 `err`，结果是每条消息
重复出现两次，且 info 级消息被误标成错误。

解决办法是让 init 脚本通过 `procd_set_param env QLIT_UNDER_PROCD=1` 告知程序，
`log()` 在该变量存在时跳过 stderr 回显；命令行手工执行时行为不变。

### 9.7 覆盖正在运行的 shell 脚本有风险

busybox ash 按文件偏移增量读取脚本。若在脚本运行期间覆盖同名文件，后续读取可能
落在错误的偏移上，执行到错乱的代码。

更新部署时应先 `/etc/init.d/qlit-netauth stop`，覆盖文件后再 `start`。
`install.sh` 不做此处理（它面向首次安装），升级时请手动先停服务。

### 9.8 探测不要用状态码，用响应体特征

`uclient-fetch` 无法输出 HTTP 状态码，而且未认证时门户会把请求劫持到认证页 ——
拿到的是 HTML，既不是期望的特征串也不是空。按响应体特征判断在这两种情况下
都能得出正确结论。详见第 6 节。

---

## 10. 验证状态

| 项目 | 状态 |
|---|---|
| RC4 与真实抓包密文的精确比对 | ✅ 开发期间通过（内置自检改用参考向量，见下） |
| RC4 对 Python 参考实现 40/40 随机向量 | ✅ 通过 |
| 内置自检向量 | 已改为虚构值 `example-password`，两条独立实现交叉核对；核对真实抓包请用 `verify` 子命令（见第 1 节） |
| 核心逻辑 36 项端到端测试（模拟门户） | ✅ macOS sh 与真实 busybox ash 各一遍 |
| **RC4 在真实设备 busybox awk v1.28.3 上** | ✅ 以真实抓包向量实测一致 |
| Lua 版界面 63 项测试（真机） | ✅ 通过 |
| Lua 版界面在真机浏览器渲染 | ✅ HTTP 200，元素齐全，按钮执行链路打通 |
| JS 版界面（未在真机验证） | ⚠️ 逻辑与跨文件一致性已测（30 项 + 变异验证），但缺少 21.02+ 设备，未进行真实渲染验证 |
| ipk 编译 | ⚠️ 未验证 —— OpenWrt SDK 为 Linux 工具链，缺少 Linux 环境或 Docker；Makefile 按标准写法编写，但未经实际编译 |
| 真实校园网认证 | ⚠️ 未进行 —— 需要真实账号密码。部署后请先执行 `selftest` |

已在真机上验证过的设备：**京东云 AX1800 Pro（IPQ6018, aarch64），QWRT 固件**
（Lua 版 LuCI，busybox 1.28.3，curl 可用）。
