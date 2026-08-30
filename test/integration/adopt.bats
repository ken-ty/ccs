#!/usr/bin/env bats
#
# ccs adopt — ccs 管轄外のセッションを引き取る
#
# **プロセスは移せない。** tmux セッションを rename してもレジストリの `tmux`
# 欄は追随しない（実測 2026-08-30）ので、`cc/<slug>` を名乗るには claude が
# そのペインの中で起動するしかない。だから引き取りは**会話の引き取り**になる。
#
# **元が生きている間は絶対に立てない。** 実測 2026-08-30 ── `claude --resume`
# は、その会話を別プロセスが握っていても拒まない。同じ sessionId のレジストリが
# 2 件並び、しかも引き取った側は `bridgeSessionId` が null になる（先に居るほうが
# Remote Control を譲らない）。**成功したように見えて、アプリからもハブからも
# 見えないセッションができる。** ここの門はそのための必須の装置で、
# 「頼んだのに終わらなかった」ときに何もしないことまで含めて見張る。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15
	export CCS_ADOPT_TIMEOUT=10
	# 戻す先の会話が無ければ引き取れない。**tmux サーバの環境は起動時に
	# 固定される**ので、最初の ccs 実行より前に export する。
	export FAKE_CLAUDE_TRANSCRIPT=1
	# **pid はファイルに書く。変数では届かない。** `_outsider` は
	# コマンド置換ごしに呼ぶので、そこでの代入はサブシェルに閉じる ──
	# 変数に溜めると teardown から見えず、外部セッション役が残る。
	# **残ると bats が終われない**（子プロセスを待つため。実測: 全 8 件が
	# ok になったあと、bats だけが返ってこない形で現れた）。
	CCS_OUTSIDERS="${CCS_TEST_TMP}/outsiders"
	export CCS_OUTSIDERS
	: >"$CCS_OUTSIDERS"
}

teardown() {
	# **KILL で落とす。** `FAKE_CLAUDE_IGNORE_TERM` を使う test が居るので、
	# TERM を送って `wait` すると**永遠に返ってこない**。後片付けに作法は要らない。
	for _p in $(cat "${CCS_OUTSIDERS:-/dev/null}" 2>/dev/null); do
		kill -KILL "$_p" 2>/dev/null || true
		wait "$_p" 2>/dev/null || true
	done
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

# ccs 管轄外の生きているセッションを 1 本立てて、その pid を返す。
#
# **tmux の外で fake-claude を動かすだけ。** スタブは tmux の中にいるときしか
# `tmux` 欄を書かないので、外で動かせばそれがそのまま「管轄外」になる ──
# アプリや VS Code から開いたセッションと同じ形（design.md §2.1 の実測で、
# レジストリは `cli`（tmux 有り）と `claude-desktop` / `claude-vscode`
# （tmux 無し）に二分されることが確認されている）。
#
# **`exec` で置き換える。** 挟まないとサブシェルが親に残り、`$!` が
# レジストリの pid と食い違う ── 「引き取ったあと元が消えた」を pid で
# 確かめられなくなる。
#
# **fd をすべて手放す（特に `3>&-`）。** bats は fd 3 で結果を集めるので、
# 握ったままのバックグラウンドプロセスが居ると **bats が終われずに固まる**
# （AGENTS.md「teardown は呼ばれないことがある」の落とし穴と同じもの。
# 実測: これを落として 10 分のタイムアウトを 1 度踏んだ）。
_outsider() {
	local _dir=$1 _uuid=$2 _name=${3:-outsider}
	mkdir -p "$_dir"
	(
		cd "$_dir" || exit 1
		unset TMUX TMUX_PANE
		exec "$CCS_FAKE_CLAUDE" -n "$_name" --session-id "$_uuid"
	) </dev/null >/dev/null 2>&1 3>&- &
	local _p=$!
	printf '%s\n' "$_p" >>"$CCS_OUTSIDERS"
	ccs_wait_until 10 test -f "${CCS_SESSIONS_DIR}/${_p}.json" || return 1
	printf '%s' "$_p"
}

_uuid() {
	printf '00000000-0000-4000-8000-0000000000%02d' "$1"
}

@test "adopt: 管轄外のセッションを同じ会話のまま引き取る" {
	local _dir="${CCS_TEST_TMP}/work/outside" _u
	_u=$(_uuid 1)
	local _pid
	_pid=$(_outsider "$_dir" "$_u")

	run --separate-stderr "$CCS_BIN" adopt "$_dir"
	[ "$status" -eq 0 ]

	# **同じ会話であること。** ここがずれると「引き取った」ように見えて
	# 別の会話が立っているだけになる。
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" = "$_u" ]
	[ "$(printf '%s' "$output" | jq -r '.slug')" = 'outside' ]

	ccs_tmux has-session -t '=cc/outside'

	# **元は終わっている。** 2 本が同じ会話を握ったままになっていない。
	run kill -0 "$_pid"
	[ "$status" -ne 0 ]
}

@test "adopt: 引き取ったあとは ccs ls に出る" {
	local _dir="${CCS_TEST_TMP}/work/outside" _u
	_u=$(_uuid 2)
	_outsider "$_dir" "$_u" >/dev/null

	"$CCS_BIN" adopt "$_dir" >/dev/null

	run --separate-stderr "$CCS_BIN" ls --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.[] | select(.slug=="outside") | .sessionId')" = "$_u" ]
}

@test "adopt: 既に管轄下なら何もしない（冪等）" {
	mkdir -p "${CCS_TEST_TMP}/work/mine"
	"$CCS_BIN" new "${CCS_TEST_TMP}/work/mine" >/dev/null

	run --separate-stderr "$CCS_BIN" adopt "${CCS_TEST_TMP}/work/mine"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.created')" = 'false' ]
	[[ "$stderr" == *"既に ccs の管轄"* ]] || return 1
}

@test "adopt: 引き取れる相手が居なければ落ちる" {
	mkdir -p "${CCS_TEST_TMP}/work/empty"

	run --separate-stderr "$CCS_BIN" adopt "${CCS_TEST_TMP}/work/empty"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"引き取れるセッションが見つかりません"* ]] || return 1
	run ccs_tmux has-session -t '=cc/empty'
	[ "$status" -ne 0 ]
}

