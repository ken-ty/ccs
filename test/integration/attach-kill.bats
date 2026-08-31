#!/usr/bin/env bats
#
# ccs attach / ccs kill
#
# attach は端末を乗っ取るので、本物を実行するとテストが固まる。
# tmux を「引数を記録するだけのもの」に差し替えて、何を呼んだかを見る。
# kill は副作用が実際に起きてほしいので、本物の tmux で確かめる。

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

# tmux を「引数をログに書くだけ」に差し替える。
# has-session だけは本当のことを答えないと分岐が試せないので、
# 記録用の一覧ファイルを見る。
_stub_tmux_recorder() {
	printf '%s\n' "$@" >"${CCS_TEST_TMP}/existing-sessions.txt"
	{
		echo '#!/bin/sh'
		echo "echo \"\$@\" >>'${CCS_TEST_TMP}/tmux.log'"
		echo 'case "$1" in'
		echo 'has-session)'
		echo "  grep -qx \"\${3#=}\" '${CCS_TEST_TMP}/existing-sessions.txt' && exit 0"
		echo '  exit 1 ;;'
		echo 'list-sessions)'
		echo "  cat '${CCS_TEST_TMP}/existing-sessions.txt' ;;"
		echo 'esac'
		echo 'exit 0'
	} >"${CCS_STUB_BIN}/tmux-recorder"
	chmod +x "${CCS_STUB_BIN}/tmux-recorder"
	export CCS_TMUX_BIN="${CCS_STUB_BIN}/tmux-recorder"
}

# --- attach ----------------------------------------------------------------

@test "attach: tmux の外なら attach-session を呼ぶ" {
	_stub_tmux_recorder 'cc/myrepo'
	run env -u TMUX "$CCS_BIN" attach myrepo
	[ "$status" -eq 0 ]

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" == *"attach-session -t cc/myrepo"* ]] || return 1
}

@test "attach: tmux の中なら switch-client を呼ぶ" {
	# 入れ子の attach は tmux が拒む。ハブが tmux の中で動いていることは
	# 十分ありうるので、ここを間違えると「ハブから乗り込めない」になる。
	_stub_tmux_recorder 'cc/myrepo'
	run env TMUX='/tmp/fake,123,0' "$CCS_BIN" attach myrepo
	[ "$status" -eq 0 ]

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" == *"switch-client -t cc/myrepo"* ]] || return 1
	[[ "$output" != *"attach-session"* ]] || return 1
}

@test "attach: 無い slug なら候補を出して落ちる" {
	_new myrepo >/dev/null
	_new other >/dev/null

	run "$CCS_BIN" attach nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"ありません"* ]] || return 1
	[[ "$output" == *"myrepo"* ]] || return 1
	[[ "$output" == *"other"* ]] || return 1
}

@test "attach: 何も立っていなければ立て方を出す" {
	run "$CCS_BIN" attach nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs new"* ]] || return 1
}

# --- attach（slug を省いて番号で選ぶ） --------------------------------------
#
# **bats はパイプ越しに走るので `[ -t 0 ]` が偽になり、対話の枝に入らない。**
# ここだけ pty を用意して、本物の端末から選んだときの挙動を見る。

_pick() {
	run "${CCS_REPO_ROOT}/test/fixtures/pty-run.py" "$1" -- \
		env -u TMUX "$CCS_BIN" attach
}

@test "attach: slug を省くと番号で選ばせ、選んだものに乗り込む" {
	_stub_tmux_recorder 'cc/aaa' 'cc/bbb'

	_pick 2
	[ "$status" -eq 0 ]
	[[ "$output" == *"1) aaa"* ]] || return 1
	[[ "$output" == *"2) bbb"* ]] || return 1

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" == *"attach-session -t cc/bbb"* ]] || return 1
	[[ "$output" != *"attach-session -t cc/aaa"* ]] || return 1
}

