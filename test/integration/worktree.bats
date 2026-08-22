#!/usr/bin/env bats
#
# ccs new <repo>@<branch> — worktree を切ってそこに立てる。
#
# **本命は「同じリポジトリに 2 本のセッションが同時に立つ」こと**
# （docs/design.md §9.1）。slug がリポジトリ名である限り `ccs new x01` は
# 冪等に 1 本目を返すので、これがタスク単位でセッションを立てる唯一の道。
#
# git は本物を使う。worktree の生成は git の挙動そのものなので、スタブに
# すると「スタブが正しいこと」しか確かめられない。claude と違って課金も
# ネットワークも無い。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15

	CCS_TEST_REPO="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$CCS_TEST_REPO"
	ccs_stub_ghq "$CCS_TEST_REPO"
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

# --- 立てる ------------------------------------------------------------------

@test "worktree: セッションを立て、worktree を作る" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	[ "$(echo "$output" | jq -r '.slug')" = 'x01@topic' ]
	[ "$(echo "$output" | jq -r '.tmux')" = 'cc/x01@topic' ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ -d "$_p" ]
	# git の worktree として登録されていること
	run git -C "$_p" rev-parse --abbrev-ref HEAD
	[ "$output" = 'topic' ]
}

@test "worktree: 元のリポジトリの中身が入っている" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ -f "${_p}/README.md" ]
}

@test "worktree: 元のリポジトリは worktree を認識している" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	run git -C "$CCS_TEST_REPO" worktree list
	[[ "$output" == *"topic"* ]] || return 1
}

# --- 本命: 同じリポジトリに 2 本 ---------------------------------------------

@test "worktree: 同じリポジトリに 2 本のセッションが立つ" {
	run --separate-stderr "$CCS_BIN" new 'x01@one'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'x01@two'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
	[ "$(echo "$output" | jq -r '[.[].slug] | sort | join(",")')" = 'x01@one,x01@two' ]
}

@test "worktree: 素の指定と worktree の指定は別セッションになる" {
	run --separate-stderr "$CCS_BIN" new 'x01'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
}

# --- 冪等性 ------------------------------------------------------------------

@test "worktree: 同じ指定は既存を返し、作り直さない" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _first=$output

	# worktree に印を置く。作り直されたら消える。
	local _p
	_p=$(echo "$_first" | jq -r '.path')
	touch "${_p}/MARK"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]
	[ "$(echo "$output" | jq -r '.sessionId')" = "$(echo "$_first" | jq -r '.sessionId')" ]
	[ -f "${_p}/MARK" ]
}

@test "worktree: 打ち方が違っても同じセッションに落ちる" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'o/x01@topic'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
}

# --- 既存ブランチ ------------------------------------------------------------

@test "worktree: 既存のブランチはそれを開く（作り直さない）" {
	git -C "$CCS_TEST_REPO" branch already
	printf 'x\n' >"${CCS_TEST_REPO}/ONLY_ON_MAIN"

	run --separate-stderr "$CCS_BIN" new 'x01@already'
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	run git -C "$_p" rev-parse --abbrev-ref HEAD
	[ "$output" = 'already' ]
}

@test "worktree: 既存ブランチを開いたことを stderr で伝える" {
	git -C "$CCS_TEST_REPO" branch already
	run --separate-stderr "$CCS_BIN" new 'x01@already'
	[[ "$stderr" == *"既存のブランチ"* ]] || return 1
}

@test "worktree: 新しいブランチを作ったことを stderr で伝える" {
	run --separate-stderr "$CCS_BIN" new 'x01@brandnew'
	[[ "$stderr" == *"作って"* ]] || return 1
	# 追跡されていないものが付いてこないことも言う
	[[ "$stderr" == *"追跡されていない"* ]] || return 1
}

# --- trust -------------------------------------------------------------------

@test "worktree: ghq 配下のリポジトリの worktree は自動で信頼する" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	run jq -r --arg p "$_p" '.projects[$p].hasTrustDialogAccepted' "$CCS_TRUST_FILE"
	[ "$output" = 'true' ]
}

@test "worktree: ghq の外のリポジトリの worktree は自動で信頼しない" {
	local _outside="${CCS_TEST_TMP}/outside/y02"
	ccs_make_git_repo "$_outside"

	run --separate-stderr "$CCS_BIN" new "${_outside}@topic"
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	# **信頼確認が出ることを先に伝えている**こと（黙って立てると 30 秒待たされる）
	[[ "$stderr" == *"まだ信頼されていません"* ]] || return 1

	# trust ファイルは、誰も承認していなければ作られてすらいない。
	if [ -f "$CCS_TRUST_FILE" ]; then
		run jq -r --arg p "$_p" '.projects[$p].hasTrustDialogAccepted // "absent"' "$CCS_TRUST_FILE"
		[ "$output" = 'absent' ]
	fi
}

# --- 異常系 ------------------------------------------------------------------

@test "worktree: git リポジトリでなければ落ちる" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/notgit"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/notgit"

	run --separate-stderr "$CCS_BIN" new 'notgit@topic'
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"git リポジトリではありません"* ]] || return 1
}

@test "worktree: 失敗しても stdout を汚さない" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/notgit"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/notgit"

	run --separate-stderr "$CCS_BIN" new 'notgit@topic'
	[ -z "$output" ]
}

@test "worktree: 同じブランチが他所で開かれていれば、理由を出して落ちる" {
	# ccs の外で同じブランチを開いておく。git は 1 ブランチ 1 worktree しか
	# 許さないので、ccs はここで必ず弾かれる。**黙って失敗させない**のが要件。
	git -C "$CCS_TEST_REPO" worktree add -b topic "${CCS_TEST_TMP}/elsewhere" >/dev/null 2>&1

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"worktree を作れませんでした"* ]] || return 1
	# 次の手が分かること
	[[ "$stderr" == *"worktree list"* ]] || return 1
	[ -z "$output" ]
}
