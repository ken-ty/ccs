#!/usr/bin/env bats
#
# test/reap-tmux — 前回の実行が取り残したサンドボックスを回収する。
#
# **これが壊れても、テストは全部通る。** 黙って何も片付けなくなるだけなので、
# 「畳む」と「触らない」の両方を実際の tmux サーバで見る。
#
# `BATS_TMPDIR` を差し替えて隔離する ── ここで `kill-server` を撃つので、
# 本物のサンドボックス置き場を見に行くと、同時に走っている他セッションの
# テストを巻き添えにしかねない。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox

	# **/tmp の下に短い名前で作る。** Unix ドメインソケットのパスには
	# 100 バイト程度の上限があり、macOS の $TMPDIR (/var/folders/…/T) の
	# 下にもう 1 段掘ると足が出る。
	CCS_REAP_ROOT="$(mktemp -d /tmp/ccs-reap.XXXXXX)"
	CCS_REAP="${CCS_REPO_ROOT}/test/reap-tmux"
}

teardown() {
	if [ -d "${CCS_REAP_ROOT:-}" ]; then
		for _sb in "$CCS_REAP_ROOT"/*; do
			[ -S "${_sb}/tmux.sock" ] || continue
			"${CCS_REAL_TMUX:-tmux}" -S "${_sb}/tmux.sock" kill-server 2>/dev/null || true
		done
		rm -rf "$CCS_REAP_ROOT"
	fi
	ccs_teardown_sandbox
}

# 隔離した置き場に、持ち主 <pid> のサンドボックスを 1 つ作る。
# pid を省くと owner.pid を書かない（この仕組みより前の残骸を模す）。
_make_sandbox() {
	_sb="$(mktemp -d "${CCS_REAP_ROOT}/ccs-test.XXXXXX")"
	[ -n "${1:-}" ] && printf '%s\n' "$1" >"${_sb}/owner.pid"
	printf '%s' "$_sb"
}

_start_server() {
	"${CCS_REAL_TMUX:-tmux}" -S "${1}/tmux.sock" new-session -d -s x 'sleep 120'
}

_server_alive() {
	"${CCS_REAL_TMUX:-tmux}" -S "${1}/tmux.sock" list-sessions >/dev/null 2>&1
}

_dead_pid() {
	sh -c 'exit 0' &
	local _p=$!
	wait "$_p" 2>/dev/null || true
	printf '%s' "$_p"
}

_reap() {
	BATS_TMPDIR="$CCS_REAP_ROOT" run "$CCS_REAP" "$@"
}

# --- 畳む -------------------------------------------------------------------

@test "reap: 持ち主が居なくなったサーバを畳んでサンドボックスごと消す" {
	_sb=$(_make_sandbox "$(_dead_pid)")
	_start_server "$_sb"
	_server_alive "$_sb"

	_reap
	[ "$status" -eq 0 ]
	[[ "$output" == *"畳んだサーバ 1"* ]] || return 1

	! _server_alive "$_sb"
	[ ! -d "$_sb" ]
}

@test "reap: サーバの居ないサンドボックスも消す" {
	_sb=$(_make_sandbox "$(_dead_pid)")

	_reap
	[ "$status" -eq 0 ]
	[ ! -d "$_sb" ]
}

@test "reap: サーバのプロセスそのものを終わらせる" {
	# ディレクトリを消してもプロセスは死なない ── そこを取り違えると、
	# 「消したのに残っている」という、いちばん追いにくい状態になる。
	_sb=$(_make_sandbox "$(_dead_pid)")
	_start_server "$_sb"
	_pid=$("${CCS_REAL_TMUX:-tmux}" -S "${_sb}/tmux.sock" display-message -p '#{pid}')

	_reap
	[ "$status" -eq 0 ]
	ccs_wait_until 5 bash -c "! kill -0 $_pid 2>/dev/null"
	! kill -0 "$_pid" 2>/dev/null
}

# --- 触らない ---------------------------------------------------------------

@test "reap: 走っているテストのものには触らない" {
	# **ここが本体。** 同じマシンで複数のセッションが同時にテストを回すのは
	# 日常なので、生きている持ち主のものを消すと他人のテストを壊す。
	_sb=$(_make_sandbox "$$")
	_start_server "$_sb"

	_reap
	[ "$status" -eq 0 ]
	[[ "$output" == *"見送り 1"* ]] || return 1

	_server_alive "$_sb"
	[ -d "$_sb" ]
}

@test "reap: 素性の分からない新しいサンドボックスには触らない" {
	# owner.pid を書く前の数マイクロ秒に見に来た可能性がある。消すと
	# 走っているテストを壊すので、十分に古くなるまで待つ。
	_sb=$(_make_sandbox)

	_reap
	[ "$status" -eq 0 ]
	[[ "$output" == *"見送り 1"* ]] || return 1
	[ -d "$_sb" ]
}

@test "reap: 素性の分からない古いサンドボックスは消す" {
	# この仕組みより前の残骸。60 分より古ければ、走っているテストではありえない。
	_sb=$(_make_sandbox)
	touch -t "$(date -v-2H '+%Y%m%d%H%M')" "$_sb"

	_reap
	[ "$status" -eq 0 ]
	[ ! -d "$_sb" ]
}

@test "reap: ccs-test.* 以外には触らない" {
	_other="${CCS_REAP_ROOT}/bats-run-XXXX"
	mkdir -p "$_other"

	_reap
	[ "$status" -eq 0 ]
	[ -d "$_other" ]
}

# --- 出力 -------------------------------------------------------------------

@test "reap --quiet: 何も片付けなければ黙る" {
	_reap --quiet
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "reap --quiet: 片付けたら報告する" {
	# 黙って片付けると「前回どこかで異常終了した」ことに気づけない。
	_sb=$(_make_sandbox "$(_dead_pid)")
	_start_server "$_sb"

	_reap --quiet
	[ "$status" -eq 0 ]
	[[ "$output" == *"畳んだサーバ 1"* ]] || return 1
}
