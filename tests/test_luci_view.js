#!/usr/bin/env node
/*
 * LuCI 视图的静态一致性测试。
 *
 * 用一套最小的 LuCI 运行时替身真正执行 view/qlit-netauth/settings.js，
 * 然后检查它和周边文件是否对得上 —— 这类跨文件错位（选项名拼错、
 * 菜单指向不存在的视图、ACL 漏授权）不会报错，只会表现为「界面点了没反应」
 * 或者「设置了不生效」，最难查。
 *
 * 检查项:
 *   1. 视图能被加载、load() 和 render() 都能跑通
 *   2. 视图里每个 UCI 选项名都真实存在于 files/etc/config/qlit-netauth
 *   3. 每个选项都带 description（界面可读性）
 *   4. menu.d 的 action.path 指向真实存在的视图文件
 *   5. acl.d 给视图里用到的那个可执行文件授了 exec 权限
 *   6. acl.d 给视图加载的 uci 配置授了读写权限
 *
 * 用法: node tests/test_luci_view.js
 */
'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..');
const VIEW_REL = 'luci-app-qlit-netauth/htdocs/luci-static/resources/view/qlit-netauth/settings.js';
const MENU_REL = 'luci-app-qlit-netauth/root/usr/share/luci/menu.d/luci-app-qlit-netauth.json';
const ACL_REL = 'luci-app-qlit-netauth/root/usr/share/rpcd/acl.d/luci-app-qlit-netauth.json';
const UCI_REL = 'files/etc/config/qlit-netauth';

let passed = 0, failed = 0;

function ok(msg) { console.log('  \x1b[32mPASS\x1b[0m ' + msg); passed++; }
function bad(msg, detail) {
	console.log('  \x1b[31mFAIL\x1b[0m ' + msg + (detail ? ' —— ' + detail : ''));
	failed++;
}
function section(t) { console.log('\n\x1b[1m== ' + t + '\x1b[0m'); }
function check(cond, msg, detail) { cond ? ok(msg) : bad(msg, detail); }

/* ======================= 最小 LuCI 运行时替身 ======================= */

const rec = { options: [], tabs: [], sections: [], exec: [], poll: null,
              modals: [], required: [] };

function makeOption(type, name) {
	const o = { __type: type, __name: name, __values: [] };
	o.value = function (v, l) { o.__values.push([v, l]); return o; };
	return o;
}

function makeMap() { return {}; }

const stubForm = {
	Map: function (config, title, desc) {
		rec.map = { config, title, desc };
		this.section = function (ctor, ...args) {
			const s = {
				__ctor: ctor && ctor.__name__,
				__args: args,
				__options: [],
				tab: function (name, title) { rec.tabs.push({ name, title }); },
				option: function (type, name, title) {
					const o = makeOption(type && type.__name__, name);
					o.tab = null; o.title = title;
					rec.options.push(o);   /* 存引用，不拷贝：视图随后才设 description 等属性 */
					s.__options.push(o);
					return o;
				},
				taboption: function (tab, type, name, title) {
					const o = makeOption(type && type.__name__, name);
					o.tab = tab; o.title = title;
					rec.options.push(o);
					s.__options.push(o);
					return o;
				}
			};
			rec.sections.push(s);
			return s;
		};
		this.render = function () {
			return Promise.resolve({ __node: 'map', children: [] });
		};
	}
};
for (const n of [ 'NamedSection', 'TypedSection', 'Flag', 'Value', 'ListValue',
                  'Button', 'DynamicList', 'MultiValue' ])
	stubForm[n] = { __name__: n };

const modules = {
	view: { extend: def => def },
	form: stubForm,
	uci: { load: cfg => { rec.uciLoaded = cfg; return Promise.resolve(); } },
	fs: {
		exec: (cmd, args) => {
			rec.exec.push([ cmd, args ]);
			/* 模拟离线：退出码 1，但 ubus 调用本身是成功的 */
			return Promise.resolve({ code: 1, stdout: 'offline\n', stderr: '' });
		}
	},
	ui: {
		showModal: (title, content, cls) => { rec.modals.push({ title, cls }); return Promise.resolve(); },
		hideModal: () => {},
		createHandlerFn: (self, fn, ...args) => (...callArgs) => self[fn](...callArgs)
	},
	poll: { add: (fn, iv) => { rec.poll = { fn, interval: iv }; } }
};

function requireStub(name) {
	rec.required.push(name);
	if (!(name in modules)) throw new Error('未知模块: ' + name);
	return modules[name];
}

/* E / _ / L 在 LuCI 里是真正的全局（官方 15 个视图里有 8 个直接用裸 E(...)
 * 而没有 require dom），所以这里也挂到全局。 */
