#!/usr/bin/env bats
#
# ccs new <repo>@<branch> — worktree を切ってそこに立てる。
#
# **本命は「同じリポジトリに 2 本のセッションが同時に立つ」こと**
# （docs/design.md §9.1）。slug がリポジトリ名である限り `ccs new x01` は
# 冪等に 1 本目を返すので、これがタスク単位でセッションを立てる唯一の道。
#
# git は本物を使う。worktree の生成は git の挙動そのものなので、スタブに
# すると「スタブが正しいこと」しか確かめられない。claude と違って課金も
# ネットワークも無い。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15

	CCS_TEST_REPO="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$CCS_TEST_REPO"
	ccs_stub_ghq "$CCS_TEST_REPO"
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

# --- 立てる ------------------------------------------------------------------

@test "worktree: セッションを立て、worktree を作る" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	[ "$(echo "$output" | jq -r '.slug')" = 'x01--topic' ]
	[ "$(echo "$output" | jq -r '.tmux')" = 'cc/x01--topic' ]
	[ "$(echo "$output" | jq -r '.created')" = 'true' ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ -d "$_p" ]
	# git の worktree として登録されていること
	run git -C "$_p" rev-parse --abbrev-ref HEAD
	[ "$output" = 'topic' ]
}

@test "worktree: 元のリポジトリの中身が入っている" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ -f "${_p}/README.md" ]
}

@test "worktree: 元のリポジトリは worktree を認識している" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	run git -C "$CCS_TEST_REPO" worktree list
	[[ "$output" == *"topic"* ]] || return 1
}

# --- 本命: 同じリポジトリに 2 本 ---------------------------------------------

@test "worktree: 同じリポジトリに 2 本のセッションが立つ" {
	run --separate-stderr "$CCS_BIN" new 'x01@one'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'x01@two'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
	[ "$(echo "$output" | jq -r '[.[].slug] | sort | join(",")')" = 'x01--one,x01--two' ]
}

@test "worktree: 素の指定と worktree の指定は別セッションになる" {
	run --separate-stderr "$CCS_BIN" new 'x01'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '2' ]
}

# --- 冪等性 ------------------------------------------------------------------

@test "worktree: 同じ指定は既存を返し、作り直さない" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _first=$output

	# worktree に印を置く。作り直されたら消える。
	local _p
	_p=$(echo "$_first" | jq -r '.path')
	touch "${_p}/MARK"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]
	[ "$(echo "$output" | jq -r '.sessionId')" = "$(echo "$_first" | jq -r '.sessionId')" ]
	[ -f "${_p}/MARK" ]
}

@test "worktree: 打ち方が違っても同じセッションに落ちる" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	run --separate-stderr "$CCS_BIN" new 'o/x01@topic'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]

	run "$CCS_BIN" ls --json
	[ "$(echo "$output" | jq -r 'length')" = '1' ]
}

# --- 既存ブランチ ------------------------------------------------------------

@test "worktree: 既存のブランチはそれを開く（作り直さない）" {
	git -C "$CCS_TEST_REPO" branch already
	printf 'x\n' >"${CCS_TEST_REPO}/ONLY_ON_MAIN"

	run --separate-stderr "$CCS_BIN" new 'x01@already'
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	run git -C "$_p" rev-parse --abbrev-ref HEAD
	[ "$output" = 'already' ]
}

@test "worktree: 既存ブランチを開いたことを stderr で伝える" {
	git -C "$CCS_TEST_REPO" branch already
	run --separate-stderr "$CCS_BIN" new 'x01@already'
	[[ "$stderr" == *"既存のブランチ"* ]] || return 1
}

@test "worktree: 新しいブランチを作ったことを stderr で伝える" {
	run --separate-stderr "$CCS_BIN" new 'x01@brandnew'
	[[ "$stderr" == *"作って"* ]] || return 1
	# 追跡されていないものが付いてこないことも言う
	[[ "$stderr" == *"追跡されていない"* ]] || return 1
}

