#!/usr/bin/env bats
#
# `ccs ls --mcp` ── MCP が落ちているセッションを見つける（#105）。
#
# **検知だけ。** 復帰は `ccs kill` → `ccs restore` で、そちらは既存の道具。
# 自動では畳まない（作業中のセッションを黙って落とすほうが高くつく）。

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

# 作業枠に 1 本立てて、slug と sessionId をファイルに積む。
# （コマンド置換ごしに呼ぶので、変数への代入はサブシェルに閉じる）
_new_tmp() {
	run --separate-stderr "$CCS_BIN" new --tmp
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -r '.slug' >>"${CCS_TEST_TMP}/tmp-slugs"
	printf '%s' "$output" | jq -r '.sessionId' >>"${CCS_TEST_TMP}/tmp-uuids"
}

_ts() { sed -n "${1:-1}p" "${CCS_TEST_TMP}/tmp-slugs"; }
_uuid_of() { sed -n "${1:-1}p" "${CCS_TEST_TMP}/tmp-uuids"; }

_slot_path() {
	printf '%s/%s' "$(cd "$CCS_SCRATCH_ROOT" && pwd -P)" \
		"$(_ts "${1:-1}" | sed 's/^tmp-//')"
}

# `<cwd>` の `<server>` に、`<uuid>` の接続ログを 1 本置く。
# 第 4 引数があれば失敗として書く。
_mcp_log() {
	local cwd=$1 server=$2 uuid=$3 fail=${4:-}
	local dir enc
	enc=$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')
	dir="${CCS_MCP_LOG_DIR}/${enc}/mcp-logs-${server}"
	mkdir -p "$dir"
	local f="${dir}/${5:-2026-09-03T00-00-00-000Z}.jsonl"
	printf '{"debug":"Starting connection","sessionId":"%s","cwd":"%s"}\n' "$uuid" "$cwd" >"$f"
	if [ -n "$fail" ]; then
		printf '{"error":"Connection failed (CONNECTION_CLOSED): Connection closed","sessionId":"%s","cwd":"%s"}\n' "$uuid" "$cwd" >>"$f"
	else
		printf '{"debug":"Tool list received","sessionId":"%s","cwd":"%s"}\n' "$uuid" "$cwd" >>"$f"
	fi
}

@test "ls --mcp: 素の ls の出力を 1 文字も変えない" {
	# **これが実装の条件。** `ccs ls` は「シンプルな列挙」のままでなければならない。
	_new_tmp

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	local plain=$output

	_mcp_log "$(_slot_path 1)" chatwork "$(_uuid_of 1)" fail

	run "$CCS_BIN" ls
	[ "$status" -eq 0 ]
	[ "$output" = "$plain" ]
}

@test "ls --mcp: 落ちているサーバを名前で出す" {
	_new_tmp
	local uuid
	uuid=$(_uuid_of 1)
	_mcp_log "$(_slot_path 1)" chatwork "$uuid" fail
	_mcp_log "$(_slot_path 1)" notion "$uuid"

	run "$CCS_BIN" ls --mcp
	[ "$status" -eq 0 ]
	[[ "$output" == *"NG"* ]] || return 1
	[[ "$output" == *"chatwork"* ]] || return 1
	[[ "$output" != *"notion"* ]] || return 1
}

@test "ls --mcp: 落ちていなければ ok と出す" {
	# **落ちていないセッションも出す。** 出ないと「調べたのか、調べていないのか」
	# が区別できない。
	_new_tmp
	_mcp_log "$(_slot_path 1)" notion "$(_uuid_of 1)"

	run "$CCS_BIN" ls --mcp
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]] || return 1
}

@test "ls --mcp: 別の会話の失敗ログを自分のものにしない" {
	# **同じ場所で会話を何度も立てていると、古い失敗ログが残る。**
	# 素直に読むと、死んでいないものを死んだと言う。
	_new_tmp
	_mcp_log "$(_slot_path 1)" chatwork 'ffffffff-0000-4000-8000-000000000000' fail

	run "$CCS_BIN" ls --mcp
	[ "$status" -eq 0 ]
	[[ "$output" != *"NG"* ]] || return 1
}

@test "ls --mcp: 同じ会話の中では新しいほうを採る" {
	# 一度落ちても、そのあと繋がったなら ok。
	_new_tmp
	local uuid
	uuid=$(_uuid_of 1)
	_mcp_log "$(_slot_path 1)" chatwork "$uuid" fail '2026-09-01T00-00-00-000Z'
	_mcp_log "$(_slot_path 1)" chatwork "$uuid" ''   '2026-09-03T00-00-00-000Z'

	run "$CCS_BIN" ls --mcp
	[ "$status" -eq 0 ]
	[[ "$output" != *"NG"* ]] || return 1
}

@test "ls --mcp --json: 機械で読める形で出す" {
	_new_tmp
	_mcp_log "$(_slot_path 1)" chatwork "$(_uuid_of 1)" fail

	run --separate-stderr "$CCS_BIN" ls --mcp --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[0].failed[0]')" = 'chatwork' ]
}

@test "ls --mcp: -l とは併用できない" {
	# **別の表。** `-l` の盤面は「いま何をしているか」で、問いが違う。
	run --separate-stderr "$CCS_BIN" ls --mcp -l
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"一緒に使えません"* ]] || return 1
}

@test "ls --mcp: ログが 1 つも無くても落ちない" {
	_new_tmp
	run "$CCS_BIN" ls --mcp
	[ "$status" -eq 0 ]
	[[ "$output" == *"ok"* ]] || return 1
}
