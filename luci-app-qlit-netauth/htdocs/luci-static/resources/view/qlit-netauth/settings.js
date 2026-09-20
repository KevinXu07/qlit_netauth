'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require poll';

var PROG = '/usr/bin/qlit-netauth';

function trim(s) {
	return (s || '').replace(/^\s+|\s+$/g, '');
}

/* 将命令输出或错误信息显示于弹窗中 */
function showResult(title, text) {
	return ui.showModal(title, [
		E('pre', {
			'style': 'white-space:pre-wrap; word-break:break-all; ' +
			         'max-height:60vh; overflow:auto; margin:0 0 1em 0'
		}, trim(text) || _('（无输出）')),
		E('div', { 'class': 'right' },
			E('button', { 'type': 'button', 'class': 'btn', 'click': ui.hideModal },
				_('关闭')))
	], 'cbi-modal');
}

return view.extend({
	/* ------------------------------------------------------------- 加载状态 */

	/* 取回初始状态供首屏直接渲染，避免先显示「检测中」再发生跳变。
	 * 返回 true / false 表示是否在线，null 表示获取失败（通常为 ACL 未生效）。 */
	load: function() {
		return Promise.all([
			uci.load('qlit-netauth'),
			fs.exec(PROG, [ 'status' ]).then(function(res) {
				return trim(res.stdout) === 'online';
			}).catch(function() {
				return null;
			})
		]);
	},

	/* ------------------------------------------------------------- 操作命令 */

	/* 执行 qlit-netauth 的子命令并展示结果。
	 * 注意 fs.exec() 在退出码非 0 时不会 reject，退出码位于 res.code；
	 * 而 `qlit-netauth status` 在离线时恰好返回 1，故判断失败必须依据
	 * res.code，不能依赖 catch。 */
	runCommand: function(args, title) {
		ui.showModal(title, [
			E('p', { 'class': 'spinning' }, _('执行中…'))
		], 'cbi-modal');

		return fs.exec(PROG, args).then(function(res) {
			var parts = [];
			if (trim(res.stdout))
				parts.push(trim(res.stdout));
			if (trim(res.stderr))
				parts.push(trim(res.stderr));
			if (res.code)
				parts.push(_('退出码') + ': ' + res.code);
			return showResult(title, parts.join('\n\n'));
		}).catch(function(err) {
			return showResult(title, _('执行失败') + ': ' +
				(err && err.message ? err.message : err));
		});
	},

	handleCheck: function() {
		return this.runCommand([ 'check' ], _('立即认证'))
			.then(L.bind(this.refreshStatus, this));
	},

	handleLogout: function() {
		return this.runCommand([ 'logout' ], _('注销下线'))
			.then(L.bind(this.refreshStatus, this));
	},

	handleSelftest: function() {
		return this.runCommand([ 'selftest' ], _('自检'));
	},

	/* --------------------------------------------------------------- 状态栏 */

	setStatusNode: function(node, online) {
		if (online === true) {
			node.className = 'label success';
			node.textContent = _('在线');
		}
		else if (online === false) {
			node.className = 'label danger';
			node.textContent = _('离线');
		}
		else {
			node.className = 'label warning';
			node.textContent = _('状态未知');
		}
	},

	refreshStatus: function() {
		var node = this.statusNode;

		/* 视图已切换时不再发起请求 */
		if (!node || !node.isConnected)
			return Promise.resolve();

		return fs.exec(PROG, [ 'status' ]).then(L.bind(function(res) {
			this.setStatusNode(node, trim(res.stdout) === 'online');
		}, this)).catch(L.bind(function() {
			this.setStatusNode(node, null);
		}, this));
	},

	/* --------------------------------------------------------------- 渲染 */

	render: function(data) {
		var m, s, o;

		m = new form.Map('qlit-netauth', _('QLIT认证'),
			_('由路由器完成校园网 Portal 认证，其下所有设备均无需单独登录。'));

		s = m.section(form.NamedSection, 'settings', 'qlit-netauth', _('设置'));
		s.addremove = false;
		s.tab('basic', _('账号'));
		s.tab('advanced', _('高级'));

		o = s.taboption('basic', form.Flag, 'enabled', _('启用自动认证'));
		o.default = '0';
		o.rmempty = false;
		o.description = _('关闭后守护进程不会运行，网络将不再自动认证。');

		o = s.taboption('basic', form.Value, 'username', _('账号'));
		o.placeholder = 'your-account';
		o.rmempty = false;
		o.description = _('校园网账号（学号）。');

		o = s.taboption('basic', form.Value, 'password', _('密码'));
		o.password = true;
		o.rmempty = false;
		o.description = _('以明文填写即可，发送前由路由器完成 RC4 加密，不会以明文发出。');

		o = s.taboption('basic', form.Value, 'portal', _('认证门户'));
		o.default = '10.2.2.82';
		o.placeholder = '10.2.2.82';
		o.rmempty = false;
		o.description = _('通常无需修改，也可写成 http://10.2.2.82。');

		o = s.taboption('advanced', form.Value, 'interval', _('在线探测间隔'));
		o.default = '60';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('单位：秒。在线状态下按此间隔检查，掉线后最多经过该时长被发现。');

		o = s.taboption('advanced', form.Value, 'retry_interval', _('失败重试间隔'));
		o.default = '15';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('单位：秒。认证失败后经过该时长重试。');

		o = s.taboption('advanced', form.Value, 'timeout', _('请求超时'));
		o.default = '8';
		o.datatype = 'uinteger';
		o.rmempty = false;
		o.description = _('单位：秒。单次 HTTP 请求的超时时间。');

		o = s.taboption('advanced', form.Value, 'probe', _('在线探测地址'));
		o.rmempty = false;
		o.description = _('以空格分隔，每条格式为 <code>URL|特征串</code>：' +
			'<code>=文本</code> 表示响应体须恰好等于该文本；<code>=</code> 表示响应体须为空' +
			'（HTTP 204，仅当已安装 curl 时生效）；直接写文本表示响应体须包含该文本。' +
			'任意一条匹配即判定为在线。若日志中持续出现反复认证，表明所列地址在本网络下均不可达，' +
			'请替换为本网络内可访问的地址。');

		o = s.taboption('advanced', form.Value, 'bind_interface', _('出口接口'));
		o.placeholder = _('留空表示走默认路由');
		o.description = _('多 WAN 或策略路由环境下，指定认证流量的出口接口（如 eth1）。' +
			'仅 curl 支持该选项。');

		o = s.taboption('advanced', form.ListValue, 'log_level', _('日志级别'));
		o.value('error', _('仅错误'));
		o.value('warn', _('警告'));
		o.value('info', _('普通'));
		o.value('debug', _('调试'));
		o.default = 'info';
		o.rmempty = false;
		o.description = _('日志可通过 <code>logread -e qlit-netauth</code> 查看。');

		/* --- 状态与操作面板（独立于 UCI 表单，以避免写入多余的配置项） --- */
		this.statusNode = E('span', { 'class': 'label' }, _('检测中…'));
		this.setStatusNode(this.statusNode, data[1]);

		var panel = E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, _('服务状态')),
			E('div', { 'style': 'margin-bottom:1em' }, [
				E('strong', {}, _('当前状态') + '：'), ' ',
				this.statusNode,
				E('span', { 'style': 'margin-left:1em; opacity:0.7' },
					_('（每 5 秒自动刷新）'))
			]),
			E('div', { 'class': 'cbi-page-actions', 'style': 'text-align:left; margin:0' }, [
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-action',
					'click': ui.createHandlerFn(this, 'handleCheck')
				}, _('立即认证')), ' ',
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleLogout')
				}, _('注销下线')), ' ',
				E('button', {
					'type': 'button',
					'class': 'btn cbi-button',
					'click': ui.createHandlerFn(this, 'handleSelftest')
				}, _('自检'))
			]),
			E('div', { 'class': 'cbi-section-descr' },
				_('「自检」以抓包中记录的真实数据校验路由器上的加密实现是否正确。' +
				  '若报告 RC4 不一致，程序将拒绝登录（以免以错误的密码反复尝试），' +
				  '请先解决该问题再启用。'))
		]);

		return m.render().then(L.bind(function(mapNode) {
			poll.add(L.bind(this.refreshStatus, this), 5);
			return E([], [ panel, mapNode ]);
		}, this));
	}
});
