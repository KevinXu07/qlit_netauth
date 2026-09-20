# 开发笔记

面向维护者。使用说明见 [README](../README.md)。

---

## 1. 测试

### 1.1 核心逻辑

```sh
sh tests/run_tests.sh
```

不接触真实校园网：`tests/mock_portal.py` 会启动一个模拟门户，并**像真门户那样以收到
的 `auth_tag` 解密 `pwd` 再比对密码**，因此验证的是完整的加密链路与状态机，而非仅
「程序未崩溃」。

39 项检查，覆盖：内置参考向量、`verify` 子命令、离线 → 认证 → 在线、已在线时不重复
认证、强制登录、注销、密码错误必须报错、含特殊字符的密码（`P@ss w0rd&x=1+2`，验证
URL 编码）、daemon 常驻与 SIGTERM 响应、探测地址不可达时的容错、`probe` 配置写错时
的告警，以及标记中含空格的探测条目（见 2.5 节）。

在 macOS sh 与真实 busybox ash 下均为 39/39 通过（busybox ash 即路由器上实际使用的
shell）。

### 1.2 JS 版界面

```sh
node tests/test_luci_view.js
```

以一套最小的 LuCI 运行时替身**真正执行** `settings.js`（按 LuCI 实际的方式解析
`'require xxx'` 指令并注入模块），再核对界面与周边文件是否一致：选项名是否存在于
UCI 配置文件、`menu.d` 的 `action.path` 是否指向真实存在的视图、`acl.d` 是否授予了
所需的 exec 与 uci 权限、三个操作按钮是否齐全等。30 项检查。

这套检查做过变异验证：故意拼错选项名、把菜单指向不存在的文件、去掉 ACL 的 exec
授权，三者均能被抓出。

### 1.3 Lua 版界面

只能在装有 LuCI 的路由器上执行：

```sh
lua tests/test_cbi_model.lua \
    /usr/lib/lua/luci/model/cbi/qlit-netauth/settings.lua \
    /etc/config/qlit-netauth
```

63 项检查：段映射与标签页、选项名与 UCI 配置的双向核对、每个选项的控件类是否正确、
密码框与 `rawhtml` 等渲染属性，以及对 `cfgvalue()` 的功能测试（写入一个「42 秒前的
online」，断言页面显示「42 秒前」而非一串 unix 时间戳）。

最后一项是必须真跑一遍才能发现的，它抓到过一个真实缺陷（见 2.2 节）。

测试会覆盖 `/var/run/qlit-netauth.state` 与 `/tmp/qlit-netauth-ui.out`，运行前会先
备份、结束后恢复，不会破坏线上运行状态。

---

## 2. 开发笔记（已知问题与成因）

均系真机调试时遇到，并已从源码确认成因。

### 2.1 LuCI 控制器的模块级 local 会失效

Lua 版 LuCI 会把每个控制器的 `index()` 用 `string.dump` 编译为**字节码**存入
`/tmp/luci-indexcache`（缓存内容为 `loadstring("LuaQ\000...")`），而**字节码不保留
upvalue**。因此：

```lua
local fs = require "nixio.fs"      -- 模块级 local
function index()
    if not fs.access(...) then     -- 自缓存加载后 fs 为 nil
```

会导致整棵菜单树构建失败、全站返回 500：`attempt to index upvalue 'fs' (a nil value)`。
必须使用全局名（`nixio.fs.access`，运行时沿环境链解析）或在函数内部 require。
官方应用（如 `luci-app-arpbind`）均采用此写法。

### 2.2 `local a, b = x and f()` 只会取得一个值

Lua 中 `and` / `or` 表达式会将多返回值**截断为一个**：

```lua
local st, ts = raw and raw:match("^(%S+)%s+(%d+)")   -- ts 恒为 nil
```

`ts` 恒为 nil，致使 `age` 退化为 `os.time()`，界面上把 unix 时间戳当作秒数显示。
正确写法是先兜底再直接调用（以 `or ""` 保证 `raw` 非 nil）：

```lua
local raw = fs.readfile(STATE) or ""
local st, ts = raw:match("^(%S+)%s+(%d+)")
```

### 2.3 老固件上没有 sftp-server

19.07 / QWRT 的 dropbear 不含 `sftp-server`，而新版 `scp` 默认使用 SFTP 协议，会报
`ash: /usr/libexec/sftp-server: not found` 后关闭连接。改用
`ssh host 'cat > 路径' < 本地文件`，对任何 sshd 均有效。`install.sh` 即采用该方式。

