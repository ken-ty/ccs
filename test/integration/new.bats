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

@test "new tmp: 作業枠に立てて slug は tmp-<id>" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(echo "$output" | jq -r '.slug')
	[[ "$_slug" == tmp-* ]] || return 1
	ccs_tmux has-session -t "=cc/${_slug}"

	# **印が刻まれている**（I2b）。ディレクトリを見れば素性が分かる。
	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ "$(jq -r '.kind' "${_p}/.ccs.json")" = 'scratch' ]
	[ "$(jq -r '.workspaceId' "${_p}/.ccs.json")" = "$(basename "$_p")" ]
	[ "$(jq -r '.issuedSlug' "${_p}/.ccs.json")" = "$_slug" ]
	[ "$(jq -r '.issuedSessionId' "${_p}/.ccs.json")" = "$(echo "$output" | jq -r '.sessionId')" ]
}

@test "new --tmp: 予約語と同じ結果になる" {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(echo "$output" | jq -r '.slug')
	[[ "$_slug" == tmp-* ]] || return 1
	ccs_tmux has-session -t "=cc/${_slug}"
}

@test "new --tmp: 初期プロンプトを渡せる" {
	# `--tmp` と `--` の並びを取り違えていないか。
	run --separate-stderr "$CCS_BIN" new --tmp -- 'hello'
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(echo "$output" | jq -r '.slug')
	ccs_tmux list-panes -t "=cc/${_slug}" -F '#{pane_start_command}' | grep -q 'hello'
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

# --- 紐付けの目印（C2） ----------------------------------------------------
#
# **`ccs` は中身を解釈しない。** ccb がタスクとセッションを紐付けるための
# 不透明な文字列を運ぶだけ（design.md §9）。知らせると 4 責務が 5 つ目に膨らむ。

@test "new --label: ls --json が返す" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --label task=T-12
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.task')" = 'T-12' ]
}

@test "new --label: 反復できる" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --label task=T-12 --label board=main >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.task')" = 'T-12' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.board')" = 'main' ]
}

@test "new --label: 中身を解釈しない（空白も引用符も = も運ぶ）" {
	# **不透明な文字列として運ぶだけ。** 検査するのは key があることだけ。
	#
	# **題材は ASCII にする。** `make check` は `LC_ALL=C` を強制する
	# （Makefile の `BATS_ENV`）ので、非 ASCII の値は Linux で往復しない ──
	# 手元（macOS）では通り、**CI でだけ落ちる**（I4 の改名先と同じ環境要因）。
	# 見たいのは「解釈せずに運ぶこと」であって「日本語であること」ではない。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" \
		--label 'note=a b "c" = d' --label 'sym=#{}$(x)`y`' >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.note')" = 'a b "c" = d' ]
	# **tmux の format も shell の展開も起きない。**
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.sym')" = '#{}$(x)`y`' ]
}

@test "new --label: 2 回目は上書きし、他の key は消さない" {
	# **「いま渡したものが全部」にしない。** ラベルを知らない側が ccs new を
	# 打つたびに紐付けが消えることになる。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --label task=T-12 --label board=main >/dev/null
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --label task=T-99 >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.task')" = 'T-99' ]
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.board')" = 'main' ]
}

@test "new: label を付けなければ空のオブジェクト" {
	# **既定の出力の形を変えない。** 読む側が有無で分岐しなくて済む。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -c '.[0].labels')" = '{}' ]
}

@test "new --label: ls -l --json でも返る" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --label task=T-12 >/dev/null

	run --separate-stderr "$CCS_BIN" ls -l --json
	[ "$(printf '%s' "$output" | jq -r '.[0].labels.task')" = 'T-12' ]
}

@test "new --label: k=v でなければ使い方の誤り" {
	run --separate-stderr "$CCS_BIN" new --tmp --label nope
	[ "$status" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'usage' ]

	run --separate-stderr "$CCS_BIN" new --tmp --label '=v'
	[ "$status" -eq 2 ]

	run --separate-stderr "$CCS_BIN" new --tmp --label
	[ "$status" -eq 2 ]
}

