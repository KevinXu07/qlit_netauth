#!/bin/sh
# =============================================================================
#  qlit-netauth 端到端测试
#
#  用一个模拟门户（tests/mock_portal.py）代替真实校园网。模拟门户会像真门户
#  那样用收到的 auth_tag 当 RC4 密钥解密 pwd 再比对密码，因此能真正验证
#  客户端的加密、请求格式和状态机是否正确。
#
#  用法: sh tests/run_tests.sh
# =============================================================================

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# QLIT_PROG 可指向另一份被测脚本，例如换成用 busybox ash 解释的副本，
# 以验证脚本在路由器实际使用的 shell 下也能跑
PROG=${QLIT_PROG:-$ROOT/files/usr/bin/qlit-netauth}

USERNAME='testuser'
PASSWORD='test-password-1'
# 与抓包无关的另一个密码，用于验证密码确实是被真正加密后传输的
PASSWORD2='P@ss w0rd&x=1+2'

PORT=${QLIT_TEST_PORT:-18099}
WORK=$(mktemp -d)
CFG="$WORK/test.conf"
LOGIN_LOG="$WORK/logins.jsonl"
MOCK_PID=''
PASSED=0
FAILED=0

cleanup() {
	[ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
	rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAILED=$((FAILED + 1)); }

check_eq() { # 名称 实际 期望
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 —— 期望 '$3'，实际 '$2'"; fi
}

section() { printf '\n\033[1m== %s\033[0m\n' "$1"; }

# ---- 启停模拟门户 -----------------------------------------------------------
start_mock() { # $1=期望密码
	[ -n "$MOCK_PID" ] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }
	python3 "$HERE/mock_portal.py" "$PORT" "$1" "$LOGIN_LOG" "$USERNAME" \
		>"$WORK/mock.out" 2>&1 &
	MOCK_PID=$!
	_i=0
	while [ "$_i" -lt 50 ]; do
		curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$PORT/__state" && return 0
		_i=$((_i + 1))
		sleep 0.1
	done
	echo "模拟门户启动失败:" >&2
	cat "$WORK/mock.out" >&2
	exit 1
}

write_cfg() { # $1=密码
	cat > "$CFG" <<EOF
username='$USERNAME'
password='$1'
portal='127.0.0.1:$PORT'
interval='2'
retry_interval='1'
timeout='5'
probe='http://127.0.0.1:$PORT/success.txt|=success'
log_level='debug'
EOF
}

run() { # 运行被测脚本，丢弃 stderr 中的日志噪音
	"$PROG" -c "$CFG" "$@" 2>"$WORK/stderr.log"
}

mock_login_count() {
	curl -s --max-time 5 "http://127.0.0.1:$PORT/__state" |
		python3 -c 'import json,sys; print(json.load(sys.stdin)["login_count"])'
}

mock_last_login() {
	python3 - "$LOGIN_LOG" <<'EOF'
import json, sys
lines = [l for l in open(sys.argv[1]) if l.strip()]
print(json.dumps(json.loads(lines[-1]), ensure_ascii=False) if lines else '{}')
EOF
}

mock_field() { # $1=字段名
	mock_last_login | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1',''))"
}

# =============================================================================
section "1. 自检（RC4 参考向量 / 时间戳 / URL 编码）与 verify 子命令"
# =============================================================================
write_cfg "$PASSWORD"
start_mock "$PASSWORD"

_out=$("$PROG" -c "$CFG" selftest 2>&1)
echo "$_out" | sed 's/^/     /'
case "$_out" in
	*FAIL*) fail "selftest 报告了 FAIL" ;;
	*)      pass "selftest 全部通过" ;;
esac
case "$_out" in
	*"RC4 与参考向量一致"*) pass "RC4 与内置参考向量一致" ;;
	*)                      fail "RC4 参考向量校验未通过" ;;
esac

# verify 子命令：用于拿自己的抓包数据核对本机实现
if "$PROG" -c "$CFG" verify example-password 1700000000000 \
     6dd4f823a554faf3c5e62d27b5983c91 >/dev/null 2>&1; then
	pass "verify 对正确的向量返回 0"
else
	fail "verify 对正确的向量却返回非 0"
fi
if "$PROG" -c "$CFG" verify example-password 1700000000000 deadbeef >/dev/null 2>&1; then
	fail "verify 对错误的向量却返回 0（校验形同虚设）"
else
	pass "verify 对错误的向量返回非 0"
fi
if "$PROG" -c "$CFG" verify >/dev/null 2>&1; then
	fail "verify 缺参数时未报错"
else
	pass "verify 缺参数时返回非 0"
fi

# =============================================================================
section "2. 离线探测 → 认证 → 在线"
# =============================================================================
check_eq "初始状态为 offline" "$(run status)" "offline"