@test "attach: 番号を選ばず Enter なら、何もせず 0 で終わる" {
	# **中止は失敗ではない。** 一覧を見て気が変わっただけなので、
	# 呼び出し側に失敗として伝えない。
	_stub_tmux_recorder 'cc/aaa'

	_pick ''
	[ "$status" -eq 0 ]

	run cat "${CCS_TEST_TMP}/tmux.log"
	[[ "$output" != *"attach-session"* ]] || return 1
	[[ "$output" != *"switch-client"* ]] || return 1
}

@test "attach: 番号でないものを選んだら 2" {
	_stub_tmux_recorder 'cc/aaa'

	_pick nope
	[ "$status" -eq 2 ]
	[[ "$output" == *"番号ではありません"* ]] || return 1
}

@test "attach: 範囲の外の番号を選んだら 2" {
	_stub_tmux_recorder 'cc/aaa' 'cc/bbb'

	_pick 9
	[ "$status" -eq 2 ]
	[[ "$output" == *"1〜2"* ]] || return 1
}

@test "attach: 何も立っていなければ立て方を出して 1" {
	_pick 1
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs new"* ]] || return 1
}

@test "attach: slug が無ければ 2" {
	run "$CCS_BIN" attach
	[ "$status" -eq 2 ]
}

# --- kill ------------------------------------------------------------------

@test "kill: tmux セッションを畳む" {
	_new myrepo >/dev/null
	ccs_tmux has-session -t '=cc/myrepo'

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill: 復帰用の uuid と cd 先を出す" {
	# **v1 に resume が無いので、これが同じ会話に戻る唯一の手掛かり。**
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
	[[ "$output" == *"myrepo"* ]] || return 1
}

@test "kill: claude が終了していても uuid を出す" {
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')
	ccs_kill_claude_of myrepo

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
}

@test "kill: 作業中なら畳まない" {
	# ハブのエージェントが打ち間違えることを想定する。会話は transcript に
	# 残るが、走っていたコマンドの途中経過は戻らない。
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 1 ]
	[[ "$output" == *"作業中"* ]] || return 1
	[[ "$output" == *"--force"* ]] || return 1

	ccs_tmux has-session -t '=cc/myrepo'
}

@test "kill --force: 作業中でも畳む" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill --force myrepo
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill -f: 短い形も効く" {
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	run "$CCS_BIN" kill -f myrepo
	[ "$status" -eq 0 ]
}

@test "kill: idle なら --force なしで畳める" {
	_new myrepo >/dev/null
	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]
}

@test "kill: 他のセッションを巻き込まない" {
	_new keep >/dev/null
	_new drop >/dev/null

	run "$CCS_BIN" kill drop
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/keep'
	run ccs_tmux has-session -t '=cc/drop'
	[ "$status" -ne 0 ]
}

@test "kill: 似た名前を巻き込まない" {
	_new x01 >/dev/null
	_new x011 >/dev/null

	run "$CCS_BIN" kill x01
	[ "$status" -eq 0 ]

	ccs_tmux has-session -t '=cc/x011'
}

@test "kill: 無い slug なら候補を出して落ちる" {
	_new myrepo >/dev/null

	run "$CCS_BIN" kill nosuch
	[ "$status" -eq 1 ]
	[[ "$output" == *"myrepo"* ]] || return 1
}

@test "kill: slug が無ければ 2" {
	run "$CCS_BIN" kill
	[ "$status" -eq 2 ]
}

@test "kill: slug が 2 つあれば 2" {
	run "$CCS_BIN" kill a b
	[ "$status" -eq 2 ]
}

@test "kill: 知らないオプションは 2" {
	run "$CCS_BIN" kill --nope myrepo
	[ "$status" -eq 2 ]
}

# --- 畳んだあと ------------------------------------------------------------

@test "kill したものは ls から消える" {
	_new keep >/dev/null
	_new drop >/dev/null

	run "$CCS_BIN" kill drop
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
	[ "$(echo "$output" | jq -r '.[0].slug')" = 'keep' ]
}