@test "new --label: ラベルは他のセッションに漏れない" {
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/a" --label task=T-1 >/dev/null
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/b" >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug=="a") | .labels.task')" = 'T-1' ]
	[ "$(printf '%s' "$output" | jq -c '.[] | select(.slug=="b") | .labels')" = '{}' ]
}

# --- 起動前に行を作る / 長い仕様を渡す（C4） -------------------------------
#
# **どちらもハブ側の都合。** 会話の id を先に決められれば、起動を待たずに
# その行を作れる。初期プロンプトは数 KB の複数行になるので、**呼ぶ側の argv に
# 載せない**手立てが要る（design.md §9）。

@test "new --session-id: 指定した uuid で立つ" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	local _u='11111111-2222-4333-8444-555555555555'

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --session-id "$_u"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" = "$_u" ]
	[[ "$(printf '%s' "$output" | jq -r '.transcript')" == *"${_u}.jsonl" ]] || return 1
}

@test "new --session-id: 大文字でも受ける（小文字に寄せる）" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" \
		--session-id '11111111-2222-4333-8444-AAAAAAAAAAAA'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" = '11111111-2222-4333-8444-aaaaaaaaaaaa' ]
}

@test "new --session-id: uuid でなければ使い方の誤り" {
	run --separate-stderr "$CCS_BIN" new --tmp --session-id nope
	[ "$status" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'usage' ]

	run --separate-stderr "$CCS_BIN" new --tmp --session-id
	[ "$status" -eq 2 ]

	# 桁が足りないものも弾く。
	run --separate-stderr "$CCS_BIN" new --tmp --session-id '1111-2222-3333'
	[ "$status" -eq 2 ]
}

@test "new --session-id: 使われている uuid では立てない" {
	# **同じ会話を 2 本の claude が握ることになる**（ccs adopt の門と同じ理由）。
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"
	local _u='11111111-2222-4333-8444-666666666666'
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/a" --session-id "$_u" >/dev/null

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/b" --session-id "$_u"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'session-id-in-use' ]
	run ccs_tmux has-session -t '=cc/b'
	[ "$status" -ne 0 ]
}

@test "new --prompt-file: 中身をそのまま初期プロンプトにする" {
	# **claude に何が渡ったかで見る。** スタブが引数をログに書く。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	local _f="${CCS_TEST_TMP}/spec.md"
	printf '# spec\n\n- one\n- two\n' >"$_f"
	local _log="${CCS_TEST_TMP}/args.log"

	FAKE_CLAUDE_LOG="$_log" run --separate-stderr \
		"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --prompt-file "$_f"
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" == *"- one"* ]] || return 1
	[[ "$(cat "$_log")" == *"- two"* ]] || return 1
}

@test "new --prompt-file: 数 KB の複数行でも壊れない" {
	# **argv に載せないための機能**なので、ここが本体。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	local _f="${CCS_TEST_TMP}/spec.md"
	local _i=1
	: >"$_f"
	while [ "$_i" -le 200 ]; do
		printf 'line %d with spaces and "quotes" and $(x) and `y`\n' "$_i" >>"$_f"
		_i=$((_i + 1))
	done
	[ "$(wc -c <"$_f")" -gt 8000 ]
	local _log="${CCS_TEST_TMP}/args.log"

	FAKE_CLAUDE_LOG="$_log" run --separate-stderr \
		"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" --prompt-file "$_f"
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" == *"line 200 with spaces"* ]] || return 1
	# **展開されていない。**
	[[ "$(cat "$_log")" == *'$(x)'* ]] || return 1
}

@test "new --prompt-file: -- と一緒には使えない" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	printf 'x\n' >"${CCS_TEST_TMP}/spec.md"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" \
		--prompt-file "${CCS_TEST_TMP}/spec.md" -- 'inline'
	[ "$status" -eq 2 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'usage' ]
}

@test "new --prompt-file: 読めなければ code:prompt-file" {
	run --separate-stderr "$CCS_BIN" new --tmp --prompt-file "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	[ "$(printf '%s' "$output" | jq -r '.error.code')" = 'prompt-file' ]
}

