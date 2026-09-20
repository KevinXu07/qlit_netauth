-- QLIT认证 —— LuCI 控制器
--
-- 适用于 19.07 系的 Lua 版 LuCI（含 QWRT 等第三方固件）。
-- 21.02 及以上的 JS 版 LuCI 请使用同仓库的 luci-app-qlit-netauth。
module("luci.controller.qlit-netauth", package.seeall)

function index()
	-- 此处必须使用全局 nixio，不可写作模块级的 local fs = require "nixio.fs"。
	--
	-- LuCI 会把每个控制器的 index() 用 string.dump 编译为字节码存入
	-- /tmp/luci-indexcache（缓存内容为 loadstring("LuaQ\000...")），
	-- 而字节码不保留 upvalue：模块级 local 被 index() 捕获为 upvalue 后，
	-- 自缓存取出时即为 nil，其后果是整棵菜单树构建失败、全站返回 500：
	--     attempt to index upvalue 'fs' (a nil value)
	--
	-- 全局名字在运行时沿环境链解析（控制器的 env -> luci.dispatcher ->
	-- package.seeall 提供的 _G），不受字节码序列化影响。官方应用
	-- （如 luci-app-arpbind）均采用此写法。
	if not nixio.fs.access("/etc/config/qlit-netauth") then
		return
	end

	entry({"admin", "services", "qlit-netauth"},
		cbi("qlit-netauth/settings"),
		_("QLIT认证"), 30).dependent = true
end