# --- trust -------------------------------------------------------------------

@test "worktree: ghq 配下のリポジトリの worktree は自動で信頼する" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	run jq -r --arg p "$_p" '.projects[$p].hasTrustDialogAccepted' "$CCS_TRUST_FILE"
	[ "$output" = 'true' ]
}

@test "worktree: ghq の外のリポジトリの worktree は自動で信頼しない" {
	local _outside="${CCS_TEST_TMP}/outside/y02"
	ccs_make_git_repo "$_outside"

	run --separate-stderr "$CCS_BIN" new "${_outside}@topic"
	[ "$status" -eq 0 ]

	local _p
	_p=$(echo "$output" | jq -r '.path')
	# **信頼確認が出ることを先に伝えている**こと（黙って立てると 30 秒待たされる）
	[[ "$stderr" == *"まだ信頼されていません"* ]] || return 1

	# trust ファイルは、誰も承認していなければ作られてすらいない。
	if [ -f "$CCS_TRUST_FILE" ]; then
		run jq -r --arg p "$_p" '.projects[$p].hasTrustDialogAccepted // "absent"' "$CCS_TRUST_FILE"
		[ "$output" = 'absent' ]
	fi
}

# --- 異常系 ------------------------------------------------------------------

@test "worktree: git リポジトリでなければ落ちる" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/notgit"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/notgit"

	run --separate-stderr "$CCS_BIN" new 'notgit@topic'
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"git リポジトリではありません"* ]] || return 1
}

@test "worktree: 失敗しても stdout を汚さない" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/notgit"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/notgit"

	run --separate-stderr "$CCS_BIN" new 'notgit@topic'
	# **C5 以降、失敗時の stdout は 1 行の JSON。** 人間向けの文は混ぜない。
	printf '%s' "$output" | jq -e . >/dev/null
	[[ "$output" != *"ccs:"* ]] || return 1
}

@test "worktree: 同じブランチが他所で開かれていれば、理由を出して落ちる" {
	# ccs の外で同じブランチを開いておく。git は 1 ブランチ 1 worktree しか
	# 許さないので、ccs はここで必ず弾かれる。**黙って失敗させない**のが要件。
	git -C "$CCS_TEST_REPO" worktree add -b topic "${CCS_TEST_TMP}/elsewhere" >/dev/null 2>&1

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 1 ]
	[[ "$stderr" == *"worktree を作れませんでした"* ]] || return 1
	# 次の手が分かること
	[[ "$stderr" == *"worktree list"* ]] || return 1
	printf '%s' "$output" | jq -e . >/dev/null
	[[ "$output" != *"ccs:"* ]] || return 1
}

# --- 素性を git から引く（ADR-0003 決定 3、W1） -------------------------------

@test "worktree: 実パスで指した worktree も自動で信頼する" {
	# **以前はここが割れていた。** 信頼の判定が「解決のときに立てた変数」に
	# 依存していたので、`<repo>@<branch>` と綴ったときだけ効き、同じ
	# ディレクトリを実パスで指すと 30 秒の信頼確認に落ちていた
	# （ADR-0002 表 #9）。
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r '.path')
	"$CCS_BIN" kill --force 'x01--topic'
	# trust を消して、実パス経由でもう一度立てる
	jq 'del(.projects)' "$CCS_TRUST_FILE" >"${CCS_TRUST_FILE}.new"
	mv "${CCS_TRUST_FILE}.new" "$CCS_TRUST_FILE"

	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]
	[[ "$stderr" != *"まだ信頼されていません"* ]] || return 1
	run jq -r --arg p "$_p" '.projects[$p].hasTrustDialogAccepted' "$CCS_TRUST_FILE"
	[ "$output" = 'true' ]
}