# --- 作業枠に「成果物は cwd に置く」と伝える（P0） -------------------------
#
# **穴はここだった。** ハーネスは一時ファイルを `/tmp` 配下の scratchpad に
# 置くよう指示するので、**「一時的な作業」と言われたエージェントはそちらを
# 選ぶ**。`~/.cc-scratch` は OS が消さないのに、そこに立てたセッションの
# 成果物が数日で消える（#63 の実例）。
#
# **`CLAUDE.md` を枠に置く案は採らなかった。** 枠が「空でない」に化けて、
# 自動承認（I2c）も `ccs gc` の掃除（I3a）も止まる。ファイルを置かずに
# 伝えるほうが、どの不変条件も壊さない。

@test "new --tmp: 作業枠のセッションに注意書きを渡す" {
	local _log="${CCS_TEST_TMP}/args.log"
	FAKE_CLAUDE_LOG="$_log" run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" == *"--append-system-prompt"* ]] || return 1
	[[ "$(cat "$_log")" == *"cwd"* ]] || return 1
}

@test "new --tmp: 注意書きを渡してもディレクトリは空のまま" {
	# **ここが CLAUDE.md 案との差。** ファイルを置かないので、
	# 自動承認も gc の掃除もそのまま効く。
	local _p
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	_p=$(printf '%s' "$output" | jq -r '.path')
	[[ "$stderr" == *"信頼済みにしました"* ]] || return 1
	# 印だけがある状態。
	[ "$(ls -A "$_p" | tr '\n' ' ')" = ".ccs.json " ]
}

@test "new <repo>: 作業枠でなければ注意書きは渡さない" {
	# **枠だけの話。** リポジトリの cwd は消えないので、伝える理由が無い。
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	local _log="${CCS_TEST_TMP}/args.log"
	FAKE_CLAUDE_LOG="$_log" run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" != *"--append-system-prompt"* ]] || return 1
}

@test "new --tmp: CCS_SCRATCH_NOTE を空にすれば渡さない" {
	export CCS_SCRATCH_NOTE=''
	local _log="${CCS_TEST_TMP}/args.log"
	FAKE_CLAUDE_LOG="$_log" run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" != *"--append-system-prompt"* ]] || return 1
}

@test "new --tmp: 注意書きは初期プロンプトを潰さない" {
	# **別の口で渡す。** -- <初期プロンプト> と両立する。
	local _log="${CCS_TEST_TMP}/args.log"
	FAKE_CLAUDE_LOG="$_log" run --separate-stderr "$CCS_BIN" new --tmp -- 'hello'
	[ "$status" -eq 0 ]
	[[ "$(cat "$_log")" == *"--append-system-prompt"* ]] || return 1
	[[ "$(cat "$_log")" == *"hello"* ]] || return 1
}

# --- 名前を渡す先（#108） --------------------------------------------------
#
# **`-n <slug>` は自動命名を止める。** 渡すと Claude Desktop 上の表示名が
# slug のままになり、話題では検索できない。だが `restore` の候補列挙は
# ghq 配下だけ会話ログの `custom-title` を「ccs が立てた」痕跡に使うので、
# そこだけは渡し続ける必要がある（`restore_started_by_ccs`、I3b）。

@test "new --tmp: 作業枠には slug を名前として押し付けない" {
	# 作業枠は印（.ccs.json）で列挙するので、痕跡が要らない。
	# スタブは `-n` が無いとき `fake` を名乗る（本物の自動命名の代役）。
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	local id found slug
	id=$(printf '%s' "$output" | jq -r '.sessionId')
	slug=$(printf '%s' "$output" | jq -r '.slug')
	found=$(grep -l "\"sessionId\":\"${id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[ -n "$found" ]
	[ "$(jq -r '.name // ""' "$found")" != "$slug" ] || return 1
}

@test "new <repo>: リポジトリには名前を渡す（restore の痕跡になる）" {
	# **外すと、以後に立てたリポジトリのセッションが黙って restore の候補から
	# 消える。** ADR-0002 決定 5 が ghq 配下への印を禁じているので代わりが無い。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	local id found
	id=$(printf '%s' "$output" | jq -r '.sessionId')
	found=$(grep -l "\"sessionId\":\"${id}\"" "$CCS_SESSIONS_DIR"/*.json)
	[ "$(jq -r '.name' "$found")" = 'myrepo' ]
}
