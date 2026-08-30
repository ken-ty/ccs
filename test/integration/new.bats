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
	[[ "$_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || return 1
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
	[[ "$output" == *"-n myrepo"* ]] || return 1
	[[ "$output" == *"--session-id ${_id}"* ]] || return 1
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
	[[ "$(jq -r '.tmux' "$_found")" == "cc/myrepo:"* ]] || return 1
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
	[[ "$output" == *"テストを走らせて"* ]] || return 1
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
	[[ "$_t" == "${CCS_PROJECTS_DIR}/"* ]] || return 1
	[[ "$_t" == *"my-repo-v2/${_id}.jsonl" ]] || return 1

	# 検査は「パスから作った 1 段」に限る。全体を見ると
	# CCS_PROJECTS_DIR 側の文字まで拾ってしまう（macOS の TMPDIR には
	# 実際に _ が入る）。
	_derived=$(basename "$(dirname "$_t")")
	[[ "$_derived" != *"_"* ]] || return 1
	[[ "$_derived" != *"."* ]] || return 1
	[[ "$_derived" == *"my-repo-v2" ]] || return 1
}

# --- 使い捨て枠 -------------------------------------------------------------

@test "new tmp: 作業枠に立てて slug は tmp-1" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
	ccs_tmux has-session -t '=cc/tmp-1'
}

@test "new --tmp: 予約語と同じ結果になる" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
	ccs_tmux has-session -t '=cc/tmp-1'
}

@test "new --tmp: 初期プロンプトを渡せる" {
	# `--tmp` と `--` の並びを取り違えていないか。
	run --separate-stderr "$CCS_BIN" new --tmp -- 'hello'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
	ccs_tmux list-panes -t '=cc/tmp-1' -F '#{pane_start_command}' | grep -q 'hello'
}

@test "new --tmp: <target> との同時指定は 2 で落ちる" {
	run --separate-stderr "$CCS_BIN" new --tmp x01
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"同時に指定できません"* ]] || return 1
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
	[[ "$stderr" == *"登録されませんでした"* ]] || return 1
	[[ "$stderr" == *"ccs attach myrepo"* ]] || return 1
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
	[[ "$output" != *"cc/"* ]] || return 1
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

@test "new: 失敗時も stdout は JSON だけ" {
	# **要件は「空であること」ではなく「パースできること」**（C5 で contract が
	# 変わった）。人間向けの文は stderr、機械向けの 1 行は stdout。
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	printf '%s' "$output" | jq -e . >/dev/null
	# **`printf '%s'` で数えない。** bats は末尾の改行を落とすので、
	# `wc -l`（改行の数）が 0 になる。1 行なら改行を足して数える。
	[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
	[[ "$output" != *"ccs:"* ]] || return 1
	[ -n "$stderr" ]
}

# --- 失敗も機械可読に（C5） ------------------------------------------------
#
# **`ccs new` の stdout は最初から機械のためのもの**（成功すると JSON を出す）。
# 失敗したときだけ何も出ないと、読む側は終了コード 1 しか手掛かりが無い ──
# 「曖昧で選べない」のか「trust で固まった」のかが区別できない。
#
# 出口は 1 つ（EXIT の trap）にしてある。1 か所ずつ足すと必ず取りこぼすので、
# ここでは**散らばった失敗のそれぞれ**が JSON になることを見張る。

@test "new: 引数の誤りは code:usage で返る" {
	run --separate-stderr "$CCS_BIN" new
	[ "$status" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'usage' ]
	[ "$(printf '%s' "$output" | jq -r '.error.exit')" -eq 2 ]
	# **文言は人間向けのものと同じ。** 2 つ書くと必ずずれる。
	[[ "$stderr" == *"$(printf '%s' "$output" | jq -r '.error.message')"* ]] || return 1
}

@test "new: 知らないオプションも JSON で返る" {
	run --separate-stderr "$CCS_BIN" new --bogus
	[ "$status" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'usage' ]
}

@test "new --tmp: 枠が全部埋まっていれば code:scratch-full" {
	# **ハブが読む価値のある区別。** 枠が無いのは待てば直るが、
	# 解決できないのは打ち直しが要る。
	export CCS_SCRATCH_SLOTS=1
	"$CCS_BIN" new --tmp >/dev/null

	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'scratch-full' ]
}

@test "new: 登録されなければ code:not-registered" {
	export FAKE_CLAUDE_NEVER_REGISTER=1
	export CCS_NEW_TIMEOUT=2
	mkdir -p "${CCS_TEST_TMP}/work/mine"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'not-registered' ]
}

@test "new: ペインが残っていて claude が死んでいれば code:stale-pane" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" >/dev/null
	ccs_wait_until 10 ccs_registry_count_is 0

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'stale-pane' ]
}

@test "new: 成功したときの形は変わらない（error を足さない）" {
	# **既定の出力を変えない。** 既に読んでいる側を壊さない。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r 'has("error")')" = 'false' ]
	[ "$(printf '%s' "$output" | jq -r '.created')" = 'true' ]
}

@test "new: stdout に人間向けの文を混ぜない" {
	run --separate-stderr "$CCS_BIN" new
	[ "$status" -eq 2 ]
	printf '%s' "$output" | jq -e . >/dev/null
	[[ "$output" != *"ccs:"* ]] || return 1
}
