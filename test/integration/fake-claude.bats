#!/usr/bin/env bats
#
# fake-claude 自身の検証。
#
# **このスタブが間違っていると、以降の integration は「落ちる」のではなく
# 「間違ったものを検証する」。** 一番気づきにくい壊れ方なので、スタブ自体に
# テストを付ける。
#
# ここは実プロセスと実 tmux を使うが、本物の claude は起動しない。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	export CCS_FAKE_PID=''
}

teardown() {
	ccs_stop_fake_claude
	ccs_teardown_sandbox
}

# --- 安全策 ----------------------------------------------------------------

@test "CCS_SESSIONS_DIR が無ければ起動を拒む" {
	# これが無いと、うっかり本物の ~/.claude/sessions に書き込む。
	run env -u CCS_SESSIONS_DIR "$CCS_FAKE_CLAUDE" --session-id abc
	[ "$status" -ne 0 ]
	[[ "$output" == *"CCS_SESSIONS_DIR"* ]]
}

@test "--session-id が無ければ 2 で落ちる" {
	# ccs は必ず id を固定して渡す（design.md §4.3）。渡し忘れを黙って
	# 通すと、id を固定しない実装に退化しても気づけない。
	run "$CCS_FAKE_CLAUDE" -n someslug
	[ "$status" -eq 2 ]
	[[ "$output" == *"--session-id"* ]]
}

# --- 登録 ------------------------------------------------------------------

@test "起動するとレジストリに 1 件書く" {
	ccs_start_fake_claude -n myslug --session-id 11111111-1111-1111-1111-111111111111
	ccs_wait_registry_count 1

	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)
	[ -n "$_f" ]

	run jq -r '.name' "$_f"
	[ "$output" = 'myslug' ]

	run jq -r '.sessionId' "$_f"
	[ "$output" = '11111111-1111-1111-1111-111111111111' ]

	run jq -r '.kind' "$_f"
	[ "$output" = 'interactive' ]
}

@test "レジストリのファイル名は pid で、中の pid と一致する" {
	# ccs はファイル名から pid を得る場面と中身から得る場面の両方がある。
	ccs_start_fake_claude -n myslug --session-id 22222222-2222-2222-2222-222222222222
	ccs_wait_registry_count 1

	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)
	_from_name=$(basename "$_f" .json)
	_from_body=$(jq -r '.pid' "$_f")
	[ "$_from_name" = "$_from_body" ]
}

@test "cwd は起動したディレクトリを指す" {
	mkdir -p "${CCS_TEST_TMP}/somewhere"
	cd "${CCS_TEST_TMP}/somewhere"
	ccs_start_fake_claude -n s --session-id 33333333-3333-3333-3333-333333333333
	ccs_wait_registry_count 1

	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)
	run jq -r '.cwd' "$_f"
	[[ "$output" == *"/somewhere" ]]
}

@test "書かれる JSON は妥当（書きかけを読ませない）" {
	# 一時ファイル → mv で置き換えているので、途中の状態は見えないはず。
	ccs_start_fake_claude -n s --session-id 44444444-4444-4444-4444-444444444444
	ccs_wait_registry_count 1

	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)
	run jq -e . "$_f"
	[ "$status" -eq 0 ]
}

@test "終了するとレジストリから消える" {
	# 本物もプロセスが死ねば消える。残骸が残ると ccs ls が幽霊を並べる。
	ccs_start_fake_claude -n s --session-id 55555555-5555-5555-5555-555555555555
	ccs_wait_registry_count 1

	ccs_stop_fake_claude
	ccs_wait_registry_count 0
	[ "$(ccs_registry_count)" = '0' ]
}

# --- テスト用のつまみ ------------------------------------------------------

@test "FAKE_CLAUDE_REGISTER_DELAY: 登録が遅れる" {
	# ccs new のレジストリ待ちを検証するための土台。遅延が効かないと
	# 「待ちループが無くても通るテスト」になってしまう。
	export FAKE_CLAUDE_REGISTER_DELAY=1
	ccs_start_fake_claude -n s --session-id 66666666-6666-6666-6666-666666666666

	# 起動直後はまだ無い
	[ "$(ccs_registry_count)" = '0' ]

	ccs_wait_registry_count 1 5
	[ "$(ccs_registry_count)" = '1' ]
}

@test "FAKE_CLAUDE_NEVER_REGISTER: 生きているが登録しない" {
	# ccs new のタイムアウト経路を検証するための土台。
	export FAKE_CLAUDE_NEVER_REGISTER=1
	ccs_start_fake_claude -n s --session-id 77777777-7777-7777-7777-777777777777

	sleep 0.5
	[ "$(ccs_registry_count)" = '0' ]
	kill -0 "$CCS_FAKE_PID"
}

