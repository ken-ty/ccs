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
	[[ "$output" == *"ccs new"* ]]
	[[ "$output" == *"ccs ls"* ]]
}

@test "help: --help と -h も同じ" {
	run "$CCS_BIN" --help
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs new"* ]]

	run "$CCS_BIN" -h
	[ "$status" -eq 0 ]
	[[ "$output" == *"ccs new"* ]]
}

@test "help: 差し替え点が一覧に載っている" {
	# 差し替え点はテストの生命線なので、ヘルプから消えたら気づけるようにする。
	run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	for var in CCS_CLAUDE_BIN CCS_TMUX_BIN CCS_GHQ_BIN CCS_JQ_BIN \
		CCS_SESSIONS_DIR CCS_TRUST_FILE CCS_SCRATCH_ROOT CCS_PROJECTS_DIR; do
		[[ "$output" == *"$var"* ]] || {
			echo "ヘルプに $var が無い"
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

@test "version: バージョンだけを出す" {
	run "$CCS_BIN" version
	[ "$status" -eq 0 ]
	[[ "$output" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
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
	[[ "$stderr" == *"ccs new"* ]]
}

@test "未知のサブコマンド: 2 で終わり、何が未知だったかを言う" {
	run "$CCS_BIN" nosuchcommand
	[ "$status" -eq 2 ]
	[[ "$output" == *"nosuchcommand"* ]]
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
}

# --- 依存チェック ----------------------------------------------------------

@test "依存不足: tmux が無ければ 4 で、導入方法を出す" {
	ccs_hide_dep tmux
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-tmux"* ]]
	[[ "$output" == *"brew install"* ]]
}

@test "依存不足: jq が無ければ 4" {
	ccs_hide_dep jq
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-jq"* ]]
}

@test "依存不足: 両方無ければ両方を挙げる" {
	# 1 つずつ直させると往復が増える。足りないものは一度に全部言う。
	ccs_hide_dep tmux
	ccs_hide_dep jq
	run "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[[ "$output" == *"ccs-absent-tmux"* ]]
	[[ "$output" == *"ccs-absent-jq"* ]]
}

@test "依存不足: メッセージは stderr に出る" {
	ccs_hide_dep tmux
	run --separate-stderr "$CCS_BIN" ls
	[ "$status" -eq 4 ]
	[ -z "$output" ]
	[[ "$stderr" == *"ccs-absent-tmux"* ]]
}

# --- 未実装のサブコマンド --------------------------------------------------

@test "未実装のサブコマンドは 3 で終わり、ROADMAP の項目を示す" {
	# 「未知（2）」と「未実装（3）」を区別する。前者は打ち間違い、後者は待てば直る。
	ccs_stub_deps

	run "$CCS_BIN" gc
	[ "$status" -eq 3 ]
	[[ "$output" == *"S9"* ]]
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
