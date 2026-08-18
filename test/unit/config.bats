#!/usr/bin/env bats
#
# 設定の読み込み（env > 設定ファイル > 既定値）。
#
# **ここが崩れると、他人の環境で ccs が動かない。** hub の名前や置き場所を
# 変えられることが、`hub` という名前のリポジトリを持っている人にとっての
# 前提条件になる（docs/configuration.md）。

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_stub_deps
	export CCS_CONFIG_FILE="${CCS_TEST_TMP}/config"
}

teardown() {
	ccs_teardown_sandbox
}

# 設定ファイルを書く。
write_config() {
	printf '%s\n' "$@" >"$CCS_CONFIG_FILE"
}

# `ccs config` の表から 1 行を引く。
config_row() {
	printf '%s\n' "$output" | grep "^$1 " || true
}

@test "設定ファイルが無くても既定値で動く" {
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$(config_row CCS_HUB_SLUG)" == *"hub"* ]]
	[[ "$(config_row CCS_HUB_SLUG)" == *"default"* ]]
}

@test "設定ファイルの値が既定値に勝つ" {
	write_config 'CCS_HUB_SLUG=orchestrator'
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$(config_row CCS_HUB_SLUG)" == *"orchestrator"* ]]
	[[ "$(config_row CCS_HUB_SLUG)" == *"config"* ]]
}

@test "env が設定ファイルに勝つ" {
	# **一時的に環境変数で上書きして試す、が成立しないと困る。**
	write_config 'CCS_HUB_SLUG=fromfile'
	CCS_HUB_SLUG=fromenv run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$(config_row CCS_HUB_SLUG)" == *"fromenv"* ]]
	[[ "$(config_row CCS_HUB_SLUG)" == *"env"* ]]
}

@test "空白とコメントを無視する" {
	write_config '# 先頭のコメント' '   ' '  CCS_HUB_SLUG = spaced   # 末尾のコメント'
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$(config_row CCS_HUB_SLUG)" == *"spaced"* ]]
}

@test "値のクォートを外す" {
	write_config 'CCS_PREFIX="ccx/"'
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$(config_row CCS_PREFIX)" == *"ccx/"* ]]
}

@test "値の先頭の ~/ をホームに展開する" {
	write_config 'CCS_HUB_HOME=~/somewhere/hub'
	run "$CCS_BIN" config --json
	[ "$status" -eq 0 ]
	[ "$(printf '%s' "$output" | jq -r '.settings.CCS_HUB_HOME.value')" = "${HOME}/somewhere/hub" ]
}

@test "知らないキーは黙って無視せず警告する" {
	# 綴り間違いが「設定したのに効かない」で終わるのを防ぐ。
	write_config 'CCS_HUB_SLUGG=typo'
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$output" == *"知らない設定キー"* ]]
	[[ "$output" == *"CCS_HUB_SLUGG"* ]]
}

@test "KEY=VALUE でない行は行番号つきで警告する" {
	write_config 'CCS_HUB_SLUG=ok' 'これは設定ではない'
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[[ "$output" == *"${CCS_CONFIG_FILE}:2"* ]]
}

@test "設定ファイルはシェルとして実行されない" {
	# **source する作りにしない。** 設定ファイルに任意のコマンドを書けると、
	# 設定と実行の境界が無くなる。
	write_config "CCS_HUB_HOME=\$(touch ${CCS_TEST_TMP}/pwned)"
	run "$CCS_BIN" config
	[ "$status" -eq 0 ]
	[ ! -e "${CCS_TEST_TMP}/pwned" ]
	# 値は展開されず、そのままの文字列として入る。
	[[ "$(config_row CCS_HUB_HOME)" == *'$(touch'* ]]
}

@test "--json は値と出どころを機械可読で出す" {
	write_config 'CCS_HUB_SLUG=orchestrator'
	run "$CCS_BIN" config --json
	[ "$status" -eq 0 ]
	printf '%s' "$output" | jq -e . >/dev/null
	[ "$(printf '%s' "$output" | jq -r '.settings.CCS_HUB_SLUG.value')" = 'orchestrator' ]
	[ "$(printf '%s' "$output" | jq -r '.settings.CCS_HUB_SLUG.source')" = 'config' ]
	[ "$(printf '%s' "$output" | jq -r '.configFileExists')" = 'true' ]
}

@test "不正な CCS_REMOTE_CONTROL は 2 で落ちる" {
	CCS_REMOTE_CONTROL=maybe run "$CCS_BIN" ls
	[ "$status" -eq 2 ]
	[[ "$output" == *"CCS_REMOTE_CONTROL"* ]]
}

@test "不正な CCS_HUB_AUTOSTART は 2 で落ちる" {
	CCS_HUB_AUTOSTART=sometimes run "$CCS_BIN" ls
	[ "$status" -eq 2 ]
	[[ "$output" == *"CCS_HUB_AUTOSTART"* ]]
}

@test "tmux で使えない文字を含む CCS_HUB_SLUG は 2 で落ちる" {
	# `:` は session:window の区切りなので、後から -t で狙えなくなる。
	CCS_HUB_SLUG='my:hub' run "$CCS_BIN" ls
	[ "$status" -eq 2 ]
	[[ "$output" == *"CCS_HUB_SLUG"* ]]
}

@test "CCS_HUB_SLUG に tmp は使えない" {
	CCS_HUB_SLUG=tmp run "$CCS_BIN" ls
	[ "$status" -eq 2 ]
}

@test "数値の設定に数値以外を入れると 2 で落ちる" {
	CCS_HUB_BACKOFF_MAX=いっぱい run "$CCS_BIN" ls
	[ "$status" -eq 2 ]
	[[ "$output" == *"CCS_HUB_BACKOFF_MAX"* ]]
}

@test "設定が不正でも config は表を出してから落ちる" {
	# **値が不正なときこそ、その値を見たい。**
	CCS_HUB_AUTOSTART=sometimes run "$CCS_BIN" config
	[ "$status" -eq 2 ]
	[[ "$output" == *"CCS_HUB_AUTOSTART"* ]]
	[[ "$output" == *"sometimes"* ]]
}

@test "設定が不正でも help と version は読める" {
	# 直し方を読むためのコマンドが、壊れた設定で死んでは困る。
	CCS_HUB_AUTOSTART=sometimes run "$CCS_BIN" help
	[ "$status" -eq 0 ]
	CCS_HUB_AUTOSTART=sometimes run "$CCS_BIN" version
	[ "$status" -eq 0 ]
}