@test "worktree: ghq の外のリポジトリの worktree は実パスでも信頼しない" {
	local _outside="${CCS_TEST_TMP}/outside/y02"
	ccs_make_git_repo "$_outside"
	local _wt="${CCS_TEST_TMP}/outside-wt"
	git -C "$_outside" worktree add -q "$_wt" -b topic

	run --separate-stderr "$CCS_BIN" new "$_wt"
	[ "$status" -eq 0 ]
	[[ "$stderr" == *"まだ信頼されていません"* ]] || return 1
}

@test "worktree: 実パスで立てても <repo>--<branch> のセッションになる" {
	# 打ち方が違っても同じ slug に落ちること ＝ 2 本目が立たないこと。
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r '.path')

	# 同じ作業ツリーを実パスで頼む → 既存を返す（新規に立てない）
	run --separate-stderr "$CCS_BIN" new "$_p"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'x01--topic' ]
	[ "$(echo "$output" | jq -r '.created')" = 'false' ]

	# tmux に 1 本しか立っていないこと
	run "$CCS_BIN" ls
	[ "$(echo "$output" | grep -c 'x01--topic')" -eq 1 ]
}

# --- リポジトリ配下に置く（ADR-0003 決定 1・2・5、W2） -------------------------

@test "worktree: リポジトリ配下の .worktrees/ に作る" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r '.path')
	[ "$_p" = "$(cd "$CCS_TEST_REPO" && pwd -P)/.worktrees/topic" ]
	[ -d "$_p" ]
}

@test "worktree: 親の git status を汚さない" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	# **これが方針の成否を分ける。** 塞がないと `?? .worktrees/` が出て、
	# `git add -A` が gitlink として拾う。
	run git -C "$CCS_TEST_REPO" status --porcelain
	[ -z "$output" ]
}

@test "worktree: .git/info/exclude に書く（.gitignore は触らない）" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	run grep -qxF '/.worktrees/' "${CCS_TEST_REPO}/.git/info/exclude"
	[ "$status" -eq 0 ]
	# **追跡されるファイルを増やさない**（先方のリポジトリに差分を作らない）
	[ ! -f "${CCS_TEST_REPO}/.gitignore" ]
}

@test "worktree: exclude は 2 度書かない（冪等）" {
	"$CCS_BIN" new 'x01@topic' >/dev/null 2>&1
	"$CCS_BIN" kill --force 'x01--topic' >/dev/null 2>&1
	"$CCS_BIN" new 'x01@other' >/dev/null 2>&1

	run grep -cxF '/.worktrees/' "${CCS_TEST_REPO}/.git/info/exclude"
	[ "$output" = '1' ]
}

@test "worktree: 末尾に改行の無い exclude を壊さない" {
	# 追記が最終行に連結されると、**両方の行が効かなくなる**。
	printf '*.log' >"${CCS_TEST_REPO}/.git/info/exclude"

	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]

	run grep -qxF '*.log' "${CCS_TEST_REPO}/.git/info/exclude"
	[ "$status" -eq 0 ]
	run grep -qxF '/.worktrees/' "${CCS_TEST_REPO}/.git/info/exclude"
	[ "$status" -eq 0 ]
}

@test "worktree: worktree の中も汚れていない（exclude は共有される）" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r '.path')

	# `--git-common-dir` は全 worktree 共有なので、1 回書けば入れ子も塞がる。
	mkdir -p "${_p}/.worktrees/dummy"
	run git -C "$_p" status --porcelain
	[ -z "$output" ]
}

@test "worktree: 同じディレクトリに別のブランチが座っていれば落ちる" {
	# `branch_slug` は / を - に潰すので、feat/foo と feat-foo は
	# **共存できるのに同じディレクトリに落ちる**（git は禁じない）。
	"$CCS_BIN" new 'x01@feat-foo' >/dev/null 2>&1
	"$CCS_BIN" kill --force 'x01--feat-foo' >/dev/null 2>&1

	run "$CCS_BIN" new 'x01@feat/foo'
	[ "$status" -ne 0 ]
	[[ "$output" == *"別のブランチの worktree があります"* ]] || return 1
	[[ "$output" == *"feat-foo"* ]] || return 1
}

