#!/usr/bin/env bats
#
# ccs new の冪等性。
#
# ハブは「その名前のセッションが欲しい」と言っているのであって、「必ず
# 新しく作れ」と言っているわけではない。同じ slug で 2 度呼ばれたときに
# 二重に立てると、同じ作業ツリーを 2 本の claude が触ることになる。

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

# --- 立っているものを返す --------------------------------------------------

@test "2 度目は立てずに既存を返す" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_first=$(echo "$output" | jq -r '.sessionId')
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.sessionId')" = "$_first" ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]
	[ "$(echo "$output" | jq -r '.running')" = 'true' ]
}

@test "2 度目は claude を起動し直さない" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_LOG="${CCS_TEST_TMP}/invocations.log"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_before=$(wc -l <"$FAKE_CLAUDE_LOG" | tr -d ' ')

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	_after=$(wc -l <"$FAKE_CLAUDE_LOG" | tr -d ' ')

	[ "$_before" = "$_after" ]
}

@test "tmux セッションは 1 本のまま" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"

	_n=$(ccs_tmux list-sessions -F '#{session_name}' | grep -c '^cc/myrepo$')
	[ "$_n" = '1' ]
}

@test "打ち方が違っても同じセッションを返す" {
	# slug が入力ではなく解決後のパスから決まることの、実地での確認。
	_root="${CCS_TEST_TMP}/ghq/github.com/ken-ty/x01"
	mkdir -p "$_root"
	ccs_stub_ghq "$_root"

	run --separate-stderr "$CCS_BIN" new x01
	[ "$status" -eq 0 ]
	_first=$(echo "$output" | jq -r '.sessionId')

	run --separate-stderr "$CCS_BIN" new ken-ty/x01
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.sessionId')" = "$_first" ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]
}

@test "別の対象なら別のセッションが立つ" {
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/a"
	_a=$(echo "$output" | jq -r '.sessionId')
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/b"
	_b=$(echo "$output" | jq -r '.sessionId')

	[ "$_a" != "$_b" ]
	ccs_tmux has-session -t '=cc/a'
	ccs_tmux has-session -t '=cc/b'
}

@test "似た名前を取り違えない" {
	# レジストリの tmux フィールドを前方一致で見るので、区切りまで
	# 含めないと x01 が x011 に当たる。
	mkdir -p "${CCS_TEST_TMP}/work/x01" "${CCS_TEST_TMP}/work/x011"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/x011"
	[ "$status" -eq 0 ]
	_x011=$(echo "$output" | jq -r '.sessionId')

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/x01"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]
	[ "$(echo "$output" | jq -r '.sessionId')" != "$_x011" ]
}

# --- 使い捨て枠 -------------------------------------------------------------

@test "new tmp: 立っている枠は掴まず、次の枠を取る" {
	# `ccs new tmp` は「新しい使い捨て」を求める指示。まだ何も書いていない
	# 作業中のセッションは中身が空なので、ディレクトリだけを見ると
	# 動いているセッションを掴んで返してしまう。
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
	_first=$(echo "$output" | jq -r '.sessionId')

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-2' ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]
	[ "$(echo "$output" | jq -r '.sessionId')" != "$_first" ]
}

@test "new tmp: 枠が全部立っていれば落ちる" {
	export CCS_SCRATCH_SLOTS=2
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"ccs gc"* ]]
}

@test "tmp-N を名指しすれば冪等に返る" {
	# 枠は掴み直さないが、その枠そのものを指せば既存が返る。
	run --separate-stderr "$CCS_BIN" new tmp
	_first=$(echo "$output" | jq -r '.sessionId')
	_path=$(echo "$output" | jq -r '.path')

	run --separate-stderr "$CCS_BIN" new "$_path"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]
	[ "$(echo "$output" | jq -r '.sessionId')" = "$_first" ]
}

# --- ペインは生きているが claude は死んでいる ------------------------------

@test "claude が終了していれば成功扱いにしない" {
	# ハブは会話相手を求めている。ペインの存在を成功として返すと嘘になる。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_EXIT_AFTER=1

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	ccs_wait_registry_count 0 10

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"claude は動いていません"* ]]
}

@test "claude が終了していても、再開用の uuid を出す" {
	# ペインを exec \$SHELL で残しているおかげで起動コマンドが残る。
	# uuid は `ccs restore` の入力であり、手で戻すときの唯一の導線でもある。
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	export FAKE_CLAUDE_EXIT_AFTER=1

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	_id=$(echo "$output" | jq -r '.sessionId')
	ccs_wait_registry_count 0 10

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"claude --resume ${_id}"* ]]
	# 立て直す道具のほうも案内する。
	[[ "$stderr" == *"ccs restore"* ]]
}

# --- 出力の作法 -------------------------------------------------------------

@test "既存を返すときも stdout は JSON 1 行だけ" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ -z "$stderr" ]
	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | wc -l | tr -d ' ')" = '1' ]
}

@test "既存を返すときの path はレジストリの cwd" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	_path=$(echo "$output" | jq -r '.path')

	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/myrepo"
	[ "$(echo "$output" | jq -r '.path')" = "$_path" ]
}