run check >/dev/null
check_eq "check 后状态变为 online" "$(run status)" "online"

check_eq "门户收到了 1 次登录请求" "$(mock_login_count)" "1"
check_eq "门户解密出的密码与配置一致" "$(mock_field pwd_plain)" "$PASSWORD"
check_eq "门户收到的用户名正确" "$(mock_field userName)" "$USERNAME"
check_eq "auth_tag 为 13 位毫秒时间戳" "$(mock_field auth_tag | grep -cE '^[0-9]{13}$')" "1"
check_eq "密文长度为明文的 2 倍（hex 编码）" "$(mock_field pwd_hexlen_ok)" "True"

# 密文里不该出现明文
if mock_field pwd_cipher | grep -q "$PASSWORD"; then
	fail "请求里出现了明文密码"
else
	pass "请求中不含明文密码（rc4hex 长度为 $(mock_field pwd_cipher | wc -c | tr -d ' ')）"
fi

# =============================================================================
section "3. 已在线时不重复认证"
# =============================================================================
run check >/dev/null
check_eq "再次 check 未产生新的登录请求" "$(mock_login_count)" "1"
check_eq "状态仍为 online" "$(run status)" "online"

# =============================================================================
section "4. 强制登录接口"
# =============================================================================
run login >/dev/null
check_eq "login 强制产生了一次新请求" "$(mock_login_count)" "2"

# =============================================================================
section "5. 注销"
# =============================================================================
run logout >/dev/null
check_eq "注销后状态为 offline" "$(run status)" "offline"

# =============================================================================
section "6. 账号密码错误时应报失败而不是假装成功"
# =============================================================================
start_mock 'a-totally-different-password'
write_cfg "$PASSWORD"
run check >/dev/null
_rc=$?
# run() 每次都覆写 stderr.log，先把这次失败运行的日志单独留一份再往下走
cp "$WORK/stderr.log" "$WORK/check.err"
if [ "$_rc" -ne 0 ]; then
	pass "密码错误时 check 返回非 0（rc=${_rc}）"
else
	fail "密码错误时 check 却返回了 0"
fi
check_eq "错误密码下状态仍为 offline" "$(run status)" "offline"
if grep -q "认证失败" "$WORK/check.err"; then
	pass "日志中报告了认证失败"
else
	fail "日志中没有认证失败信息"
fi

# =============================================================================
section "7. 含特殊字符的密码（验证 URL 编码与加密链路）"
# =============================================================================
start_mock "$PASSWORD2"
write_cfg "$PASSWORD2"
run check >/dev/null
check_eq "特殊字符密码认证后为 online" "$(run status)" "online"
check_eq "门户解密出的密码正确" "$(mock_field pwd_plain)" "$PASSWORD2"

# =============================================================================
section "8. daemon 常驻模式"
# =============================================================================
start_mock "$PASSWORD"
write_cfg "$PASSWORD"
"$PROG" -c "$CFG" daemon >"$WORK/daemon.out" 2>&1 &
DAEMON_PID=$!
sleep 3
_daemon_alive=0
kill -0 "$DAEMON_PID" 2>/dev/null && _daemon_alive=1
check_eq "daemon 进程存活" "$_daemon_alive" "1"
check_eq "daemon 完成了认证" "$(mock_login_count)" "1"
_online=0
[ "$(run status)" = "online" ] && _online=1
check_eq "daemon 运行期间网络为 online" "$_online" "1"

# SIGTERM 应能立即退出（不必等满一个 interval）
_t0=$(date +%s)
kill -TERM "$DAEMON_PID" 2>/dev/null
wait "$DAEMON_PID" 2>/dev/null
_t1=$(date +%s)
kill -0 "$DAEMON_PID" 2>/dev/null && fail "daemon 收到 SIGTERM 后仍在运行" || pass "daemon 响应 SIGTERM 并退出"
if [ $((_t1 - _t0)) -le 2 ]; then
	pass "SIGTERM 后 $((_t1 - _t0))s 内退出（未等满 interval）"
else
	fail "SIGTERM 后退出耗时 $((_t1 - _t0))s，可能没响应信号"
fi

# =============================================================================
section "9. 探测地址不可达时的容错"
# =============================================================================
start_mock "$PASSWORD"
cat > "$CFG" <<EOF
username='$USERNAME'
password='$PASSWORD'
portal='127.0.0.1:$PORT'
interval='2'
retry_interval='1'
timeout='3'
probe='http://127.0.0.1:1/nope|=success'
log_level='debug'
EOF
run check >/dev/null
check_eq "探测不可达时仍尝试登录且成功" "$(mock_login_count)" "1"

