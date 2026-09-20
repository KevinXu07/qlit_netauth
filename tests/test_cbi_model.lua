#!/usr/bin/env lua
--
-- LuCI (Lua CBI) 界面的静态一致性测试。
--
-- 无需 HTTP 请求上下文，也不必把界面装进系统目录 —— 直接加载 CBI 模型，
-- 检查它构建出的表单结构，并与核心包的 UCI 配置文件交叉核对。
--
-- 这类跨文件错位（选项名拼错、该用 Flag 的用了 Value、密码框忘了设 password、
-- 按钮少了 inputtitle 导致渲染成文本框）在 LuCI 里都不会报错，只会表现为
-- 「界面不对」或「设置了不生效」，最难查。
--
-- 用法（在路由器上执行）:
--     lua tests/test_cbi_model.lua <settings.lua 路径> [uci 配置文件路径]
--
-- 例:
--     lua tests/test_cbi_model.lua /tmp/luiapp/model/cbi/qlit-netauth/settings.lua \
--         /tmp/qlit-netauth.config
--
-- 只能跑在装了 LuCI 的设备上（需要 luci.cbi / luci.i18n）。本机（macOS）没有
-- LuCI，所以这个测试是部署到路由器后才跑的。

-- 模型里 require 的这两个模块需要 HTTP 请求上下文，命令行下不存在，
-- 换成桩。其余（luci.sys / luci.util / nixio.fs）用真实实现。
package.loaded["luci.http"] = { redirect = function() end, write = function() end }
package.loaded["luci.dispatcher"] = {
	build_url = function(...) return "/cgi-bin/luci/" .. table.concat({ ... }, "/") end
}

local cbi  = require "luci.cbi"
local i18n = require "luci.i18n"

local MODEL_PATH = arg[1]
local UCI_PATH   = arg[2]

if not MODEL_PATH then
	io.stderr:write("用法: lua test_cbi_model.lua <settings.lua> [uci 配置文件]\n")
	os.exit(2)
end

local passed, failed = 0, 0

local function ok(msg)   print("  PASS " .. msg) passed = passed + 1 end
local function bad(msg, detail)
	print("  FAIL " .. msg .. (detail and (" —— " .. detail) or ""))
	failed = failed + 1
end
local function section(t) print("\n== " .. t .. " ==") end
local function check(cond, msg, detail) if cond then ok(msg) else bad(msg, detail) end end

-- ============ 记录每个选项用的是哪个控件类 ============
-- CBI 的构造签名是 <Class>(map, section, option_name, ...)，所以第 3 个参数是选项名。
local widget_of = {}
local function wrap(name)
	local orig = cbi[name]
	if type(orig) ~= "table" then return end
	-- 替身必须仍然是 AbstractValue 的后代：CBI 在 s:option() 里会做
	-- is_a(类, AbstractValue) 检查，用普通表替换会直接报
	-- "class must be a descendant of AbstractValue"。
	local wrapper = { __base = orig }
	cbi[name] = setmetatable(wrapper, {
		__call = function(_, ...)
			local opt = select(3, ...)
			if type(opt) == "string" then widget_of[opt] = name end
			return orig(...)
		end,
		__index = orig,
	})
end
for _, n in ipairs({ "Flag", "Value", "ListValue", "Button", "DummyValue" }) do
	wrap(n)
end

-- ============ 加载模型 ============
section("1. 模型可加载并构建")

local chunk, lerr = loadfile(MODEL_PATH)
if not chunk then
	bad("loadfile 失败", tostring(lerr))
	print("\n== 结果: " .. passed .. " 通过, " .. failed .. " 失败 ==")
	os.exit(1)
end
ok("模型文件语法正确")

local env = { translate = i18n.translate, translatef = i18n.translatef, arg = {} }
setmetatable(env, { __index = function(t, k)
	return rawget(t, k) or cbi[k] or _G[k]
end })
setfenv(chunk, env)

local pok, m = pcall(chunk)
if not pok then
	bad("模型执行抛异常", tostring(m))
	print("\n== 结果: " .. passed .. " 通过, " .. failed .. " 失败 ==")
	os.exit(1)
end
ok("模型执行成功")

check(type(m) == "table", "返回了 map 对象（cbi.load 要求必须返回）",
	"实际类型: " .. type(m))
if type(m) ~= "table" then
	print("\n== 结果: " .. passed .. " 通过, " .. failed .. " 失败 ==")
	os.exit(1)
end

check(m.title and m.title ~= "", "map 有标题", tostring(m.title))
check(m.redirect and m.redirect ~= "", "设置了保存后跳转地址，按钮执行完能回到本页")

-- ============ 段与标签页 ============
section("2. 段与标签页")