@test "worktree: .worktrees を追跡しているリポジトリでは落ちる" {
	mkdir -p "${CCS_TEST_REPO}/.worktrees"
	printf 'mine\n' >"${CCS_TEST_REPO}/.worktrees/KEEP"
	git -C "$CCS_TEST_REPO" add -A
	git -C "$CCS_TEST_REPO" commit -q -m 'user owns .worktrees'

	# そこは利用者の場所。exclude で隠さず、黙って中に作らない。
	run "$CCS_BIN" new 'x01@topic'
	[ "$status" -ne 0 ]
	[[ "$output" == *"既にこのリポジトリで追跡されています"* ]] || return 1
	[ -f "${CCS_TEST_REPO}/.worktrees/KEEP" ]
}

@test "worktree: worktree の中から立てても入れ子にならない" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r '.path')

	run --separate-stderr env -C "$_p" "$CCS_BIN" new '.@sibling'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | jq -r '.slug')" = 'x01--sibling' ]
	# 本体の .worktrees に並ぶこと（worktree の中に生えないこと）
	[ "$(echo "$output" | jq -r '.path')" = "$(cd "$CCS_TEST_REPO" && pwd -P)/.worktrees/sibling" ]
	[ ! -d "${_p}/.worktrees/sibling" ]
}

# --- slug に @ を残さない（N1） --------------------------------------------
#
# **組み込みの `SendMessage` にとって `@` は `name@team` のチーム区切り。**
# `ccs@ls-board` は「チーム `ls-board` の `ccs`」と解釈され、宛先として弾かれる
# （`to must be a bare teammate name`）。**送る側からは見えているのに届かない**
# ので、worktree のセッションだけハブから指示を受け取れなかった。
#
# 実測 2026-08-31（`ListAgents` の 37 行）: **ref を持たないのは `@` を含む
# 1 行だけ**で、空白・日本語・`#`・`/`・`[` `]` を含む名前はすべて通っていた。
# 効いているのは文字集合ではなく `@` そのもの。

@test "worktree: 立てたセッションの名前に @ が入らない" {
	run --separate-stderr "$CCS_BIN" new 'x01@topic'
	[ "$status" -eq 0 ]
	[[ "$(printf '%s' "$output" | jq -r '.slug')" != *"@"* ]] || return 1
	[[ "$(printf '%s' "$output" | jq -r '.tmux')" != *"@"* ]] || return 1

	# **起動コマンドにも @ が入らない。** tmux 名だけ直しても、
	# 宛先として使われるのはこちら。
	#
	# **worktree には `-n` を渡さなくなった**（#108）ので、渡す名前そのものが
	# 無い。@ が入る余地が無いことと、名前を押し付けていないことの両方を見る。
	local _cmd
	_cmd=$(ccs_tmux list-panes -t '=cc/x01--topic' -F '#{pane_start_command}')
	[[ "$_cmd" != *"@"* ]] || return 1
	[[ "$_cmd" != *" -n "* ]] || return 1
}

@test "worktree: 打ち方は <repo>@<branch> のまま" {
	# **変えたのは組み立てる slug だけ。** 入力の綴りは SendMessage を
	# 通らないので、変える理由が無い。
	run --separate-stderr "$CCS_BIN" resolve 'x01@topic'
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | cut -f1)" = 'x01--topic' ]
}

@test "worktree: ブランチ名に @ があっても slug には残らない" {
	# **入力構文では表現できない**（`<target>` は最後の `@` で割るので
	# `x01@feat@v2` は repo 部が `x01@feat` になる）。実在するブランチを
	# 実パスで指して確かめる ── そちらは git に訊いて枝の名前を得る経路。
	git -C "$CCS_TEST_REPO" worktree add -q ".worktrees/at" -b 'feat@v2'

	run --separate-stderr "$CCS_BIN" resolve "${CCS_TEST_REPO}/.worktrees/at"
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | cut -f1)" = 'x01--feat-v2' ]
}
