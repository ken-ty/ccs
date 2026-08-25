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

@test "worktree: 置き場所は CCS_WORKTREE_ROOT/<repo>/<branch>" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve --json 'x01@topic'
	[ "$status" -eq 0 ]
	local _p
	_p=$(echo "$output" | jq -r .path)

	# **根は symlink を辿った形で返る。** /tmp → /private/tmp のような環境で
	# 生の変数と比べると外れる（実装側で一度踏んだ）。
	local _root
	_root=$(cd "$CCS_WORKTREE_ROOT" && pwd -P)
	[ "$_p" = "${_root}/x01/topic" ]
}

@test "worktree: ghq root の外に置く（ghq list に混ざらないため）" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve --json 'x01@topic'
	local _p
	_p=$(echo "$output" | jq -r .path)
	[[ "$_p" != "${CCS_TEST_TMP}/ghq/"* ]] || return 1
}

# --- 副作用が無いこと --------------------------------------------------------

@test "worktree: resolve は実体を作らない" {
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/o/x01"

	run "$CCS_BIN" resolve 'x01@topic'
	[ "$status" -eq 0 ]
	[ ! -e "${CCS_WORKTREE_ROOT}/x01" ]
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

@test "worktree: worktree の worktree は拒む" {
	# **本物の worktree を作る。** 以前は `mkdir` した空ディレクトリで
	# 通っていたが、それは置き場所の前方一致で当てていたから。
	# 素性を git に訊く以上（ADR-0003 決定 3）、worktree でないものは
	# worktree として扱わない。
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	git -C "$_repo" worktree add -q "${CCS_WORKTREE_ROOT}/x01/topic" -b topic

	run "$CCS_BIN" resolve "${CCS_WORKTREE_ROOT}/x01/topic@other"
	[ "$status" -eq 1 ]
	[[ "$output" == *"既に worktree です"* ]] || return 1
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

@test "worktree: CCS_WORKTREE_ROOT の外にある worktree も入れ子として拒む" {
	local _repo="${CCS_TEST_TMP}/ghq/github.com/o/x01"
	ccs_make_git_repo "$_repo"
	ccs_stub_ghq "$_repo"
	# **根の外**に手で切った worktree。前方一致で当てていた頃は素通しだった。
	git -C "$_repo" worktree add -q "${CCS_TEST_TMP}/elsewhere/wt" -b topic

	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/elsewhere/wt@another"
	[ "$status" -ne 0 ]
	[[ "$output" == *"それは既に worktree です"* ]] || return 1
	# 案内は本体の名前で出すこと（打ち直せる形になっていること）
	[[ "$output" == *"ccs new x01@another"* ]] || return 1
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