global._ = s => s;
global.L = { bind: (fn, self, ...args) => fn.bind(self, ...args) };
function isNodeLike(v) {
	return v !== null && typeof v === 'object' && typeof v.tag !== 'undefined';
}
function isAttrsObject(v) {
	return v !== null && typeof v === 'object' && !Array.isArray(v) && !isNodeLike(v);
}
global.E = function (html, attr, data) {
	let attrs = {}, children;
	if (arguments.length >= 2) {
		if (isAttrsObject(attr)) { attrs = attr; children = data; }
		else { children = attr; }        /* create(html, data) 形式 */
	}
	else {
		children = undefined;
	}
	return { tag: html, attrs: attrs, children: children };
};

/* 复现 LuCI 的模块加载方式：扫描源码里的 'require xxx' 指令，把对应模块
 * 作为参数注入，最终等价于
 *     (function(window, document, L, view, form, ...) { <源码> })
 * 见 luci.js 里 LuCI.prototype.require 的实现。 */
function loadLuCIView(src, requireFn) {
	const requirematch = /^require[ \t]+(\S+)(?:[ \t]+as[ \t]+([a-zA-Z_]\S*))?$/;
	const strictmatch = /^use[ \t]+strict$/;
	const depends = [];
	let args = '';

	for (let i = 0, off = -1, prev = -1, quote = -1, comment = -1, esc = false;
	     i < src.length; i++) {
		const chr = src.charCodeAt(i);

		if (esc) esc = false;
		else if (comment != -1) {
			if ((comment == 47 && chr == 10) || (comment == 42 && prev == 42 && chr == 47))
				comment = -1;
		}
		else if ((chr == 42 || chr == 47) && prev == 47) comment = chr;
		else if (chr == 92) esc = true;
		else if (chr == quote) {
			const s = src.substring(off, i), m = requirematch.exec(s);
			if (m) {
				const dep = m[1], as = m[2] || dep.replace(/[^a-zA-Z0-9_]/g, '_');
				depends.push(requireFn(dep));
				args += ', ' + as;
			}
			else if (!strictmatch.exec(s)) {
				break;   /* 遇到普通字符串，说明指令区结束 */
			}
			off = -1;
			quote = -1;
		}
		else if (quote == -1 && (chr == 34 || chr == 39)) {
			off = i + 1;
			quote = chr;
		}

		prev = chr;
	}

	const factory = new Function('window', 'document', 'L' + args, src);
	return factory.apply(factory, [ {}, {}, global.L ].concat(depends));
}

/* 把节点树里所有按钮文案收集起来，用于断言操作按钮存在 */
function collectButtons(node, out) {
	out = out || [];
	if (!node || typeof node !== 'object') return out;
	if (node.tag === 'button') out.push(node.children);
	if (Array.isArray(node.children)) node.children.forEach(c => collectButtons(c, out));
	else if (node.children && typeof node.children === 'object') collectButtons(node.children, out);
	return out;
}

/* ============================== 开始测试 ============================== */