# =============================================================================
section "10. probe 配置写错时不应静默失效"
# =============================================================================
start_mock "$PASSWORD"
cat > "$CFG" <<EOF
username='$USERNAME'
password='$PASSWORD'
portal='127.0.0.1:$PORT'
interval='2'
retry_interval='1'
timeout='3'
probe='http://127.0.0.1:$PORT/success.txt'
log_level='debug'
EOF
run status >/dev/null
if grep -q "缺少 '|' 分隔符" "$WORK/stderr.log"; then
	pass "缺少 | 的 probe 条目被识别并告警"
else
	fail "缺少 | 的 probe 条目没有被识别出来"
fi
check_eq "该条目被跳过后判定为离线（只会多认证，不会漏认证）" "$(run status)" "offline"

# =============================================================================
section "11. 状态缓存（LuCI 界面读它，避免页面卡在网络探测上）"
# =============================================================================
export QLIT_STATE_FILE="$WORK/state"
start_mock "$PASSWORD"
write_cfg "$PASSWORD"
rm -f "$QLIT_STATE_FILE"

check_eq "尚无缓存时为 unknown" "$(run state | cut -d' ' -f1)" "unknown"

run check >/dev/null
check_eq "check 后缓存写入 online" "$(run state | cut -d' ' -f1)" "online"
check_eq "缓存带 unix 时间戳" "$(run state | cut -d' ' -f2 | grep -cE '^[0-9]{9,}$')" "1"

# 注意：logout 之后 check 会重新认证成功、缓存正确地变成 online，
# 所以要测出 offline 必须让认证失败 —— 换一个门户不认的密码。
start_mock 'a-totally-different-password'
write_cfg "$PASSWORD"
run check >/dev/null
check_eq "认证失败后缓存变为 offline" "$(run state | cut -d' ' -f1)" "offline"

# state 命令本身不能发网络请求（否则界面又会被拖慢）—— 用不可达的地址验证它立刻返回
cat > "$CFG" <<EOF
username='$USERNAME'
password='$PASSWORD'
portal='127.0.0.1:$PORT'
timeout='3'
probe='http://127.0.0.1:1/nope|=success'
log_level='debug'
EOF
_t0=$(date +%s)
run state >/dev/null
_t1=$(date +%s)
check_eq "state 命令不依赖网络（耗时 $((_t1 - _t0))s）" "$((_t1 - _t0))" "0"
unset QLIT_STATE_FILE

# =============================================================================
section "12. 标记中含空格的探测条目（默认配置里就有一条如此）"
# =============================================================================
# 条目以空白分隔，但 MARKER 本身可能含空格，如 "=Microsoft Connect Test"。
# 早期版本按空白直接切分，会把这一条拆成三段，其中两段缺 | 分隔符，
# 于是每个探测周期都往 syslog 打两条警告。此处固化该场景。
start_mock "$PASSWORD"
cat > "$CFG" <<EOF
username='$USERNAME'
password='$PASSWORD'
portal='127.0.0.1:$PORT'
interval='2'
retry_interval='1'
timeout='5'
probe='http://127.0.0.1:$PORT/connecttest.txt|=Microsoft Connect Test http://127.0.0.1:$PORT/success.txt|=success'
log_level='debug'
EOF

check_eq "含空格的标记使条目数按 2 计" \
	"$(run selftest 2>/dev/null | grep -o 'probe 条目数=[0-9]*' | cut -d= -f2)" "2"

run check >/dev/null
cp "$WORK/stderr.log" "$WORK/space.err"
check_eq "认证后判定为在线" "$(run status)" "online"

if grep -q "缺少 '|' 分隔符" "$WORK/space.err"; then
	fail "含空格的标记被错误切分并产生了分隔符警告"
	grep "缺少 '|' 分隔符" "$WORK/space.err" | head -3 | sed 's/^/         /'
else
	pass "含空格的标记未被误切分（无分隔符警告）"
fi

# 真正缺少 | 的条目仍须告警，避免把上一条修复做成"什么都不报"
cat > "$CFG" <<EOF
username='$USERNAME'
password='$PASSWORD'
portal='127.0.0.1:$PORT'
timeout='3'
probe='http://127.0.0.1:$PORT/success.txt'
log_level='debug'
EOF
run status >/dev/null
if grep -q "缺少 '|' 分隔符" "$WORK/stderr.log"; then
	pass "确实缺少 | 的条目仍然告警"
else
	fail "缺少 | 的条目不再告警了（校验被削弱）"
fi

# =============================================================================
printf '\n\033[1m== 结果: %d 通过, %d 失败 ==\033[0m\n' "$PASSED" "$FAILED"
[ "$FAILED" -eq 0 ] || exit 1
