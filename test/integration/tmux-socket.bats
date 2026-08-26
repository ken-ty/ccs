#!/usr/bin/env bats
#
# テストが立てる tmux サーバのソケットは、サンドボックスの中に閉じている。
#
# **これは「作法」ではなく、ゴミが残らないことの根拠そのもの。** サンドボックスの
# 中にある限り `ccs_teardown_sandbox` の `rm -rf` が必ず持っていくので、後始末に
# 特別扱いが要らない。外に出た瞬間、消し忘れが積み上がる ── 実際に共有の
# `/tmp/tmux-<uid>/` へ 3,950 個溜まった（2026-08-27）。
#
# ここが緑なら、`-L`（tmux が置き場所を決める）に戻す変更は通らない。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_use_fake_claude
	ccs_use_own_tmux_server
	ccs_stub_ghq ''
	export CCS_NEW_TIMEOUT=15

	# **tmux が「共有の置き場所」だと思う場所を、空の使い捨てに向ける。**
	# 実際の /tmp/tmux-<uid>/ を数えると、同時に走っている他のセッションや
	# 利用者自身の tmux で数が動いて falky になる。ここを空のまま保てるか、
	# という形にすれば、何が同時に走っていても結果が変わらない。
	export TMUX_TMPDIR="${CCS_TEST_TMP}/shared-tmux"
	mkdir -p "$TMUX_TMPDIR"

	mkdir -p "${CCS_TEST_TMP}/work"
}

teardown() {
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
}

@test "ソケットはサンドボックスの中にある" {
	run "$CCS_BIN" new "${CCS_TEST_TMP}/work"
	[ "$status" -eq 0 ]

	# tmux 自身に訊く。ヘルパの変数を見るだけだと、変数と実際の起動引数が
	# ずれていても気づけない。
	_actual=$(ccs_tmux display-message -p '#{socket_path}')
	[ "$_actual" = "$CCS_TMUX_SOCKET" ]

	case $_actual in
	"$CCS_TEST_TMP"/*) ;;
	*) return 1 ;;
	esac
	[ -S "$_actual" ]
}

@test "共有の tmux ディレクトリを汚さない" {
	run "$CCS_BIN" new "${CCS_TEST_TMP}/work"
	[ "$status" -eq 0 ]
	ccs_tmux has-session -t '=cc/work'

	# `-L` に戻すと、ここに tmux-<uid>/<名前> が生まれる。
	[ -z "$(ls -A "$TMUX_TMPDIR")" ]
}

@test "サンドボックスを消せばソケットも消える" {
	run "$CCS_BIN" new "${CCS_TEST_TMP}/work"
	[ "$status" -eq 0 ]
	[ -S "$CCS_TMUX_SOCKET" ]

	# 後始末の特別扱いが要らないことの確認。teardown と同じ順で撃つ。
	ccs_kill_own_tmux_server
	ccs_teardown_sandbox
	[ ! -e "$CCS_TMUX_SOCKET" ]
	[ ! -d "$CCS_TEST_TMP" ]
}
