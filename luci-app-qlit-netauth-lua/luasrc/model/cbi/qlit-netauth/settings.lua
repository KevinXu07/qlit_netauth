-- QLIT认证 —— LuCI 配置界面（Lua CBI）
--
-- 适用于 19.07 系的 Lua 版 LuCI（含 QWRT 等第三方固件）。
-- 21.02 及以上的 JS 版 LuCI 请使用同仓库的 luci-app-qlit-netauth。
--
-- 设计上的两个要点：
--   1. 状态显示读取守护进程写入的缓存文件，而非在此执行 `qlit-netauth status`。
--      后者需进行真实的网络探测（最多 3 个地址 × 超时），可能使页面阻塞二十余秒。
--   2. 按钮不写入 UCI 选项，仅执行命令并将输出写入临时文件，再由下方的
--      DummyValue 进行渲染，因此无需向配置中写入无意义的字段。

local fs   = require "nixio.fs"
local sys  = require "luci.sys"
local http = require "luci.http"
local disp = require "luci.dispatcher"
local util = require "luci.util"

local PROG  = "/usr/bin/qlit-netauth"
local STATE = "/var/run/qlit-netauth.state"
local OUT   = "/tmp/qlit-netauth-ui.out"

m = Map("qlit-netauth", translate("QLIT认证"),
	translate("由路由器完成校园网 Portal 认证，其下所有设备均无需单独登录。"))

-- 按钮执行完毕后返回本页，同时使页面重新读取一次状态
m.redirect = disp.build_url("admin", "services", "qlit-netauth")

s = m:section(NamedSection, "settings", "qlit-netauth")
s.addremove = false
s:tab("status",   translate("状态"))
s:tab("basic",    translate("账号"))
s:tab("advanced", translate("高级"))

-- ===================== 状态 =====================

sv = s:taboption("status", DummyValue, "_status", translate("当前状态"))
sv.rawhtml = true
function sv.cfgvalue(self, section)
	-- 注意不可写作 local st, ts = raw and raw:match(...)：
	-- Lua 中 and/or 这类表达式仅保留一个返回值，ts 将恒为 nil，
	-- 致使 age 退化为 os.time()，界面上显示为一串时间戳。
	local raw = fs.readfile(STATE) or ""
	local st, ts = raw:match("^(%S+)%s+(%d+)")

	if not st or st == "unknown" then
		return "<em>" .. translate("暂无状态，守护进程可能未运行。") .. "</em>"
	end

	local text, color
	if st == "online" then
		text, color = translate("在线"), "#2e7d32"
	else
		text, color = translate("离线"), "#c62828"
	end

	local age = os.time() - (tonumber(ts) or 0)
	return string.format(
		'<strong style="color:%s;font-size:1.1em">%s</strong> <span style="opacity:.7">(%s)</span>',
		color, text, translatef("最近检测于 %d 秒前", age))
end

-- 三个操作按钮。inputstyle 仅可使用 CSS 中已定义的类：
-- add / apply / down / download / edit / find / link / reload / remove / reset / save / up
local function action(name, title, args, style, desc)
	local b = s:taboption("status", Button, name, title)
	b.inputtitle = title
	b.inputstyle = style
	b.description = desc
	function b.write(self, section)
		-- sys.call 走 /bin/sh，重定向可用（已在本机型实测）
		sys.call(string.format("%s %s > %s 2>&1", PROG, args, OUT))
		http.redirect(m.redirect)
	end
	return b
end

action("_act_check", translate("立即认证"), "check", "apply",
	translate("执行一次探测，未认证时进行登录。"))
action("_act_logout", translate("注销下线"), "logout", "reset",
	translate("主动下线。下一次探测将重新认证，故通常仅在排查问题时使用。"))
action("_act_selftest", translate("自检"), "selftest", "reload",
	translate("以抓包中记录的真实数据校验路由器上的加密实现。若报告 RC4 不一致，"
		.. "程序将拒绝登录，请先解决该问题。"))

ov = s:taboption("status", DummyValue, "_output", translate("上次操作输出"))
ov.rawhtml = true
function ov.cfgvalue(self, section)
	local out = fs.readfile(OUT)
	if not out or out == "" then
		return "<em>" .. translate("（无）") .. "</em>"
	end
	return '<pre style="white-space:pre-wrap;word-break:break-all;'
		.. 'max-height:20em;overflow:auto;margin:0">' .. util.pcdata(out) .. "</pre>"
end

-- ===================== 账号 =====================

o = s:taboption("basic", Flag, "enabled", translate("启用自动认证"))
o.default = "0"
o.rmempty = false
o.description = translate("关闭后守护进程不会运行，网络将不再自动认证。")

o = s:taboption("basic", Value, "username", translate("账号"))
o.rmempty = false
o.description = translate("校园网账号（学号）。")

o = s:taboption("basic", Value, "password", translate("密码"))
o.password = true
o.rmempty = false
o.description = translate("以明文填写即可，发送前由路由器完成 RC4 加密，不会以明文发出。")

o = s:taboption("basic", Value, "portal", translate("认证门户"))
o.default = "10.2.2.82"
o.rmempty = false
o.description = translate("通常无需修改。")

-- ===================== 高级 =====================

o = s:taboption("advanced", Value, "interval", translate("在线探测间隔"))
o.default = "60"
o.datatype = "uinteger"
o.rmempty = false
o.description = translate("单位：秒。在线状态下按此间隔检查，掉线后最多经过该时长被发现。")

o = s:taboption("advanced", Value, "retry_interval", translate("失败重试间隔"))
o.default = "15"
o.datatype = "uinteger"
o.rmempty = false
o.description = translate("单位：秒。认证失败后经过该时长重试。")

o = s:taboption("advanced", Value, "timeout", translate("请求超时"))
o.default = "8"
o.datatype = "uinteger"
o.rmempty = false
o.description = translate("单位：秒。单次 HTTP 请求的超时时间。")

o = s:taboption("advanced", Value, "probe", translate("在线探测地址"))
o.rmempty = false
o.description = translate("以空格分隔，每条格式为 URL|特征串：=文本 表示响应体须恰好等于该文本；"
	.. "= 表示响应体须为空（HTTP 204，仅当已安装 curl 时生效）；直接写文本表示响应体须包含该文本。"
	.. "任意一条匹配即判定为在线。若日志中持续出现反复认证，表明所列地址在本网络下均不可达，"
	.. "请替换为本网络内可访问的地址。")

o = s:taboption("advanced", Value, "bind_interface", translate("出口接口"))
o.rmempty = true
o.description = translate("多 WAN 或策略路由环境下，指定认证流量的出口接口（如 eth3）。"
	.. "留空表示使用默认路由。仅 curl 支持该选项。")

o = s:taboption("advanced", ListValue, "log_level", translate("日志级别"))
o:value("error", translate("仅错误"))
o:value("warn",  translate("警告"))
o:value("info",  translate("普通"))
o:value("debug", translate("调试"))
o.default = "info"
o.rmempty = false
o.description = translate("日志可通过 logread -e qlit-netauth 查看。")

return m
