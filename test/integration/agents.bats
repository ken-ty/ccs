#!/usr/bin/env bats
#
# ccs agents — このマシンの claude を俯瞰する
#
# **`ccs ls` には混ぜない。** あちらの行が kill / gc の対象と一致していることが
# いまの安全性の根拠なので、管轄外を混ぜると人の判断も `ccs ls --json | jq` 系も
# 他人のセッションを巻き込む方向に倒れる。ここで見張るのは「別の表であること」と
# 「管轄外だと読めること」の 2 つ。

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
	ccs_stop_outsiders
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

_new() {
	mkdir -p "${CCS_TEST_TMP}/work/$1"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/$1"
	[ "$status" -eq 0 ]
}

_U='00000000-0000-4000-8000-00000000000%d'

@test "agents: 管轄下と管轄外の両方が出る" {
	_new mine
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 1)" >/dev/null

	run --separate-stderr "$CCS_BIN" agents
	[ "$status" -eq 0 ]
	[[ "$output" == *"mine"* ]] || return 1
	[[ "$output" == *"work/outside"* ]] || return 1
}

@test "agents: 管轄外は SLUG が - になる" {
	# **打てる宛先が無いことを、列そのもので表す。** 名乗っている name を
	# SLUG 欄に置くと、打てない文字列が打てる位置に座る。
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 2)" 'まぎらわしい 名前' >/dev/null

	run --separate-stderr "$CCS_BIN" agents
	[ "$status" -eq 0 ]
	[[ "$output" == *"-"*"work/outside"* ]] || return 1
	# name は SLUG 欄に出さない。
	[[ "$output" != *"まぎらわしい"* ]] || return 1
}

@test "agents: 上半分が ccs ls と行単位で一致する" {
	# **2 つの表の関係が、説明なしで読めること。**
	_new mine
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 3)" >/dev/null

	run --separate-stderr "$CCS_BIN" ls
	local _ls=$output
	run --separate-stderr "$CCS_BIN" agents
	local _ag=$output

	local _n
	_n=$(printf '%s\n' "$_ls" | wc -l | tr -d ' ')
	[ "$(printf '%s\n' "$_ag" | head -n "$_n")" = "$_ls" ]
	# 管轄外の 1 行ぶんだけ長い。
	[ "$(printf '%s\n' "$_ag" | wc -l | tr -d ' ')" -eq "$((_n + 1))" ]
}

@test "agents --json: 管轄外は slug も tmux も null" {
	# **`slug: null` が「打てる宛先が無い」の signal。** ccb はここで絞る。
	_new mine
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 4)" >/dev/null

	run --separate-stderr "$CCS_BIN" agents --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq '[.[] | select(.slug == null)] | length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == null) | .tmux')" = 'null' ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == null) | .sessionId')" = "$(printf "$_U" 4)" ]
	# 管轄下の行は今までどおり。
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == "mine") | .tmux')" = 'cc/mine' ]
}

@test "ls --json: 管轄外は 1 件も出ない（混ぜない）" {
	_new mine
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 5)" >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq 'length')" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].slug')" = 'mine' ]
}

@test "agents: status が取れなければ - を置く" {
	# **無いことを無いまま出す。** 実測 2026-08-30、アプリ由来のセッションには
	# status キーそのものが無かった。
	export FAKE_CLAUDE_NO_STATUS=1
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 6)" >/dev/null

	run --separate-stderr "$CCS_BIN" agents --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == null) | .status')" = '-' ]
}

@test "agents: レジストリの残骸は出さない" {
	# **死んだ pid の項目を「生きている」と読まない**（registry_is_live）。
	printf '{"pid":%d,"sessionId":"%s","cwd":"%s","name":"ghost","status":"idle"}\n' \
		999999 "$(printf "$_U" 7)" "${CCS_TEST_TMP}/ghost" \
		>"${CCS_SESSIONS_DIR}/999999.json"

	run --separate-stderr "$CCS_BIN" agents --json
	[ "$status" -eq 0 ]
	[[ "$output" != *"ghost"* ]] || return 1
	[ "$(printf '%s' "$output" | jq 'length')" -eq 0 ]
}

@test "agents -l: 盤面の列も管轄外の行で埋まる" {
	# **`ls_board_rows` は slug を見ない**（cwd と sessionId から会話ログを
	# 引くだけ）ので、管轄外の行もそのまま通る。
	export FAKE_CLAUDE_TRANSCRIPT=1
	ccs_start_outsider "${CCS_TEST_TMP}/work/outside" "$(printf "$_U" 8)" >/dev/null

	run --separate-stderr "$CCS_BIN" agents -l --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == null) | .pid')" != 'null' ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug == null) | .updatedAt')" != 'null' ]
}

@test "agents: 何も動いていなければその旨を出す" {
	run --separate-stderr "$CCS_BIN" agents
	[ "$status" -eq 0 ]
	[[ "$output" == *"動いている claude はありません"* ]] || return 1
}