@test "kill して立て直すと新しいセッションになる" {
	_out=$(_new myrepo)
	_first=$(echo "$_out" | jq -r '.sessionId')

	run "$CCS_BIN" kill myrepo
	[ "$status" -eq 0 ]

	_out2=$(_new myrepo)
	[ "$(echo "$_out2" | jq -r '.created')" = 'true' ]
	[ "$(echo "$_out2" | jq -r '.sessionId')" != "$_first" ]
}

@test "kill tmp-<id> で作業枠の本数が空く" {
	# **枠は使い回さない**（I2b）ので、畳んで空くのは「同時に立てられる
	# 本数」のほう。id は毎回変わる。
	export CCS_SCRATCH_SLOTS=1
	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	local _slug
	_slug=$(echo "$output" | jq -r '.slug')

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 1 ]

	run "$CCS_BIN" kill "$_slug"
	[ "$status" -eq 0 ]

	run --separate-stderr "$CCS_BIN" new tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" != "$_slug" ]
}

# --- kill は worktree を消さない（W3、ADR-0003 決定 7）----------------------

@test "kill: worktree のセッションは片付け先を案内する" {
	# **畳んだ時点がこのパスを引ける最後の機会。** あとから探すには
	# git の一覧を舐めることになるので、その場で 1 行出す。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" kill 'x01--topic'
	[ "$status" -eq 0 ]
	[[ "$output" == *"worktree は残しています"* ]] || return 1
	[[ "$output" == *"ccs gc"* ]] || return 1
}

@test "kill: worktree は実際に残る" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r '.path')

	run "$CCS_BIN" kill 'x01--topic'
	[ "$status" -eq 0 ]
	[ -d "$_p" ]
	run git -C "$_repo" branch --list topic
	[[ "$output" == *"topic"* ]] || return 1
}

@test "kill: worktree でないセッションには案内を出さない" {
	_new plain >/dev/null

	run "$CCS_BIN" kill plain
	[ "$status" -eq 0 ]
	[[ "$output" != *"worktree は残しています"* ]] || return 1
}

# --- 自分で終わる（--self） ------------------------------------------------
#
# **アプリでアーカイブしても tmux のセッションは残る。** アーカイブは会話一覧の
# 操作で、CLI のプロセスは生き続ける ── `ccs` が idle を誤読しているのではなく、
# 本当に生きている（実測 2026-08-28。bin/ccs の `kill_self_slug` の上）。だから
# 終わる意思のあるセッションが自分で終わる口を用意する。
#
# **「中から呼んだ」ことは、ここでは env で作る。** 本当にペインの中から実行すると
# 自分ごと消えるので、テストのプロセスが結果を見られない。`current_tmux_session` が
# 見るのは `$TMUX` / `$TMUX_PANE` とソケットの一致だけなので、そこを揃えれば
# 判定は同じ経路を通る。**「自分を殺したプロセスが最後まで走れない」ところだけは
# ここでは再現できない**ので、それは docs/hands-on.md の手動確認が受け持つ。

# そのセッションの中から呼んだように見せる env を組み立てる。
_inside() {
	local sock pane
	sock=$(ccs_tmux display-message -p '#{socket_path}')
	pane=$(ccs_tmux list-panes -t "=cc/$1" -F '#{pane_id}' | head -1)
	printf 'TMUX=%s,1,0\nTMUX_PANE=%s\n' "$sock" "$pane"
}

# `ccs kill --self` を、そのセッションの中から呼んだ形で実行する。
_run_self() {
	local slug=$1
	shift
	# shellcheck disable=SC2046  # 1 行 1 変数なので分割してよい
	run env $(_inside "$slug") "$CCS_BIN" kill --self "$@"
}

