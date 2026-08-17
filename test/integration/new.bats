#!/usr/bin/env bats
#
# ccs new — 設計の実体。
#
# 本物の tmux を使い、claude は fake-claude に差し替える。ここで本物を
# 起動する作りにすると、テストが課金され、ログイン状態に依存し、実行の
# たびに結果が変わる（AGENTS.md）。
#
# tmux セッションは必ず teardown で畳む。取りこぼすと、あとのテストが
# 「すでに立っています」で落ちる。

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

# --- 立てる ----------------------------------------------------------------

@test "new: tmux セッションを立てて JSON を返す" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]

	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | jq -r '.slug')" = 'myrepo' ]
	[ "$(echo "$output" | jq -r '.tmux')" = 'cc/myrepo' ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]

	ccs_tmux has-session -t '=cc/myrepo'
}

@test "new: 返した sessionId でレジストリに載っている" {
	# 「立った」の判定は tmux ではなくレジストリで行う。ペインが生きていても
	# claude が起動していないことがあるため。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_id=$(echo "$output" | jq -r '.sessionId')

	_found=$(grep -l "\"sessionId\":\"${_id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[ -n "$_found" ]
	[ "$(jq -r '.name' "$_found")" = 'myrepo' ]
}

@test "new: sessionId は妥当な UUID の形" {
	# 本物は --session-id に妥当な UUID を要求する。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	_id=$(echo "$output" | jq -r '.sessionId')
	[[ "$_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]
}

@test "new: 呼ぶたびに違う sessionId になる" {
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/a"
	_a=$(echo "$output" | jq -r '.sessionId')
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/b"
	_b=$(echo "$output" | jq -r '.sessionId')

	[ "$_a" != "$_b" ]
}

@test "new: claude を正しい引数で起動している" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/invocations.log"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_id=$(echo "$output" | jq -r '.sessionId')

	run cat "$FAKE_CLAUDE_LOG"
	[[ "$output" == *"-n myrepo"* ]]
	[[ "$output" == *"--session-id ${_id}"* ]]
}

@test "new: セッションの cwd は解決したパス" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	_id=$(echo "$output" | jq -r '.sessionId')
	_expected=$(echo "$output" | jq -r '.path')

	_found=$(grep -l "\"sessionId\":\"${_id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[ "$(jq -r '.cwd' "$_found")" = "$_expected" ]
}

@test "new: レジストリに tmux ペインが記録される" {
	# 本物がこれを書くので、ccs は自前で対応づけを持たなくてよい。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	_id=$(echo "$output" | jq -r '.sessionId')

	_found=$(grep -l "\"sessionId\":\"${_id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[[ "$(jq -r '.tmux' "$_found")" == "cc/myrepo:"* ]]
}

@test "new: 空白や引用符を含むパスでも壊れない" {
	# パスは利用者が決めるもの。tmux にはコマンドを文字列で渡すので、
	# 引用を手抜きするとここで壊れる。
	mkdir -p "${CCS_TEST_TMP}/work/my repo's dir"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/my repo's dir"
	[ "$status" -eq 0 ]
	_id=$(echo "$output" | jq -r '.sessionId')

	_found=$(grep -l "\"sessionId\":\"${_id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[ "$(jq -r '.cwd' "$_found")" = "$(echo "$output" | jq -r '.path')" ]
}

@test "new: 初期プロンプトを -- の後ろで渡せる" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/invocations.log"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo" -- 'テストを走らせて'
	[ "$status" -eq 0 ]

	run cat "$FAKE_CLAUDE_LOG"
	[[ "$output" == *"テストを走らせて"* ]]
}

# --- transcript --------------------------------------------------------------

@test "new: transcript のパスは本物の規則に従う" {
	# 実測: 絶対パスの英数字以外をすべて - に潰す
	#   /Users/apple/ghq/github.com/ken-ty/collection_deck_ja
	#     → -Users-apple-ghq-github-com-ken-ty-collection-deck-ja
	mkdir -p "${CCS_TEST_TMP}/work/my_repo.v2"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/my_repo.v2"
	[ "$status" -eq 0 ]

	_t=$(echo "$output" | jq -r '.transcript')
	_id=$(echo "$output" | jq -r '.sessionId')
	[[ "$_t" == "${CCS_PROJECTS_DIR}/"* ]]
	[[ "$_t" == *"my-repo-v2/${_id}.jsonl" ]]

	# 検査は「パスから作った 1 段」に限る。全体を見ると
	# CCS_PROJECTS_DIR 側の文字まで拾ってしまう（macOS の TMPDIR には
	# 実際に _ が入る）。
	_derived=$(basename "$(dirname "$_t")")
	[[ "$_derived" != *"_"* ]]
	[[ "$_derived" != *"."* ]]
	[[ "$_derived" == *"my-repo-v2" ]]
}

# --- 使い捨て枠 -------------------------------------------------------------

@test "new tmp: 作業枠に立てて slug は tmp-1" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
	ccs_tmux has-session -t '=cc/tmp-1'
}

# --- 失敗の経路 -------------------------------------------------------------

# 同じ slug を 2 度頼まれたときの振る舞いは integration/idempotent.bats。

@test "new: 登録されなければ落とし、ペインの中身を見せる" {
	# 本物が信頼確認やログインで止まったときの経路。何に詰まったかは
	# ペインにしか出ないので、それを出さないと利用者は詰む。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_NEVER_REGISTER=1
	export CCS_NEW_TIMEOUT=2

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"登録されませんでした"* ]]
	[[ "$stderr" == *"ccs attach myrepo"* ]]
}

@test "new: 登録されなくても tmux セッションは残す" {
	# 消すと何に詰まっていたか分からなくなる。片付けは人が決める。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_NEVER_REGISTER=1
	export CCS_NEW_TIMEOUT=2

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 1 ]
	ccs_tmux has-session -t '=cc/myrepo'
}

@test "new: 登録が遅れても待って成功する" {
	# 固定 sleep ではなくポーリングであることの確認。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_REGISTER_DELAY=2
	export CCS_NEW_TIMEOUT=15

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]
}

@test "new: 存在しない対象では tmux セッションを作らない" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	run ccs_tmux ls
	[[ "$output" != *"cc/"* ]]
}

@test "new: target が 2 つあれば 2" {
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"
	[ "$status" -eq 2 ]
}

@test "new: 知らないオプションは 2" {
	run --separate-stderr "$CCS_BIN" new --nope somewhere
	[ "$status" -eq 2 ]
}

# --- 出力の作法 -------------------------------------------------------------

@test "new: 成功時の stdout は JSON だけ" {
	# ハブがそのままパースする。人間向けの文言が混じると壊れる。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | wc -l | tr -d ' ')" = '1' ]
}

@test "new: 失敗時は stdout を汚さない" {
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ -n "$stderr" ]
}