### 2.4 判断进程状态时不应使用 `pgrep -f`

`pgrep -f "qlit-netauth daemon"` 会匹配到自身命令行中含有该字符串的 shell，产生
「明明未启动却报告在运行」的假阳性。应使用
`ubus call service list '{"name":"..."}'` 或 `ps w | grep "[q]lit-netauth"`
（方括号技巧）。

### 2.5 按空白切分配置值时，标记本身可能含空格

`probe` 以空格分隔多条，但 MARKER 中可以含空格，默认值中的
`=Microsoft Connect Test` 即是如此。若直接以 `for x in $CFG_PROBE` 切分，该条目会被
拆成三段，其中两段缺少 `|` 分隔符，于是每个探测周期都向 syslog 写入两条警告。

正确做法是先按空白切分，再将不以 `http://` 或 `https://` 开头的片段并回前一条
（探测地址必须带协议头，否则 curl 与 uclient-fetch 均无法使用，该判据是可靠的）。

该问题只在真实配置上运行才会暴露：测试用例最初的标记不含空格，全部通过。现已在
`tests/run_tests.sh` 第 12 节固化了这一场景。

### 2.6 日志不应同时写 stderr 与 syslog

`log()` 原先既 `echo >&2`（便于命令行观察）又调用 `logger`（写入 syslog）。由 procd
启动时，stderr 会被一并转入 syslog 且优先级恒为 `err`，结果是每条消息重复出现两次，
且 info 级消息被误标为错误。

解决办法是让 init 脚本通过 `procd_set_param env QLIT_UNDER_PROCD=1` 告知程序，
`log()` 在该变量存在时跳过 stderr 回显；命令行手工执行时行为不变。

### 2.7 覆盖正在运行的 shell 脚本有风险

busybox ash 按文件偏移增量读取脚本。若在脚本运行期间覆盖同名文件，后续读取可能落在
错误的偏移上，执行到错乱的代码。

更新部署时应先 `/etc/init.d/qlit-netauth stop`，覆盖文件后再 `start`。
`install.sh` 不做此处理（它面向首次安装），升级时需手动先停服务。

### 2.8 在线探测不应使用状态码

`uclient-fetch` 无法输出 HTTP 状态码；且未认证时门户会将请求劫持至认证页，返回的是
HTML，既非期望的特征串也非空。按响应体特征判断在这两种情况下都能得出正确结论。
详见 README 第 3 节。

### 2.9 OpenWrt 的 ipk 是 gzip 压缩的 tar

并非 `ar` 归档。校验其中的元数据应当：

```sh
tar xzf pkg.ipk ./control.tar.gz
tar xzOf control.tar.gz ./control
```

用 `ar p` 读取会失败。已核对 19.07.10、23.05.5 及本仓库产物，三者格式一致。

### 2.10 抓包文件不得提交

`.gitignore` 已排除 `*.har`。抓包内含可直接解出的账号与密码（RC4 密钥就写在同一个
请求里，故密文等同于明文），以及姓名、邮箱等个人信息。测试用例中的账号与密码均为
虚构值。

---

## 3. 验证状态

| 项目 | 状态 |
|---|---|
| RC4 与真实抓包密文的精确比对 | 通过（开发期间完成；内置自检已改用虚构参考向量） |
| RC4 对独立 Python 实现 40/40 随机向量 | 通过 |
| 内置自检向量 | 虚构值 `example-password`，由两条独立实现交叉核对；核对真实抓包请用 `verify` |
| 核心逻辑 39 项端到端测试（模拟门户） | 通过，macOS sh 与真实 busybox ash 各一遍 |
| RC4 在真实设备 busybox awk v1.28.3 上 | 以真实抓包向量实测一致 |
| Lua 版界面 63 项测试（真机） | 通过 |
| Lua 版界面在真机浏览器渲染 | HTTP 200，元素齐全，按钮执行链路已打通 |
| JS 版界面 | 逻辑与跨文件一致性已测（30 项 + 变异验证）；缺少 21.02+ 设备，未做真实渲染验证 |
| ipk 编译与安装 | 由 GitHub Actions 编译，产物已核对架构为 `all`；未在 19.07 设备上实际执行 `opkg install` |
| 真实校园网认证 | 未进行 —— 需要真实账号密码。部署后请先执行 `selftest` |

真机验证所用设备：**京东云 AX1800 Pro（IPQ6018，aarch64），QWRT 固件**
（Lua 版 LuCI，busybox 1.28.3，curl 可用）。
