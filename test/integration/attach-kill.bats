#!/usr/bin/env bats
#
# ccs attach / ccs kill
#
# attach は端末を乗っ取るので、本物を実行するとテストが固まる。
# tmux を「引数を記録するだけのもの」に差し替えて、何を呼んだかを見る。
# kill は副作用が実際に起きてほしいので、本物の tmux で確かめる。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

_new() {
	mkdir -p "${CCS_TEST_TMP}/work/$1"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/$1"
	[ "$status" -eq 0 ]
	echo "$output"
}

# tmux を「引数をログに書くだけ」に差し替える。
# has-session だけは本当のことを答えないと分岐が試せないので、
# 記録用の一覧ファイルを見る。
_stub_tmux_recorder() {
	printf '%s\n' "$@" >"${CCS_TEST_TMP}/existing-sessions.txt"
	{
		echo '#!/bin/sh'
		echo "echo \"\$@\" >>'${CCS_TEST_TMP}/tmux.log'"
		echo 'case "$1" in'
		echo 'has-session)'
		echo "  grep -qx \"\${3#=}\" '${CCS_TEST_TMP}/existing-sessions.txt' && exit 0"
		echo '  exit 1 ;;'
		echo 'list-sessions)'
		echo "  cat '${CCS_TEST_TMP}/existing-sessions.txt' ;;"
		echo 'esac'
		echo 'exit 0'
	} >"${CCS_STUB_BIN}/tmux-recorder"
	chmod +x "${CCS_STUB_BIN}/tmux-recorder"
	export CCS_TMUX_BIN="${CCS_STUB_BIN}/tmux-recorder"
}

# --- attach ----------------------------------------------------------------

@test "attach: tmux の外なら attach-session を呼ぶ" {
	_stub_tmux_recorder 'cc/myrepo'
	run env -u TMUX "$CCS_BIN" attach myrepo
	[ "$status" -eq 0 ]

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" == *"attach-session -t cc/myrepo"* ]] || return 1
}

@test "attach: tmux の中なら switch-client を呼ぶ" {
	# 入れ子の attach は tmux が拒む。ハブが tmux の中で動いていることは
	# 十分ありうるので、ここを間違えると「ハブから乗り込めない」になる。
	_stub_tmux_recorder 'cc/myrepo'
	run env TMUX='/tmp/fake,123,0' "$CCS_BIN" attach myrepo
	[ "$status" -eq 0 ]

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" == *"switch-client -t cc/myrepo"* ]] || return 1
	[[ "$output" != *"attach-session"* ]] || return 1
}

@test "attach: 無い slug なら候補を出して落ちる" {
	_new myrepo >/dev/null
	_new other >/dev/null

	run "$CCS_BIN" attach nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"ありません"* ]] || return 1
	[[ "$output" == *"myrepo"* ]] || return 1
	[[ "$output" == *"other"* ]] || return 1
}

@test "attach: 何も立っていなければ立て方を出す" {
	run "$CCS_BIN" attach nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs new"* ]] || return 1
}

@test "attach: slug が無ければ 2" {
	run "$CCS_BIN" attach
	[ "$status" -eq 2 ]
}

# --- kill ------------------------------------------------------------------

@test "kill: tmux セッションを畳む" {
	_new myrepo >/dev/null
	ccs_tmux has-session -t '=cc/myrepo'

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill: 復帰用の uuid と cd 先を出す" {
	# **v1 に resume が無いので、これが同じ会話に戻る唯一の手掛かり。**
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
	[[ "$output" == *"myrepo"* ]] || return 1
}

@test "kill: claude が終了していても uuid を出す" {
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of myrepo

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
}

@test "kill: 作業中なら畳まない" {
	# ハブのエージェントが打ち間違えることを想定する。会話は transcript に
	# 残るが、走っていたコマンドの途中経過は戻らない。
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 1 ]
	[[ "$output" == *"作業中"* ]] || return 1
	[[ "$output" == *"--force"* ]] || return 1

	ccs_tmux has-session -t '=cc/myrepo'
}

@test "kill --force: 作業中でも畳む" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill --force myrepo
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill -f: 短い形も効く" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill -f myrepo
	[ "$status" -eq 0 ]
}

@test "kill: idle なら --force なしで畳める" {
	_new myrepo >/dev/null
	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
}

@test "kill: 他のセッションを巻き込まない" {
	_new keep >/dev/null
	_new drop >/dev/null

	run "$CCS_BIN" kill drop
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/keep'
	run ccs_tmux has-session -t '=cc/drop'
	[ "$status" -ne 0 ]
}

@test "kill: 似た名前を巻き込まない" {
	_new x01 >/dev/null
	_new x011 >/dev/null

	run "$CCS_BIN" kill x01
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/x011'
}

@test "kill: 無い slug なら候補を出して落ちる" {
	_new myrepo >/dev/null

	run "$CCS_BIN" kill nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"myrepo"* ]] || return 1
}

@test "kill: slug が無ければ 2" {
	run "$CCS_BIN" kill
	[ "$status" -eq 2 ]
}

@test "kill: slug が 2 つあれば 2" {
	run "$CCS_BIN" kill a b
	[ "$status" -eq 2 ]
}

@test "kill: 知らないオプションは 2" {
	run "$CCS_BIN" kill --nope myrepo
	[ "$status" -eq 2 ]
}

# --- 畳んだあと ------------------------------------------------------------

@test "kill したものは ls から消える" {
	_new keep >/dev/null
	_new drop >/dev/null

	run "$CCS_BIN" kill drop
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'keep' ]
}

@test "kill して立て直すと新しいセッションになる" {
	_out=$(_new myrepo)
	_first=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]

	_out2=$(_new myrepo)
	[ "$(echo "$_out2" | jq -r '.created')" = 'true' ]
	[ "$(echo "$_out2" | jq -r '.sessionId')" != "$_first" ]
}

@test "kill tmp-N で作業枠が空く" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]

	run "$CCS_BIN" kill tmp-1
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
}
