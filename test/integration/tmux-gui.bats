#!/usr/bin/env bats
#
# tmux サーバを macOS の GUI セッション（Aqua）で立てる（CCS_TMUX_GUI）。
#
# ssh から立てた tmux サーバは Background セッションで、ログインキーチェーンが
# 見えない。その子の claude が呼ぶ gh は keyring のトークンを読めず「token
# invalid」になる（2026-09-15 実測）。サーバが生まれる瞬間にしか直せないので、
# 「これから作る」場面でだけ launchd の gui ドメインに一度きりのジョブを流す。
#
# launchctl は本物を使わない。macOS でしか動かないうえ、本物を叩くと
# 「どこで走ったか」で結果が変わる。uname も Darwin を名乗らせて、Linux の CI
# でも同じ経路を通す。tmux は本物（`-S` で自分専用のサーバ）。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	ccs_stub uname 'echo Darwin'
	export CCS_TMUX_GUI=auto
	export CCS_LAUNCHCTL_BIN="${CCS_STUB_BIN}/launchctl"
	printf 'Background' >"${CCS_TEST_TMP}/managername"
	# bootstrap は、本物の launchd がするのと同じ結果（サーバが立つ）を自分で作る。
	# plist を控えて、何を焼き込んだかをテストから読めるようにする。
	ccs_stub launchctl '
printf "%s\n" "$*" >>"'"${CCS_TEST_TMP}"'/launchctl.log"
case "$1" in
managername) cat "'"${CCS_TEST_TMP}"'/managername" ;;
bootstrap)
	[ -e "'"${CCS_TEST_TMP}"'/bootstrap-fails" ] && exit 1
	cp "$3" "'"${CCS_TEST_TMP}"'/bootstrap.plist"
	"$CCS_TMUX_BIN" start-server \; set-option -s exit-empty off
	;;
esac
exit 0
'
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

launchctl_calls() {
	[ -f "${CCS_TEST_TMP}/launchctl.log" ] && cat "${CCS_TEST_TMP}/launchctl.log" || true
}

# --- 立てる場面 ------------------------------------------------------------

@test "gui: サーバが無く Background なら、launchd の gui ドメインで立ててから new-session する" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/myrepo'

	run launchctl_calls
	[[ "$output" == *"bootstrap gui/$(id -u) "*"local.ccs.tmux-bootstrap."* ]] || return 1
	[[ "$output" == *"bootout gui/$(id -u)/local.ccs.tmux-bootstrap."* ]] || return 1
}

@test "gui: plist には tmux の実パスと exit-empty off と今の PATH が焼き込まれている" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]

	_plist="${CCS_TEST_TMP}/bootstrap.plist"
	[ -f "$_plist" ]
	grep -q "<string>${CCS_TMUX_BIN}</string><string>start-server</string>" "$_plist"
	grep -q '<string>exit-empty</string><string>off</string>' "$_plist"
	grep -q '<key>PATH</key>' "$_plist"
	grep -q '<key>RunAtLoad</key><true/>' "$_plist"
	# ジョブは一度きり。KeepAlive を付けると launchd が何度も立て直す
	! grep -q 'KeepAlive' "$_plist"
}

@test "gui: サーバが立ったあとは、全部畳んでもサーバが残る（exit-empty off）" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	ccs_tmux kill-session -t '=cc/myrepo'
	# セッション 0 本でもサーバは応える
	ccs_tmux list-sessions
}

@test "gui: plist は片付けられている" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_n=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'local.ccs.tmux-bootstrap.*.plist' 2>/dev/null | wc -l)
	[ "$_n" -eq 0 ]
}

# --- 触らない場面 ----------------------------------------------------------

@test "gui: サーバが既に居れば launchctl に触らない" {
	ccs_tmux start-server \; set-option -s exit-empty off
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	run launchctl_calls
	[[ "$output" != *"bootstrap"* ]] || return 1
}

@test "gui: 自分が Aqua なら、そのまま立てる" {
	printf 'Aqua' >"${CCS_TEST_TMP}/managername"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	run launchctl_calls
	[[ "$output" != *"bootstrap"* ]] || return 1
}

@test "gui: CCS_TMUX_GUI=off なら launchctl を一切呼ばない" {
	export CCS_TMUX_GUI=off
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ ! -f "${CCS_TEST_TMP}/launchctl.log" ]
}

@test "gui: macOS 以外では何もしない" {
	ccs_stub uname 'echo Linux'
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ ! -f "${CCS_TEST_TMP}/launchctl.log" ]
}

# --- 失敗しても止めない ----------------------------------------------------

@test "gui: bootstrap に失敗したら、警告して今のセッションで立てる" {
	touch "${CCS_TEST_TMP}/bootstrap-fails"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/myrepo'
	[[ "$stderr" == *"Aqua"*"立てられませんでした"* ]] || return 1
	[[ "$stderr" == *"CCS_TMUX_GUI=off"* ]] || return 1
}

@test "gui: 設定キーとして ccs config に出る" {
	run "$CCS_BIN" config
	[[ "$output" == *"CCS_TMUX_GUI"* ]] || return 1
	[[ "$output" == *"CCS_LAUNCHCTL_BIN"* ]] || return 1
}