@test "adopt: 同じ場所に 2 本居たら決めずに止まる" {
	local _dir="${CCS_TEST_TMP}/work/outside"
	_outsider "$_dir" "$(_uuid 3)" 'first' >/dev/null
	_outsider "$_dir" "$(_uuid 4)" 'second' >/dev/null

	run --separate-stderr "$CCS_BIN" adopt "$_dir"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"--pid"* ]] || return 1

	# **どちらも畳んでいない。** 決められないときに片方を殺さない。
	run ccs_tmux has-session -t '=cc/outside'
	[ "$status" -ne 0 ]
}

@test "adopt --pid: 2 本居ても名指しなら引き取れる" {
	local _dir="${CCS_TEST_TMP}/work/outside" _u
	_u=$(_uuid 5)
	local _keep _take
	_keep=$(_outsider "$_dir" "$(_uuid 6)" 'keep')
	_take=$(_outsider "$_dir" "$_u" 'take')

	run --separate-stderr "$CCS_BIN" adopt "$_dir" --pid "$_take"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.sessionId')" = "$_u" ]

	# **名指ししなかったほうは生きている。**
	kill -0 "$_keep"
}

@test "adopt: 会話ログが無ければ引き取らない" {
	# **戻す先が無い。** まだ 1 度もやり取りしていないセッションは
	# 会話ログを持たない（本物も最初のやり取りまで書かない）。
	local _dir="${CCS_TEST_TMP}/work/outside"
	FAKE_CLAUDE_TRANSCRIPT='' _outsider "$_dir" "$(_uuid 7)" >/dev/null

	run --separate-stderr "$CCS_BIN" adopt "$_dir"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"会話ログがありません"* ]] || return 1
	run ccs_tmux has-session -t '=cc/outside'
	[ "$status" -ne 0 ]
}

@test "adopt: 頼んでも終わらなければ何もしない" {
	# **ここが本体の門。** 元が生きたまま `--resume` すると、拒まれずに
	# 2 本目が立ち、しかも Remote Control が付かない（実測 2026-08-30）。
	local _dir="${CCS_TEST_TMP}/work/outside"
	export FAKE_CLAUDE_IGNORE_TERM=1
	export CCS_ADOPT_TIMEOUT=2
	local _pid
	_pid=$(_outsider "$_dir" "$(_uuid 8)")

	run --separate-stderr "$CCS_BIN" adopt "$_dir"
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"何もしていません"* ]] || return 1

	# **立てていない。** 2 本目を作らないことが、この門の存在理由。
	run ccs_tmux has-session -t '=cc/outside'
	[ "$status" -ne 0 ]
	# **元はそのまま生きている。**
	kill -0 "$_pid"
}
