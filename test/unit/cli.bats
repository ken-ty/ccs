#!/usr/bin/env bats
#
# 入口の挙動 — サブコマンド分岐・ヘルプ・依存チェック・終了コード。
#
# 終了コードは呼び出し側（ハブのエージェント）が分岐に使う契約なので、
# 「落ちること」ではなく「どの番号で落ちるか」を検証する。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
}

teardown() {
	ccs_teardown_sandbox
}

# --- ヘルプとバージョン ----------------------------------------------------

@test "help: 使い方を stdout に出して 0 で終わる" {
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs new"* ]] || return 1
	[[ "$output" == *"ccs ls"* ]] || return 1
}

@test "help: --help と -h も同じ" {
	run "$CCS_BIN" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs new"* ]] || return 1

	run "$CCS_BIN" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs new"* ]] || return 1
}

@test "help: 設定の入口（ccs config）を案内している" {
	# 差し替え点の一覧は `ccs config` が持つ（キーが 20 個あり、ヘルプに
	# 全部並べると読めなくなったため）。ヘルプからそこへ辿れることを見る。
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs config"* ]] || return 1
}

@test "config: 差し替え点が全部一覧に載っている" {
	# 差し替え点はテストの生命線なので、一覧から消えたら気づけるようにする。
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	for var in CCS_CLAUDE_BIN CCS_TMUX_BIN CCS_GHQ_BIN CCS_JQ_BIN \
		CCS_SESSIONS_DIR CCS_TRUST_FILE CCS_SCRATCH_ROOT CCS_PROJECTS_DIR \
		CCS_HUB_SLUG CCS_HUB_HOME CCS_HUB_AUTOSTART CCS_REMOTE_CONTROL; do
		[[ "$output" == *"$var"* ]] || {
			echo "ccs config に $var が無い"
			return 1
		}
	done
}

@test "help: 依存が無くても読める" {
	# 「何が足りないか」を知るためにヘルプを読むので、ここで死ぬと詰む。
	ccs_hide_dep tmux
	ccs_hide_dep jq
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
}

@test "version: 1 行で版を出す" {
	# **形の検証は test/unit/version.bats が持つ。** ここは入口の分岐だけ見る。
	# 素の X.Y.Z を返す契約は `version --short` へ移った（そちらも version.bats）。
	run "$CCS_BIN" version
	[ "$status" -eq 0 ]
	[ -n "$output" ]
	[ "$(printf '%s' "$output" | grep -c .)" = '1' ]
}

# --- 使い方の誤り ----------------------------------------------------------

@test "引数なし: usage を stderr に出して 2 で終わる" {
	run "$CCS_BIN"
	[ "$status" -eq 2 ]
}

@test "引数なし: usage は stdout を汚さない" {
	# stdout は機械可読な結果のためだけに使う（ccs new の JSON など）。
	run --separate-stderr "$CCS_BIN"
	[ "$status" -eq 2 ]
	[ -z "$output" ]
	[[ "$stderr" == *"ccs new"* ]] || return 1
}

@test "未知のサブコマンド: 2 で終わり、何が未知だったかを言う" {
	run "$CCS_BIN" nosuchcommand
	[ "$status" -eq 2 ]
	[[ "$output" == *"nosuchcommand"* ]] || return 1
}

@test "new: target が無ければ 2" {
	ccs_stub_deps
	run "$CCS_BIN" new
	[ "$status" -eq 2 ]
}

@test "attach: slug が無ければ 2" {
	ccs_stub_deps
	run "$CCS_BIN" attach
	[ "$status" -eq 2 ]
}

@test "kill: slug が無ければ 2" {
	ccs_stub_deps
	run "$CCS_BIN" kill
	[ "$status" -eq 2 ]
	# **自分を畳む道があることを、断るときに言う。** ここで詰まる人は
	# 「slug が分からない」ことが多い。
	[[ "$stderr$output" == *"--self"* ]] || return 1
}

@test "kill --self: ccs のセッションの外では 2" {
	# 中から呼んだのかどうかは $TMUX とソケットの一致で決める。素の
	# シェルから打っても、畳む相手が決まらない。
	ccs_stub_deps
	run "$CCS_BIN" kill --self
	[ "$status" -eq 2 ]
	[[ "$stderr$output" == *"--self"* ]] || return 1
}

@test "kill --self: slug と併記できない" {
	# **自分だと思って他人を畳む余地を残さない。** それが --self の理由。
	ccs_stub_deps
	run "$CCS_BIN" kill --self myrepo
	[ "$status" -eq 2 ]
}

@test "help: kill --self を案内している" {
	ccs_stub_deps
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs kill --self"* ]] || return 1
}

# --- 依存チェック ----------------------------------------------------------

@test "依存不足: tmux が無ければ 4 で、導入方法を出す" {
	ccs_hide_dep tmux
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-tmux"* ]] || return 1
	[[ "$output" == *"brew install"* ]] || return 1
}

@test "依存不足: jq が無ければ 4" {
	ccs_hide_dep jq
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-jq"* ]] || return 1
}

@test "依存不足: 両方無ければ両方を挙げる" {
	# 1 つずつ直させると往復が増える。足りないものは一度に全部言う。
	ccs_hide_dep tmux
	ccs_hide_dep jq
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-tmux"* ]] || return 1
	[[ "$output" == *"ccs-absent-jq"* ]] || return 1
}

@test "依存不足: メッセージは stderr に出る" {
	ccs_hide_dep tmux
	run --separate-stderr "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[ -z "$output" ]
	[[ "$stderr" == *"ccs-absent-tmux"* ]] || return 1
}

# --- サブコマンドが揃っていること ------------------------------------------

@test "v1 のサブコマンドはどれも「未実装(3)」を返さない" {
	# 終了コード 3 は v2 以降のために空けてあるが、v1 の範囲では
	# 誰も返さない。ここが 3 を返し始めたら、実装が抜けている。
	ccs_stub_deps

	for sub in ls gc; do
		run "$CCS_BIN" "$sub"
		[ "$status" -ne 3 ] || {
			echo "${sub} が未実装(3)を返した"
			return 1
		}
	done
}

# --- 安全策 ----------------------------------------------------------------

@test "サンドボックス: HOME と差し替え点が使い捨て領域を指している" {
	# このテストが落ちたら、他の全テストが実環境を壊しうる状態になっている。
	# 個別のテストが差し替えを組み立てないよう、ヘルパの責務をここで固定する。
	[ -n "$CCS_TEST_TMP" ]
	for path in "$HOME" "$CCS_SESSIONS_DIR" "$CCS_TRUST_FILE" \
		"$CCS_SCRATCH_ROOT" "$CCS_PROJECTS_DIR"; do
		[[ "$path" == "$CCS_TEST_TMP"/* ]] || {
			echo "実環境を指している: $path"
			return 1
		}
	done
}
