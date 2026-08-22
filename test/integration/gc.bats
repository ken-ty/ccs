#!/usr/bin/env bats
#
# ccs gc
#
# 消す操作なので、**既定が dry-run であること**を最優先で確かめる。
# あわせて「中身のある作業枠を絶対に消さない」ことも押さえる ──
# そこにあるのは利用者のファイルで、消えたら戻らない。

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

# --- 何も無いとき ----------------------------------------------------------

@test "gc: 何も無ければその旨を出す" {
	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "gc: 生きているセッションだけなら何もしない" {
	_new alive >/dev/null

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/alive'
}

# --- 既定は dry-run --------------------------------------------------------

@test "gc: 既定では畳まない" {
	# ハブのエージェントが打つことを想定すると、確認なしで消える設計は
	# 割に合わない（ghq rm --dry-run と同じ作法）。
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs gc --yes"* ]] || return 1

	ccs_tmux has-session -t '=cc/dead'
}

@test "gc: 既定でも対象を具体的に見せる" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[[ "$output" == *"dead"* ]] || return 1
}

@test "gc: 既定では空の枠も消さない" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[ -d "${CCS_SCRATCH_ROOT}/1" ]
}

# --- --yes で実行 ----------------------------------------------------------

@test "gc --yes: 止まったセッションを畳む" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc -y: 短い形も効く" {
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc -y
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc --yes: 生きているセッションは残す" {
	_new alive >/dev/null
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/alive'
	run ccs_tmux has-session -t '=cc/dead'
	[ "$status" -ne 0 ]
}

@test "gc --yes: 空の枠を消す" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1" "${CCS_SCRATCH_ROOT}/2"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ ! -d "${CCS_SCRATCH_ROOT}/1" ]
	[ ! -d "${CCS_SCRATCH_ROOT}/2" ]
}

@test "gc --yes: 使用中の枠は触らない" {
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	_path=$(echo "$output" | jq -r '.path')

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "$_path" ]
	ccs_tmux has-session -t '=cc/tmp-1'
}

# --- 中身のある枠は消さない ------------------------------------------------

@test "gc --yes: 中身のある枠は絶対に消さない" {
	# ここにあるのは利用者のファイル。枠を塞いでいるのは事実だが、
	# 消えたら戻らない。
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	printf 'たいせつな作業\n' >"${CCS_SCRATCH_ROOT}/1/notes.md"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -f "${CCS_SCRATCH_ROOT}/1/notes.md" ]
	[ "$(cat "${CCS_SCRATCH_ROOT}/1/notes.md")" = 'たいせつな作業' ]
}

@test "gc: 中身のある枠は報告する" {
	# 消さないが、枠を塞いでいることは伝える。
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	touch "${CCS_SCRATCH_ROOT}/1/leftover"

	run "$CCS_BIN" gc
	[ "$status" -eq 0 ]
	[[ "$output" == *"中身が残っている"* ]] || return 1
	[[ "$output" == *"消しません"* ]] || return 1
}

@test "gc: 隠しファイルだけでも中身ありとみなす" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1/.git"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_SCRATCH_ROOT}/1/.git" ]
}

# --- 復帰の手掛かり --------------------------------------------------------

@test "gc: 畳む前に uuid を見せる" {
	# **畳むと pane_start_command ごと消えるので、ここが最後の機会。**
	_out=$(_new dead)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
}

@test "gc --yes: 実行時にも uuid を見せる" {
	_out=$(_new dead)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	[[ "$output" == *"${_id}"* ]] || return 1
}

# --- 管轄の境界 ------------------------------------------------------------

@test "gc: cc/ が付かない tmux セッションは触らない" {
	ccs_tmux new-session -d -s 'my-own-work' -c "$CCS_TEST_TMP" 'sleep 60'

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=my-own-work'
}

@test "gc: 枠の外のディレクトリは触らない" {
	mkdir -p "${CCS_TEST_TMP}/not-a-slot"

	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]
	[ -d "${CCS_TEST_TMP}/not-a-slot" ]
}

@test "gc: 知らないオプションは 2" {
	run "$CCS_BIN" gc --nope
	[ "$status" -eq 2 ]
}

# --- 後始末のあと ----------------------------------------------------------

@test "gc --yes のあと ls が綺麗になる" {
	_new alive >/dev/null
	_new dead >/dev/null
	ccs_kill_claude_of dead

	run "$CCS_BIN" gc --yes
	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'alive' ]
}

@test "gc --yes のあと作業枠が使えるようになる" {
	export CCS_SCRATCH_SLOTS=1
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]

	# 枠が 1 本しかないので、次は取れない
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 1 ]

	ccs_kill_claude_of tmp-1
	run "$CCS_BIN" gc --yes
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'tmp-1' ]
}
