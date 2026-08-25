#!/usr/bin/env bats
#
# <repo>@<branch> の解決。
#
# **1 リポジトリに 2 本目のセッションを立てる唯一の手段**（docs/design.md §9.1）。
# slug がリポジトリ名である限り `ccs new x01` は冪等に 1 本目を返すので、
# 作業ツリーごと分けるしかない。ここでは「どこに解決されるか」だけを見る
# （実体を作るのは ccs new なので、integration 側）。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_stub_deps
	ccs_stub_ghq ''
}

teardown() {
	ccs_teardown_sandbox
}

# --- slug --------------------------------------------------------------------

@test "worktree: slug は <repo>@<branch>" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@topic'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@topic' ]
}

@test "worktree: ブランチの / は - に潰す" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@feat/login'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@feat-login' ]
	# パス側も潰れていること。潰さないと feat と feat/login が同居できない。
	[[ "$(echo "$output" | cut -f2)" == */feat-login ]] || return 1
}

@test "worktree: 打ち方が違っても同じ slug に落ちる" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@topic'
	local _a=$output
	run "$CCS_BIN" resolve 'o/x01@topic'
	[ "$output" = "$_a" ]
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/ghq/github.com/o/x01@topic"
	[ "$output" = "$_a" ]
}

# --- 置き場所 ----------------------------------------------------------------

@test "worktree: 置き場所は <repo>/.worktrees/<branch>" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	mkdir -p "$_repo"
	ccs_stub_ghq "$_repo"

	run "$CCS_BIN" resolve --json 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r .path)

	# **本体は symlink を辿った形で返る。** /tmp → /private/tmp のような環境で
	# 生の変数と比べると外れる（実装側で一度踏んだ）。
	local _abs
	_abs=$(cd "$_repo" && pwd -P)
	[ "$_p" = "${_abs}/.worktrees/topic" ]
}

@test "worktree: ghq 配下でも ghq list には混ざらない" {
	# ghq は `.git` を見つけた時点でそれ以上降りないので、リポジトリ配下の
	# worktree は列挙されない（ADR-0003 の実測）。**これが方針転換の前提**
	# なので、ここで固定する。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${_repo}/.worktrees/topic" -b topic

	run env GHQ_ROOT="${CCS_TEST_TMP}/ghq" ghq list -p
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | grep -c '\.worktrees')" -eq 0 ]
}

# --- 副作用が無いこと --------------------------------------------------------

@test "worktree: resolve は実体を作らない" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@topic'
	[ "$status" -eq 0 ]
	[ ! -e "${CCS_TEST_TMP}/ghq/github.com/o/x01/.worktrees" ]
}

# --- 曖昧さ ------------------------------------------------------------------

@test "worktree: @ を含む実在ディレクトリはパスとして扱う" {
	mkdir -p "${CCS_TEST_TMP}/work/foo@2"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/work/foo@2"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'foo@2' ]
	[ "$(echo "$output" | cut -f2)" = "$(cd "${CCS_TEST_TMP}/work/foo@2" && pwd -P)" ]
}

@test "worktree: ブランチ名が空なら 2" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@'
	[ "$status" -eq 2 ]
	[[ "$output" == *"ブランチがありません"* ]] || return 1
}

@test "worktree: リポジトリ名が空なら 2" {
	run "$CCS_BIN" resolve '@topic'
	[ "$status" -eq 2 ]
	[[ "$output" == *"対象がありません"* ]] || return 1
}

@test "worktree: 存在しないリポジトリなら 1" {
	run "$CCS_BIN" resolve 'nope@topic'
	[ "$status" -eq 1 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "worktree: worktree を指されたら本体に読み替える" {
	# **拒否ではなく読み替え**（ADR-0003 決定 4）。入れ子を「拒む」のではなく
	# 「起こり得なくする」。slug も本体から決まるので自動で正しくなる。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${_repo}/.worktrees/topic" -b topic

	run --separate-stderr "$CCS_BIN" resolve "${_repo}/.worktrees/topic@other"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@other' ]
	# **入れ子にならない。** 本体の .worktrees に落ちること。
	[ "$(echo "$output" | cut -f2)" = "$(cd "$_repo" && pwd -P)/.worktrees/other" ]
	# 黙って読み替えない
	[[ "$stderr" == *"本体のリポジトリに読み替えました"* ]] || return 1
}

# --- 素性を git から引く（ADR-0003 決定 3、W1） -------------------------------
#
# 置き場所ではなく git に訊く。**パスもまた名前**なので、同一性の根拠にしない。
# ここは `ccs resolve` だけを見る（実体の生成は integration 側）。

@test "worktree: 実パスで指しても <repo>@<branch> と名乗る" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${CCS_TEST_TMP}/elsewhere/wt" -b topic

	# **これが割れていた。** 末尾要素で `wt` を返していたので、
	# `ccs new x01@topic` と別の tmux セッションが立ち、
	# 1 つの作業ツリーを 2 本の claude が触っていた。
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/elsewhere/wt"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@topic' ]
}

@test "worktree: 本体は素の slug のまま（@ を付けない）" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${CCS_TEST_TMP}/elsewhere/wt" -b topic

	run "$CCS_BIN" resolve 'x01'
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01' ]
}

@test "worktree: ブランチの / は実パス指定でも - に潰す" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${CCS_TEST_TMP}/elsewhere/wt" -b feat/login

	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/elsewhere/wt"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@feat-login' ]
}

@test "worktree: 分離 HEAD は素性として扱わない（末尾要素に戻る）" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q --detach "${CCS_TEST_TMP}/elsewhere/wt"

	# 枝を名乗れないものを `x01@HEAD` にすると、別のコミットを見ている
	# 2 つの作業ツリーが同じ slug に落ちる。素性が半分なら使わない。
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/elsewhere/wt"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'wt' ]
}

@test "worktree: 規約の外に手で切った worktree でも本体に読み替える" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	# 置き場所の規約の外。前方一致で当てていた頃は素通しだった。
	git -C "$_repo" worktree add -q "${CCS_TEST_TMP}/elsewhere/wt" -b topic

	# **--separate-stderr が要る。** 読み替えは stderr に 1 行出るので、
	# 混ぜると $output の 1 行目が案内文になる。
	run --separate-stderr "$CCS_BIN" resolve "${CCS_TEST_TMP}/elsewhere/wt@another"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01@another' ]
	[ "$(echo "$output" | cut -f2)" = "$(cd "$_repo" && pwd -P)/.worktrees/another" ]
}

@test "worktree: submodule は worktree ではない" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	local _sub="${CCS_TEST_TMP}/ghq/github.com/o/lib"
	ccs_make_git_repo "$_repo"
	ccs_make_git_repo "$_sub"
	ccs_stub_ghq "$_repo"

	# submodule の .git も**ファイル**なので、安い門番だけでは外れない。
	git -C "$_repo" -c protocol.file.allow=always submodule add -q "$_sub" vendor
	git -C "$_repo" commit -q -m 'add submodule'

	run "$CCS_BIN" resolve "${_repo}/vendor"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'vendor' ]
}