@test "kill --self: slug を打たずに自分を畳む" {
	_new myrepo >/dev/null
	ccs_tmux has-session -t '=cc/myrepo'

	_run_self myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"cc/myrepo を畳みました"* ]] || return 1

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill --self: 作業中でも畳める（自分が作業中だから）" {
	# **この ccs を動かしているのが自分自身**なので、自分の status は必ず
	# 作業中になる。ここに working の門を掛けると --self は常に断られる。
	export FAKE_CLAUDE_STATUS=working
	_new myrepo >/dev/null

	_run_self myrepo
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/myrepo'
	[ "$status" -ne 0 ]
}

@test "kill --self: 報告は畳む前に出し切る" {
	# 畳んだあとに置いた処理は動かない（ペインごと消える）。順序が仕様。
	_out=$(_new myrepo)
	_id=$(echo "$_out" | jq -r '.sessionId')

	_run_self myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_id}"* ]] || return 1
}

@test "kill --self: 未コミットの変更があれば断る" {
	# ファイルは消えないが、終わると言っている本人に「本当に終わったのか」を
	# 訊けるのは作業ツリーの状態だけ。追跡していないファイルも数える。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	run --separate-stderr "$CCS_BIN" new x01
	[ "$status" -eq 0 ]
	printf 'wip\n' >"${_repo}/wip.txt"

	_run_self x01
	[ "$status" -eq 1 ]
	[[ "$output" == *"未コミット"* ]] || return 1
	[[ "$output" == *"--force"* ]] || return 1

	ccs_tmux has-session -t '=cc/x01'
}

@test "kill --self --force: 未コミットでも畳む" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	run --separate-stderr "$CCS_BIN" new x01
	[ "$status" -eq 0 ]
	printf 'wip\n' >"${_repo}/wip.txt"

	_run_self x01 --force
	[ "$status" -eq 0 ]

	run ccs_tmux has-session -t '=cc/x01'
	[ "$status" -ne 0 ]
}

@test "kill --self: git の管理下でなければ門は掛からない" {
	# 使い捨ての作業枠は git リポジトリではない。ここで断ると畳めなくなる。
	_new myrepo >/dev/null

	_run_self myrepo
	[ "$status" -eq 0 ]
}

@test "kill --self: worktree は残し、片付け先を案内する" {
	# **kill と同じ方針。** 自分で終わったからといって作業ツリーは消さない。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r '.path')

	_run_self 'x01--topic'
	[ "$status" -eq 0 ]
	[[ "$output" == *"worktree は残しています"* ]] || return 1
	[ -d "$_p" ]
}

@test "kill --self: hub は畳ませない" {
	# **hub が落ちると、スマホから ccs を叩く経路そのものが消える。**
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]

	_run_self hub
	[ "$status" -eq 1 ]
	[[ "$output" == *"hub"* ]] || return 1

	ccs_tmux has-session -t '=cc/hub'
}

@test "kill --self --force: hub は --force でも畳ませない" {
	export CCS_HUB_HOME="${CCS_TEST_TMP}/hub"
	run "$CCS_BIN" hub up
	[ "$status" -eq 0 ]

	_run_self hub --force
	[ "$status" -eq 1 ]

	ccs_tmux has-session -t '=cc/hub'
}

# --- 管轄外のセッションが自分で終わる（--self、A2） ------------------------
#
# **`cc/` のペインを持たないセッションにも、終わる意思はある。** アプリや
# VS Code から開いたものは ccs 管轄外なので `kill_self_slug` が成立しないが、
# `--self` が言っているのは「自分が終わる」であって「ccs が立てたものを畳む」
# ではない。`ccs adopt`（A1）が「引き取るので閉じて」と頼んだときの受け皿。
#
# **claude 役は「ccs を呼ぶ親プロセス」で作る。** `self_registry_file` は
# 祖先の pid でレジストリを引くので、親が自分のぶんの項目を書いてから ccs を
# 呼べば、本物と同じ経路をそのまま通る。SIGTERM を trap して受け取ったことを
# 記録するので、畳まれても最後まで走れる（**本物はここで死ぬ**ので、
# 「殺したプロセスが走り切れない」ところだけは docs/hands-on.md が受け持つ）。

