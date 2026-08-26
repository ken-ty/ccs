#!/usr/bin/env bats
#
# 見張り — テストのプロセスが消えたら、そのテストが作ったものを片付ける。
#
# **bats の teardown は呼ばれないことがある**（SIGINT / SIGKILL。test_helper の
# 表を参照）。tmux サーバは端末から切り離された常駐プロセスなので、teardown
# だけに頼ると、Ctrl-C ひとつで何日も生き残る ── 実際に丸 1 日残った。
#
# **自分自身は殺せない**ので、見張りの持ち主とサンドボックスを引数で渡して試す。
# 本番と同じ関数を、同じ引数の形で呼んでいる。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox

	# 見張りに watch させる「別のテスト」を模した使い捨て。
	CCS_FAKE_SANDBOX="${CCS_TEST_TMP}/fake-sandbox"
	mkdir -p "$CCS_FAKE_SANDBOX"
	CCS_FAKE_SOCK="${CCS_FAKE_SANDBOX}/tmux.sock"
}

teardown() {
	[ -S "${CCS_FAKE_SOCK:-}" ] &&
		"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" kill-server 2>/dev/null
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

# 持ち主役のプロセス。止めたいときに kill できるもの。
_start_owner() {
	sleep 120 &
	CCS_OWNER_PID=$!
	# ジョブ表から外す。残すと bash が「Terminated」をテストの出力に混ぜる。
	disown 2>/dev/null || true
}

_fake_server_alive() {
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" list-sessions >/dev/null 2>&1
}

@test "見張り: 持ち主が消えたら tmux サーバを畳む" {
	_start_owner
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" new-session -d -s x 'sleep 120'
	_fake_server_alive

	ccs_watch_sandbox "$CCS_OWNER_PID" "$CCS_FAKE_SANDBOX"

	# teardown は一切走らない ── 見張りだけで畳めることを見る。
	kill -9 "$CCS_OWNER_PID"
	ccs_wait_until 10 bash -c "! '${CCS_REAL_TMUX:-tmux}' -S '$CCS_FAKE_SOCK' list-sessions >/dev/null 2>&1"
	! _fake_server_alive
}

@test "見張り: サンドボックスごと消す" {
	_start_owner
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" new-session -d -s x 'sleep 120'
	printf 'leftover\n' >"${CCS_FAKE_SANDBOX}/junk"

	ccs_watch_sandbox "$CCS_OWNER_PID" "$CCS_FAKE_SANDBOX"

	kill -9 "$CCS_OWNER_PID"
	ccs_wait_until 10 bash -c "[ ! -d '$CCS_FAKE_SANDBOX' ]"
	[ ! -d "$CCS_FAKE_SANDBOX" ]
}

@test "見張り: サーバを先に畳む（ディレクトリを消してもプロセスは死なない）" {
	# **これが 1 日生き残った理由そのもの。** rm -rf はソケットのファイルを
	# 消すだけで、常駐しているサーバには何も起きない。順序を逆にすると、
	# 消えたソケットを握ったプロセスが残り、名指しで畳むことすらできなくなる。
	_start_owner
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" new-session -d -s x 'sleep 120'
	_pid=$("${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" display-message -p '#{pid}')

	ccs_watch_sandbox "$CCS_OWNER_PID" "$CCS_FAKE_SANDBOX"

	kill -9 "$CCS_OWNER_PID"
	ccs_wait_until 10 bash -c "! kill -0 $_pid 2>/dev/null"
	# サーバのプロセスそのものが消えていること。
	! kill -0 "$_pid" 2>/dev/null
}

@test "見張り: 持ち主が生きている間は何もしない" {
	_start_owner
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" new-session -d -s x 'sleep 120'

	ccs_watch_sandbox "$CCS_OWNER_PID" "$CCS_FAKE_SANDBOX"

	sleep 3
	_fake_server_alive
	[ -d "$CCS_FAKE_SANDBOX" ]
	kill "$CCS_OWNER_PID" 2>/dev/null || true
}

@test "見張り: SIGINT を無視する（Ctrl-C はプロセスグループ全体に届く）" {
	# 見張りが Ctrl-C の巻き添えで死ぬと、Ctrl-C のときだけ効かない
	# ── いちばん効いてほしい場面で効かない見張りになる。
	_start_owner
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_FAKE_SOCK" new-session -d -s x 'sleep 120'

	ccs_watch_sandbox "$CCS_OWNER_PID" "$CCS_FAKE_SANDBOX"
	_watch=$!

	kill -INT "$_watch" 2>/dev/null || true
	sleep 1
	kill -0 "$_watch" 2>/dev/null # SIGINT では死んでいない

	kill -9 "$CCS_OWNER_PID"
	ccs_wait_until 10 bash -c "! '${CCS_REAL_TMUX:-tmux}' -S '$CCS_FAKE_SOCK' list-sessions >/dev/null 2>&1"
	! _fake_server_alive
}