@test "FAKE_CLAUDE_EXIT_AFTER: 自ら終了し、後始末もする" {
	# 「ペインは生きているが claude は死んだ」状態の再現。
	export FAKE_CLAUDE_EXIT_AFTER=1
	ccs_start_fake_claude -n s --session-id 88888888-8888-8888-8888-888888888888
	ccs_wait_registry_count 1

	ccs_wait_until 5 bash -c '! kill -0 '"$CCS_FAKE_PID"' 2>/dev/null'
	run bash -c "kill -0 $CCS_FAKE_PID 2>/dev/null"
	[ "$status" -ne 0 ]
	[ "$(ccs_registry_count)" = '0' ]
}

@test "FAKE_CLAUDE_LOG: 渡された引数を記録する" {
	# ccs が本物にどんな引数を渡しているかを検証するための窓。
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/invocations.log"
	export FAKE_CLAUDE_EXIT_AFTER=0
	"$CCS_FAKE_CLAUDE" -n myslug --session-id 99999999-9999-9999-9999-999999999999 --permission-mode plan

	run cat "$FAKE_CLAUDE_LOG"
	[[ "$output" == *"-n myslug"* ]]
	[[ "$output" == *"--session-id 99999999-9999-9999-9999-999999999999"* ]]
	[[ "$output" == *"--permission-mode plan"* ]]
}

@test "知らないフラグを渡されても落ちない" {
	# 本物には多数のフラグがある。スタブが未知のフラグで落ちると、
	# ccs 側の変更が「実装のバグ」ではなく「スタブの都合」で落ちる。
	export FAKE_CLAUDE_EXIT_AFTER=0
	run "$CCS_FAKE_CLAUDE" -n s --session-id aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa \
		--model opus --effort high --dangerously-skip-permissions
	[ "$status" -eq 0 ]
}

# --- agents --json ---------------------------------------------------------

@test "agents --json: 何も無ければ空配列" {
	run "$CCS_FAKE_CLAUDE" agents --json
	[ "$status" -eq 0 ]
	run bash -c "'$CCS_FAKE_CLAUDE' agents --json | jq -e 'length == 0'"
	[ "$status" -eq 0 ]
}

@test "agents --json: 生きているセッションを並べる" {
	ccs_start_fake_claude -n myslug --session-id bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
	ccs_wait_registry_count 1

	run bash -c "'$CCS_FAKE_CLAUDE' agents --json | jq -r '.[0].name'"
	[ "$status" -eq 0 ]
	[ "$output" = 'myslug' ]

	run bash -c "'$CCS_FAKE_CLAUDE' agents --json | jq -e 'length == 1'"
	[ "$status" -eq 0 ]
}

@test "agents --json: 死んだ pid の残骸は並べない" {
	# 本物も生きているものしか出さない。ここが甘いと ccs ls が幽霊を出す。
	printf '{"pid":999999,"sessionId":"dead","cwd":"/tmp","name":"ghost","kind":"interactive"}' \
		>"${CCS_SESSIONS_DIR}/999999.json"

	run bash -c "'$CCS_FAKE_CLAUDE' agents --json | jq -e 'length == 0'"
	[ "$status" -eq 0 ]
}

@test "agents --json: --json 無しは 2 で落ちる" {
	run "$CCS_FAKE_CLAUDE" agents
	[ "$status" -eq 2 ]
}

# --- tmux -----------------------------------------------------------------

@test "tmux の中で起動すると tmux フィールドを埋める" {
	# 本物がこれを書くので、ccs は自前でペインとの対応づけを持たなくてよい
	# （design.md §2.1）。スタブがこれを再現しないと、S4 以降で
	# 「本物なら埋まるのに、テストでは検証できない」ことになる。
	_session="ccs-test-$$"
	tmux new-session -d -s "$_session" -c "$CCS_TEST_TMP" \
		"env CCS_SESSIONS_DIR='$CCS_SESSIONS_DIR' '$CCS_FAKE_CLAUDE' -n tmuxslug --session-id cccccccc-cccc-cccc-cccc-cccccccccccc"

	ccs_wait_registry_count 1 10
	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)

	run jq -r '.tmux // ""' "$_f"
	tmux kill-session -t "$_session" 2>/dev/null || true

	[ -n "$output" ]
	[[ "$output" == "${_session}:"* ]]
}

@test "tmux の外で起動すると tmux フィールドは無い" {
	ccs_start_fake_claude -n s --session-id dddddddd-dddd-dddd-dddd-dddddddddddd
	ccs_wait_registry_count 1

	_f=$(find "$CCS_SESSIONS_DIR" -name '*.json' -type f)
	run jq -r '.tmux // "absent"' "$_f"
	[ "$output" = 'absent' ]
}