local s = (m.children or {})[1]
check(s ~= nil, "存在一个 section")
check(#(m.children or {}) == 1, "只有 1 个 section（避免多个 section 写同一个 UCI 段）",
	"实际: " .. tostring(#(m.children or {})))

if s then
	check(s.section == "settings", string.format("section 段名是 settings（实际 %q）", tostring(s.section)),
		"实际: " .. tostring(s.section))
	check(s.sectiontype == "qlit-netauth", "section 段类型是 qlit-netauth",
		"实际: " .. tostring(s.sectiontype))
	check(s.addremove == false, "addremove 为 false（单例配置，不允许增删）")

	local tabs = {}
	for k in pairs(s.tabs or {}) do tabs[#tabs + 1] = k end
	table.sort(tabs)
	check(#tabs == 3, "有 3 个标签页", "实际: " .. table.concat(tabs, ", "))
	check(tabs[1] == "advanced" and tabs[2] == "basic" and tabs[3] == "status",
		"标签页为 status / basic / advanced", table.concat(tabs, ", "))
end

-- ============ 选项与 UCI 配置文件交叉核对 ============
section("3. 选项 与 UCI 配置文件 交叉核对")

local opt_names = {}
for _, o in ipairs((s and s.children) or {}) do
	if o.option then opt_names[#opt_names + 1] = o.option end
end
table.sort(opt_names)
ok("界面暴露的选项 (" .. #opt_names .. "): " .. table.concat(opt_names, ", "))

-- 带下划线前缀的是按钮/只读展示用的伪选项，不该出现在 UCI 里
local uci_opts = {}
if UCI_PATH and io.open(UCI_PATH, "r") then
	local fh = io.open(UCI_PATH, "r")
	local sectype, secname
	for line in fh:lines() do
		local t, n = line:match("^%s*config%s+(%S+)%s*'?([%w_%-]*)'?")
		if t then sectype, secname = t, n end
		local o = line:match("^%s*option%s+(%S+)")
		if o then uci_opts[o] = true end
	end
	fh:close()

	check(sectype == "qlit-netauth", "配置文件里的段类型是 qlit-netauth",
		"实际: " .. tostring(sectype))
	check(secname == "settings", "配置文件里的段名是 settings（与模型映射的一致）",
		"实际: " .. tostring(secname))

	-- 允许为空的选项（rmempty）在 LuCI 保存时会因值为空而被删除，这是 LuCI 的
	-- 正常行为，不算缺失；只有必填项不在配置里才是真问题。
	local missing, optional_absent = {}, {}
	for _, o in ipairs((s and s.children) or {}) do
		local name = o.option
		if name and name:sub(1, 1) ~= "_" and not uci_opts[name] then
			if o.rmempty == true then
				optional_absent[#optional_absent + 1] = name
			else
				missing[#missing + 1] = name
			end
		end
	end
	table.sort(missing)
	table.sort(optional_absent)
	check(#missing == 0, "所有必填的界面选项都存在于 UCI 配置文件中",
		#missing > 0 and ("配置里没有: " .. table.concat(missing, ", ")) or nil)
	if #optional_absent > 0 then
		ok("以下允许为空的选项当前不在配置中（LuCI 保存时删除了空值）: " ..
			table.concat(optional_absent, ", "))
	end

	-- 反向：配置文件里有没有界面上改不到的选项
	local notexposed = {}
	for o in pairs(uci_opts) do
		local found = false
		for _, n in ipairs(opt_names) do if n == o then found = true end end
		if not found then notexposed[#notexposed + 1] = o end
	end
	table.sort(notexposed)
	check(#notexposed == 0, "配置文件里没有界面上改不到的选项",
		#notexposed > 0 and ("界面缺: " .. table.concat(notexposed, ", ")) or nil)
else
	ok("跳过交叉核对（未提供可读的 UCI 配置文件: " .. tostring(UCI_PATH) .. "）")
end

-- ============ 控件类型 ============
section("4. 控件类型是否正确")

local expect_widget = {
	enabled        = "Flag",
	username       = "Value",
	password       = "Value",
	portal         = "Value",
	interval       = "Value",
	retry_interval = "Value",
	timeout        = "Value",
	probe          = "Value",
	bind_interface = "Value",
	log_level      = "ListValue",
	_act_check     = "Button",
	_act_logout    = "Button",
	_act_selftest  = "Button",
	_status        = "DummyValue",
	_output        = "DummyValue",
}
for name, want in pairs(expect_widget) do
	check(widget_of[name] == want,
		string.format("%-16s 是 %s", name, want),
		"实际: " .. tostring(widget_of[name]))
end

-- ============ 渲染相关的关键属性 ============
section("5. 渲染属性")

local by_name = {}
for _, o in ipairs((s and s.children) or {}) do
	if o.option then by_name[o.option] = o end
end

check(by_name.password and by_name.password.password == true,
	"密码字段以密码框渲染（不回显明文）")

check(by_name._status and by_name._status.rawhtml == true,
	"状态用 rawhtml 渲染（否则颜色标记会被转义成文本）")
check(by_name._output and by_name._output.rawhtml == true,
	"命令输出用 rawhtml 渲染")

local buttons = { "_act_check", "_act_logout", "_act_selftest" }
for _, b in ipairs(buttons) do
	local o = by_name[b]
	check(o and o.inputtitle and o.inputtitle ~= "",
		b .. " 设置了 inputtitle（否则按钮没有文字）")
	local valid = { add = 1, apply = 1, down = 1, download = 1, edit = 1, find = 1,
	                link = 1, reload = 1, remove = 1, reset = 1, save = 1, up = 1 }
	check(o and o.inputstyle and valid[o.inputstyle] == 1,
		b .. " 的 inputstyle 是主题里存在的样式",
		"实际: " .. tostring(o and o.inputstyle))
end

local lv = by_name.log_level
check(lv and lv.keylist and #lv.keylist == 4,
	"日志级别是下拉框且有 4 个选项",
	lv and lv.keylist and ("实际 " .. #lv.keylist .. " 个") or "取不到 keylist")

-- 数值型选项要有 datatype，否则用户能填进非数字导致守护进程行为异常
for _, n in ipairs({ "interval", "retry_interval", "timeout" }) do
	local o = by_name[n]
	check(o and o.datatype == "uinteger", n .. " 声明了 datatype=uinteger")
end

-- 必填项不能被 rmempty 掉，否则清空后配置项直接消失
for _, n in ipairs({ "username", "password", "portal", "interval", "probe", "log_level" }) do
	local o = by_name[n]
	check(o and o.rmempty == false, n .. " 设了 rmempty=false（清空后仍保留该项）")
end

-- ============ 状态渲染（功能测试） ============
-- 真正调用 cfgvalue 并检查渲染结果。上面那些静态检查抓不到
-- "时间戳被当成秒数显示" 这类逻辑错误，只有真跑一遍才行。
section("6. 状态渲染")

local STATE = "/var/run/qlit-netauth.state"
local OUT_PATH = "/tmp/qlit-netauth-ui.out"

-- 这两个是运行期文件：状态文件由守护进程持续写入。测试会覆盖它们，
-- 因此先备份，测试结束（或中途出错）后恢复，避免破坏线上状态。
local function snapshot(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local data = fh:read("*a")
	fh:close()
	return data
end
local function restore(path, data)
	if data == nil then
		os.remove(path)
		return
	end
	local fh = io.open(path, "w")
	if fh then fh:write(data); fh:close() end
end

local saved_state = snapshot(STATE)
local saved_out   = snapshot(OUT_PATH)

local function write_state(text)
	local fh = io.open(STATE, "w")
	if not fh then return false end
	fh:write(text)
	fh:close()
	return true
end

local sv = by_name._status
if not sv then
	bad("取不到 _status 控件")
elseif not write_state("online " .. (os.time() - 42) .. "\n") then
	ok("跳过状态渲染测试（无法写入 " .. STATE .. "，需要 root）")
else
	local html = sv:cfgvalue("settings") or ""
	check(html:find("在线") ~= nil, "online 状态渲染出「在线」")
	check(html:find("42 秒前") ~= nil,
		"显示的是经过的秒数（42 秒前），而不是 unix 时间戳",
		"实际: " .. (html:match("最近检测于[^)]*") or html))

	write_state("offline " .. (os.time() - 7) .. "\n")
	html = sv:cfgvalue("settings") or ""
	check(html:find("离线") ~= nil, "offline 状态渲染出「离线」")
	check(html:find("7 秒前") ~= nil, "offline 的秒数也正确",
		"实际: " .. (html:match("最近检测于[^)]*") or html))

	write_state("unknown 0\n")
	html = sv:cfgvalue("settings") or ""
	check(html:find("暂无状态") ~= nil, "状态为 unknown 时提示暂无状态")

	os.remove(STATE)
	html = sv:cfgvalue("settings") or ""
	check(html:find("暂无状态") ~= nil, "状态文件不存在时提示暂无状态（不报错）")

	-- 命令输出那一格
	local ov = by_name._output
	local OUT = "/tmp/qlit-netauth-ui.out"
	local fh = io.open(OUT, "w")
	fh:write("ok   RC4 test\n<b>不该被当成 HTML</b>\n")
	fh:close()
	html = ov:cfgvalue("settings") or ""
	check(html:find("RC4 test") ~= nil, "命令输出能显示出来")
	-- 断言的是安全属性（原始标签不能出现在页面里），而不是某种具体的转义写法：
	-- luci.util.pcdata 用的是数字实体 &#60;b&#62; 而不是命名实体 &lt;b&gt;。
	check(html:find("<b>", 1, true) == nil,
		"命令输出做了 HTML 转义（原始 <b> 不出现在页面里）",
		"实际片段: " .. tostring(html:match("<b>.-</b>") or ""))
	check(html:find("&#60;", 1, true) ~= nil or html:find("&lt;", 1, true) ~= nil,
		"转义后的实体确实出现了")
	os.remove(OUT)
	html = ov:cfgvalue("settings") or ""
	check(html:find("（无）") ~= nil, "没有输出时显示「（无）」")
end

-- 恢复运行期文件
restore(STATE, saved_state)
restore(OUT_PATH, saved_out)
ok("已恢复测试前的运行期文件（状态文件与输出文件）")

-- ============ 结果 ============
print(string.format("\n== 结果: %d 通过, %d 失败 ==", passed, failed))
os.exit(failed == 0 and 0 or 1)