_SELF_UUID='11111111-2222-3333-4444-555555555555'

_run_self_external() {
	local _cwd=$1
	shift
	cat >"${CCS_TEST_TMP}/outsider.sh" <<EOF
unset TMUX TMUX_PANE
trap 'echo GOT-TERM' TERM
printf '{"pid":%d,"sessionId":"%s","cwd":"%s","name":"%s"}\n' \\
	"\$\$" '${_SELF_UUID}' '${_cwd}' 'outsider' >"\${CCS_SESSIONS_DIR}/\$\$.json"
'${CCS_BIN}' kill --self $*
echo "ccs=\$?"
EOF
	run sh "${CCS_TEST_TMP}/outsider.sh"
}

@test "kill --self: 管轄外のセッションでも自分を畳める" {
	local _cwd="${CCS_TEST_TMP}/outside"
	mkdir -p "$_cwd"

	_run_self_external "$_cwd"
	[ "$status" -eq 0 ]
	[[ "$output" == *"outsider を畳みました"* ]] || return 1
	[[ "$output" == *"ccs=0"* ]] || return 1
	# SIGTERM が本当に届いた。**畳んだと言うだけでは終わっていない。**
	[[ "$output" == *"GOT-TERM"* ]] || return 1
}

@test "kill --self: 管轄外でも uuid を添える（戻る手掛かりを消さない）" {
	local _cwd="${CCS_TEST_TMP}/outside"
	mkdir -p "$_cwd"

	_run_self_external "$_cwd"
	[ "$status" -eq 0 ]
	[[ "$output" == *"claude --resume ${_SELF_UUID}"* ]] || return 1
}

@test "kill --self: 管轄外でも未コミットの変更があれば断る" {
	local _repo="${CCS_TEST_TMP}/outside-repo"
	ccs_make_git_repo "$_repo"
	printf 'wip\n' >"${_repo}/wip.txt"

	_run_self_external "$_repo"
	[[ "$output" == *"未コミットの変更があります"* ]] || return 1
	[[ "$output" == *"ccs=1"* ]] || return 1
	# **断ったなら畳んでいない。**
	[[ "$output" != *"GOT-TERM"* ]] || return 1
}

@test "kill --self --force: 管轄外で未コミットでも畳む" {
	local _repo="${CCS_TEST_TMP}/outside-repo"
	ccs_make_git_repo "$_repo"
	printf 'wip\n' >"${_repo}/wip.txt"

	_run_self_external "$_repo" --force
	[ "$status" -eq 0 ]
	[[ "$output" == *"GOT-TERM"* ]] || return 1
}

@test "kill --self: 祖先でないレジストリは掴まない" {
	# **ここが `CLAUDE_PID` を信じない理由。** レジストリに項目があるだけの
	# 他人を「自分」と読むと、`--self` が他人を畳む道具になる。祖先を辿る限り
	# 見つかるものは定義上そのプロセスの親なので、取り違えが起きない。
	sleep 30 &
	local _other=$!
	# 畳んだときのジョブ通知でテスト出力を汚さない。
	disown "$_other" 2>/dev/null || true
	printf '{"pid":%d,"sessionId":"%s","cwd":"%s","name":"%s"}\n' \
		"$_other" "$_SELF_UUID" "$CCS_TEST_TMP" 'someone-else' \
		>"${CCS_SESSIONS_DIR}/${_other}.json"

	run --separate-stderr env -u TMUX -u TMUX_PANE "$CCS_BIN" kill --self
	[ "$status" -eq 2 ]
	[[ "$stderr" == *"--self"* ]] || return 1

	# **巻き添えにしていない。**
	kill -0 "$_other"
	kill "$_other" 2>/dev/null || true
}