async function main() {
	const viewPath = path.join(ROOT, VIEW_REL);

	section('1. 视图可加载并渲染');
	let view;
	try {
		const src = fs.readFileSync(viewPath, 'utf8');
		view = loadLuCIView(src, requireStub);
		ok('视图模块加载成功（按 LuCI 的方式注入 require 的模块）');
	} catch (e) {
		bad('视图模块加载失败', e.message);
		return finish();
	}

	let data, tree;
	try {
		data = await view.load();
		ok('load() 执行成功');
	} catch (e) {
		bad('load() 抛异常', e.message);
	}

	try {
		tree = await view.render(data);
		ok('render() 执行成功');
	} catch (e) {
		bad('render() 抛异常', e.message);
		return finish();
	}

	ok('视图声明的依赖: ' + rec.required.join(', '));
	for (const need of [ 'view', 'form', 'uci', 'fs', 'ui', 'poll' ])
		check(rec.required.includes(need), '依赖了 ' + need + ' 模块',
			'实际: ' + rec.required.join(', '));

	check(rec.uciLoaded === 'qlit-netauth', 'load() 读取的 uci 配置是 qlit-netauth',
		'实际: ' + rec.uciLoaded);
	check(rec.poll && rec.poll.interval === 5, '注册了 5 秒轮询',
		rec.poll ? '实际: ' + rec.poll.interval : '未注册 poll');

	/* ===================== 2. 选项名与 UCI 配置对照 ===================== */
	section('2. 界面选项 与 UCI 配置文件 对照');

	const uciSrc = fs.readFileSync(path.join(ROOT, UCI_REL), 'utf8');
	const uciOpts = new Set();
	let secType = null, secName = null;
	for (const line of uciSrc.split('\n')) {
		const m1 = line.match(/^\s*config\s+(\S+)\s*(?:'([^']*)'|(\S+))?/);
		if (m1) { secType = m1[1]; secName = m1[2] || m1[3]; continue; }
		const m2 = line.match(/^\s*option\s+(\S+)/);
		if (m2) uciOpts.add(m2[1]);
	}

	check(secType === 'qlit-netauth', 'UCI 段类型是 qlit-netauth',
		'实际: ' + secType);
	check(secName === 'settings', 'UCI 段名是 settings（视图按此名映射）',
		'实际: ' + secName);
	check(rec.sections.length > 0 && rec.sections[0].__ctor === 'NamedSection' &&
		rec.sections[0].__args[0] === 'settings' && rec.sections[0].__args[1] === 'qlit-netauth',
		'视图用 NamedSection 映射到 settings/qlit-netauth',
		rec.sections[0] ? '实际: ' + JSON.stringify(rec.sections[0].__args) : '无 section');

	const names = rec.options.map(o => o.__name);
	const badNames = names.filter(n => !uciOpts.has(n));
	check(badNames.length === 0, '所有选项名都存在于 UCI 配置中',
		badNames.length ? '配置里没有: ' + badNames.join(', ') : '');
	ok('界面暴露的选项 (' + names.length + '): ' + names.join(', '));

	const noDesc = rec.options.filter(o => !o.description).map(o => o.__name);
	check(noDesc.length === 0, '每个选项都有说明文字',
		noDesc.length ? '缺说明: ' + noDesc.join(', ') : '');

	const pw = rec.options.find(o => o.__name === 'password');
	check(pw && pw.password === true, '密码字段以密码框渲染（不回显明文）');

	const lv = rec.options.find(o => o.__name === 'log_level');
	check(lv && lv.__values.length === 4, '日志级别是下拉选择且选项齐全',
		lv ? '实际 ' + lv.__values.length + ' 项' : '');

	check(rec.tabs.length === 2, '表单分了 2 个标签页',
		'实际: ' + rec.tabs.map(t => t.name).join(','));

	/* ===================== 3. 菜单指向的视图存在 ===================== */
	section('3. 菜单 / ACL 交叉检查');

	const menu = JSON.parse(fs.readFileSync(path.join(ROOT, MENU_REL), 'utf8'));
	const menuKey = Object.keys(menu)[0];
	const action = menu[menuKey].action;
	check(action.type === 'view', '菜单项是 view 类型', '实际: ' + action.type);
	const expectedView = 'luci-app-qlit-netauth/htdocs/luci-static/resources/view/' +
		action.path + '.js';
	check(fs.existsSync(path.join(ROOT, expectedView)),
		'菜单 path "' + action.path + '" 指向真实存在的视图文件', expectedView);
	check(menu[menuKey].depends && menu[menuKey].depends.uci &&
		Object.keys(menu[menuKey].depends.uci)[0] === 'qlit-netauth',
		'菜单依赖 qlit-netauth 这个 uci 配置（未安装时不显示）');

	const acl = JSON.parse(fs.readFileSync(path.join(ROOT, ACL_REL), 'utf8'));
	const aclName = Object.keys(acl)[0];
	const aclBody = acl[aclName];
	check(aclName === 'luci-app-qlit-netauth',
		'ACL 键名与菜单里引用的 acl 名一致', aclName);

	/* 视图实际用到的可执行文件必须被授权 exec */
	const progPaths = new Set(rec.exec.map(e => e[0]));
	const execAllowed = Object.keys((aclBody.read.file) || {});
	for (const p of progPaths) {
		const hit = execAllowed.some(a => a === p);
		check(hit, '视图执行 ' + p + ' 已被 ACL 授权 exec',
			'ACL 里的 exec 条目: ' + execAllowed.join(', ') || '(无)');
	}

	const uciAcl = (aclBody.read.uci || []).concat(aclBody.write.uci || []);
	check(uciAcl.includes('qlit-netauth'),
		'ACL 授权读写 uci 配置 qlit-netauth', '实际: ' + uciAcl.join(', '));

	/* ===================== 4. 操作按钮齐全 ===================== */
	section('4. 操作按钮');
	const buttons = collectButtons(tree).map(b => String(b));
	for (const want of [ '立即认证', '注销下线', '自检' ])
		check(buttons.includes(want), '存在「' + want + '」按钮',
			'实际按钮: ' + buttons.join(', '));

	finish();
}

function finish() {
	console.log('\n\x1b[1m== 结果: ' + passed + ' 通过, ' + failed + ' 失败 \x1b[0m');
	process.exit(failed === 0 ? 0 : 1);
}

main().catch(e => { console.error('测试自身出错:', e); process.exit(1); });
