#!/usr/bin/env bats
#
# ccs ls
#
# **sessionId を必ず出す。** v1 に resume が無いので、止まったセッションを
# 手で `claude --resume <uuid>` するのが唯一の復帰路であり、その uuid を
# 知る手段がこの一覧しかない。ここで落とすと詰む。

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

# --- 空のとき --------------------------------------------------------------

@test "ls: 何も無ければ、その旨と次の手を出す" {
	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]]
	[[ "$output" == *"ccs new"* ]]
}

@test "ls --json: 何も無ければ空配列" {
	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r 'length')" = '0' ]
}

# --- 立っているものを出す --------------------------------------------------

@test "ls: 立てたセッションが並ぶ" {
	_new myrepo >/dev/null

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[[ "$output" == *"myrepo"* ]]
	[[ "$output" == *"SLUG"* ]]
}

@test "ls --json: slug / status / sessionId / path / tmux を持つ" {
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'myrepo' ]
	[ "$(echo "$output" | jq -r '.[0].sessionId')" = "$_id" ]
	[ "$(echo "$output" | jq -r '.[0].tmux')" = 'cc/myrepo' ]
	[ "$(echo "$output" | jq -r '.[0].path')" = "$(echo "$_out" | jq -r '.path')" ]
}

@test "ls: sessionId をそのまま出す（省略しない）" {
	# 手で claude --resume に貼れる必要がある。
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" ls
	[[ "$output" == *"$_id"* ]]
}

@test "ls: 複数あれば slug 順に並ぶ" {
	_new zebra >/dev/null
	_new alpha >/dev/null
	_new middle >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'alpha' ]
	[ "$(echo "$output" | jq -r '.[1].slug')" = 'middle' ]
	[ "$(echo "$output" | jq -r '.[2].slug')" = 'zebra' ]
}

@test "ls: status はレジストリの値を映す" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].status')" = 'working' ]
}

# --- 止まっているもの ------------------------------------------------------

@test "ls: claude が終了していれば stopped と出す" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	_new myrepo >/dev/null
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].status')" = 'stopped' ]
}

@test "ls: stopped でも sessionId を出す" {
	# **これが無いと復帰できない。** v1 に resume が無いので、
	# 手で claude --resume するための uuid はここにしか無い。
	export FAKE_CLAUDE_EXIT_AFTER=1
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].sessionId')" = "$_id" ]
}

@test "ls: stopped でも path を出す" {
	export FAKE_CLAUDE_EXIT_AFTER=1
	_out=$(_new myrepo)
	_expected=$(echo "$_out" | jq -r '.path')
	ccs_wait_registry_count 0 10

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r '.[0].path')" = "$_expected" ]
}

@test "ls: 生きているものと止まっているものが混在しても正しい" {
	_alive=$(_new alive)
	_alive_id=$(echo "$_alive" | jq -r '.sessionId')

	_dead=$(_new dead)
	_dead_id=$(echo "$_dead" | jq -r '.sessionId')

	# FAKE_CLAUDE_EXIT_AFTER は使えない ── tmux サーバの環境は
	# サーバ起動時（= 1 本目の new）に固定されるので、あとから export しても
	# 2 本目には届かない。プロセスを直接落として同じ状態を作る。
	ccs_kill_claude_of dead

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="alive") | .status')" != 'stopped' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="alive") | .sessionId')" = "$_alive_id" ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="dead") | .status')" = 'stopped' ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="dead") | .sessionId')" = "$_dead_id" ]
}

# --- 管轄の境界 ------------------------------------------------------------

@test "ls: cc/ が付かない tmux セッションは無視する" {
	# 手で開いた作業用セッションを巻き込まない。
	ccs_tmux new-session -d -s 'my-own-work' -c "$CCS_TEST_TMP" 'sleep 60'
	_new myrepo >/dev/null

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'myrepo' ]
}

@test "ls: 別セッションの sessionId を取り違えない" {
	# レジストリの照合は cc/<slug>: まで含めた前方一致。
	_a=$(_new x01)
	_b=$(_new x011)

	run "$CCS_BIN" ls --json
	_got_a=$(echo "$output" | jq -r '.[] | select(.slug=="x01") | .sessionId')
	_got_b=$(echo "$output" | jq -r '.[] | select(.slug=="x011") | .sessionId')
	[ "$_got_a" = "$(echo "$_a" | jq -r '.sessionId')" ]
	[ "$_got_b" = "$(echo "$_b" | jq -r '.sessionId')" ]
	[ "$_got_a" != "$_got_b" ]
}

@test "ls: 死んだプロセスのレジストリを掴まない" {
	# claude は終了時に自分のファイルを消すが、シグナル死では残る。
	# 残骸を掴むと、**死んでいるセッションを idle と表示し、立て直した
	# あとも古い sessionId を出し続ける**（2026-08-23 に CI が捕まえた）。
	_a=$(_new x01)
	_live=$(echo "$_a" | jq -r '.sessionId')

	# 同じ tmux セッションを指す残骸を、死んだ pid で置く。
	# ファイル名を先頭に来るものにして、live より先に当たるようにする。
	cat >"${CCS_SESSIONS_DIR}/00000.json" <<JSON
{"pid":999999,"sessionId":"00000000-0000-4000-8000-000000000000","cwd":"/somewhere","tmux":"cc/x01:@0.%0","name":"stale","status":"idle"}
JSON

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.[] | select(.slug=="x01") | .sessionId')" = "$_live" ]
}

# --- 出力の作法 -------------------------------------------------------------

@test "ls --json: 妥当な JSON" {
	_new a >/dev/null
	_new b >/dev/null

	run "$CCS_BIN" ls --json
	echo "$output" | jq -e . >/dev/null
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
}

@test "ls --json: パスに引用符が混じっても壊れない" {
	mkdir -p "${CCS_TEST_TMP}/work/say\"hi"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/say\"hi"
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	echo "$output" | jq -e . >/dev/null
}

@test "ls: 表は長い slug でも崩れない" {
	mkdir -p "${CCS_TEST_TMP}/work/a-very-long-repository-name-here"
	run --separate-stderr "$CCS_BIN" new "${CCS_TEST_TMP}/work/a-very-long-repository-name-here"
	[ "$status" -eq 0 ]
	_new b >/dev/null

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	# ヘッダと各行の SESSION ID 列が同じ桁から始まる
	_header_col=$(printf '%s\n' "$output" | sed -n '1p' | awk '{ print index($0, "SESSION ID") }')
	[ "$_header_col" -gt 0 ]
}

@test "ls: 知らないオプションは 2" {
	run "$CCS_BIN" ls --nope
	[ "$status" -eq 2 ]
}
