#!/usr/bin/env bats
#
# scripts/termshot.py — キャプチャ済みの端末出力 → SVG。
#
# ドキュメントに貼る画像を作る道具なので、壊れても本体は動く。ただし
# **壊れたまま気づかないと、公開したドキュメントに壊れた画像が並ぶ**ので、
# 「妥当な SVG が出ること」だけは常に押さえる。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	CCS_TERMSHOT="${CCS_REPO_ROOT}/scripts/termshot.py"
	export CCS_TERMSHOT
}

teardown() {
	ccs_teardown_sandbox
}

_svg_is_valid() {
	python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])" "$1"
}

@test "termshot: 妥当な SVG を出す" {
	printf '$ ccs ls\nSLUG  STATUS\nx01   idle\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/out.svg"
	[ "$status" -eq 0 ]

	_svg_is_valid "${CCS_TEST_TMP}/out.svg"
}

@test "termshot: 標準入力からも読める" {
	run bash -c "printf 'hello\n' | python3 '$CCS_TERMSHOT'"
	[ "$status" -eq 0 ]
	[[ "$output" == *"<svg"* ]]
	[[ "$output" == *"hello"* ]]
}

@test "termshot: 中身の文字がそのまま入る" {
	# 「実際に走らせた結果を貼る」ための道具なので、入力を書き換えない。
	printf 'SESSION ID 4aad423f-3dee-49f4-a43b-2fa7624a3487\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt"
	[[ "$output" == *"4aad423f-3dee-49f4-a43b-2fa7624a3487"* ]]
}

@test "termshot: XML の特殊文字を壊さない" {
	# jq の出力には " や < > が普通に混じる。
	printf '{"slug":"x01","path":"<a & b>"}\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/out.svg"
	[ "$status" -eq 0 ]
	_svg_is_valid "${CCS_TEST_TMP}/out.svg"
	grep -q '&amp;' "${CCS_TEST_TMP}/out.svg"
	grep -q '&lt;' "${CCS_TEST_TMP}/out.svg"
}

@test "termshot: 日本語が入っても妥当" {
	printf '中身が残っている作業枠（ccs は消しません）\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/out.svg"
	[ "$status" -eq 0 ]
	_svg_is_valid "${CCS_TEST_TMP}/out.svg"
	grep -q '作業枠' "${CCS_TEST_TMP}/out.svg"
}

@test "termshot: 日本語の行は幅を広く見積もる" {
	# 素朴に len() で数えると、全角の行が枠から溢れる。
	#
	# 入力は最小幅（24 桁）を超える長さにする。短いと両方とも下限に
	# 張り付いて、幅の計算が効いているのか分からないテストになる。
	printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' >"${CCS_TEST_TMP}/ascii.txt"
	printf 'ああああああああああああああああああああああああああああああ\n' >"${CCS_TEST_TMP}/wide.txt"

	_w_ascii=$(python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/ascii.txt" | sed -n 's/.*width="\([0-9]*\)".*/\1/p' | head -1)
	_w_wide=$(python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/wide.txt" | sed -n 's/.*width="\([0-9]*\)".*/\1/p' | head -1)

	[ "$_w_wide" -gt "$_w_ascii" ]
}

@test "termshot: 長い行は折り返す" {
	# `ccs new` の JSON は 1 行 280 桁ある。折り返さないと横に 2400px の
	# 画像になり、本文幅に縮小されて読めない。
	python3 -c "print('x' * 300)" >"${CCS_TEST_TMP}/long.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/long.txt" -o "${CCS_TEST_TMP}/out.svg"
	[ "$status" -eq 0 ]
	_svg_is_valid "${CCS_TEST_TMP}/out.svg"

	_w=$(sed -n 's/.*width="\([0-9]*\)".*/\1/p' "${CCS_TEST_TMP}/out.svg" | head -1)
	[ "$_w" -lt 1000 ]

	# 3 行に割れる（100 桁 × 3）。中身は落とさない。
	[ "$(grep -c 'class="out"' "${CCS_TEST_TMP}/out.svg")" -eq 3 ]
}

@test "termshot: --cols 0 で折り返さない" {
	python3 -c "print('x' * 300)" >"${CCS_TEST_TMP}/long.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/long.txt" --cols 0
	[ "$status" -eq 0 ]
	[[ "$output" == *"$(python3 -c "print('x' * 300)")"* ]]
}

@test "termshot: 折り返した継続行はコマンドの色のまま" {
	# 端末では 1 行の続き。途中で色が変わると別の行に見える。
	python3 -c "print('\$ ccs new ' + 'a' * 200)" >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt"
	[ "$status" -eq 0 ]
	[[ "$output" != *'class="out"'* ]]
}

@test "termshot: ANSI エスケープを落とす" {
	printf '\033[32mgreen\033[0m text\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/out.svg"
	[ "$status" -eq 0 ]
	_svg_is_valid "${CCS_TEST_TMP}/out.svg"
	grep -q 'green text' "${CCS_TEST_TMP}/out.svg"
	! grep -q '\[32m' "${CCS_TEST_TMP}/out.svg"
}

@test "termshot: 末尾の空行を落とす" {
	# capture-pane はペインの高さぶん空行を返す。そのままだと
	# 下半分が余白の画像になる。
	printf 'one\n\n\n\n\n\n' >"${CCS_TEST_TMP}/in.txt"
	printf 'one\n' >"${CCS_TEST_TMP}/tight.txt"

	_h_padded=$(python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" | sed -n 's/.*height="\([0-9]*\)".*/\1/p' | head -1)
	_h_tight=$(python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/tight.txt" | sed -n 's/.*height="\([0-9]*\)".*/\1/p' | head -1)

	[ "$_h_padded" = "$_h_tight" ]
}

@test "termshot: light と dark の両方の配色を持つ" {
	# 画像を 2 枚用意しないための作り。片方が抜けると、どちらかの
	# テーマで読めない画像になる。
	printf 'hello\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt"
	[[ "$output" == *"prefers-color-scheme: dark"* ]]
	[[ "$output" == *".bg"* ]]
}

@test "termshot: プロンプト行を色分けする" {
	printf '$ ccs ls\noutput line\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt"
	[[ "$output" == *'class="cmd"'* ]]
	[[ "$output" == *'class="out"'* ]]
}

@test "termshot: タイトルを指定できる" {
	printf 'hello\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" --title 'ccs new x01'
	[[ "$output" == *"ccs new x01"* ]]
}

@test "termshot: 空の入力は 1 で落ちる" {
	printf '\n\n' >"${CCS_TEST_TMP}/in.txt"

	run python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt"
	[ "$status" -eq 1 ]
	[[ "$output" == *"入力が空"* ]]
}

@test "termshot: 同じ入力からは同じ SVG が出る" {
	# 決定的でないと、差分がレビューできない。
	printf '$ ccs ls\nx01  idle\n' >"${CCS_TEST_TMP}/in.txt"

	python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/a.svg"
	python3 "$CCS_TERMSHOT" "${CCS_TEST_TMP}/in.txt" -o "${CCS_TEST_TMP}/b.svg"

	cmp "${CCS_TEST_TMP}/a.svg" "${CCS_TEST_TMP}/b.svg"
}
