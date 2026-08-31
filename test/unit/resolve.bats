#!/usr/bin/env bats
#
# <target> の解決 — パス / ghq のリポジトリ名 / 使い捨て枠。
#
# slug は tmux セッション名・Claude の表示名・ログの見出しで共有される唯一の
# 識別子（docs/design.md §4.2）。ここがブレると名寄せが全部ブレるので、
# 「同じ場所を指す入力は、打ち方が違っても同じ slug になる」を重点的に見る。

bats_require_minimum_version 1.5.0

load '../test_helper'

setup() {
	ccs_setup_sandbox
	ccs_stub_deps
	# 既定では ghq を「何も無い」状態にする。個々のテストで上書きする。
	ccs_stub_ghq ''
}

teardown() {
	ccs_teardown_sandbox
}

# --- パス指定 --------------------------------------------------------------

@test "絶対パス: そのまま解決し、slug は末尾要素" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/work/myrepo"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'myrepo' ]
	[ "$(echo "$output" | cut -f2)" = "$(cd "${CCS_TEST_TMP}/work/myrepo" && pwd -P)" ]
}

@test "相対パス: 絶対パスに正規化する" {
	mkdir -p "${CCS_TEST_TMP}/work/myrepo"
	cd "${CCS_TEST_TMP}/work"
	run "$CCS_BIN" resolve ./myrepo
	[ "$status" -eq 0 ]
	[[ "$output" == *"/work/myrepo" ]] || return 1
	[[ "$output" != *"./"* ]] || return 1
}

@test "パス: 途中の .. を畳む" {
	mkdir -p "${CCS_TEST_TMP}/work/a" "${CCS_TEST_TMP}/work/b"
	cd "${CCS_TEST_TMP}/work/a"
	run "$CCS_BIN" resolve ../b
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'b' ]
	[[ "$output" != *".."* ]] || return 1
}

@test "パス: 実在しなければ 1 で落ちる" {
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "パス: ファイルはディレクトリではないので落ちる" {
	touch "${CCS_TEST_TMP}/afile"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/afile"
	[ "$status" -eq 1 ]
}

@test "パス: 実在する相対パスは ghq より優先する" {
	# `ken-ty/x01` は ghq の指定とも相対パスとも読める。実物がある方を採る。
	mkdir -p "${CCS_TEST_TMP}/here/ken-ty/x01"
	ccs_stub_ghq "/somewhere/else/ken-ty/x01"
	cd "${CCS_TEST_TMP}/here"

	run "$CCS_BIN" resolve ken-ty/x01
	[ "$status" -eq 0 ]
	[[ "$output" == *"${CCS_TEST_TMP}/here/ken-ty/x01"* ]] || return 1
}

# --- slug の正規化 ---------------------------------------------------------

@test "slug: tmux で危険な文字を落とす" {
	# tmux 3.7 は `:` を名前に受け付けるが、`session:window` の区切りなので
	# 後から -t で狙えなくなる。受け付けることと安全であることは別。
	mkdir -p "${CCS_TEST_TMP}/weird/a.b:c d"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/weird/a.b:c d"
	[ "$status" -eq 0 ]
	_slug=$(echo "$output" | cut -f1)
	[[ "$_slug" != *":"* ]] || return 1
	[[ "$_slug" != *"."* ]] || return 1
	[[ "$_slug" != *" "* ]] || return 1
	[ "$_slug" = 'a-b-c-d' ]
}

@test "slug: 英数字と - _ は残す" {
	mkdir -p "${CCS_TEST_TMP}/w/my_repo-2"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/w/my_repo-2"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'my_repo-2' ]
}

@test "slug: @ は落とす（宛先として使えなくなるため）" {
	# **`SendMessage` にとって `@` は `name@team` のチーム区切り。**
	# 残すと「送る側からは見えているのに届かない」名前ができる（N1）。
	mkdir -p "${CCS_TEST_TMP}/w/my_repo-2@main"
	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/w/my_repo-2@main"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'my_repo-2-main' ]
}

# --- ghq のリポジトリ名 ----------------------------------------------------

@test "リポジトリ名: 末尾一致で引ける" {
	_root="${CCS_TEST_TMP}/ghq/github.com/ken-ty/x01"
	mkdir -p "$_root"
	ccs_stub_ghq "$_root"

	run "$CCS_BIN" resolve x01
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'x01' ]
	# symlink を辿った形で比べる。macOS の /tmp は /private/tmp への symlink
	# なので、リテラルのパスと突き合わせると環境依存で落ちる。
	[ "$(echo "$output" | cut -f2)" = "$(cd "$_root" && pwd -P)" ]
}

@test "リポジトリ名: owner/repo でも host/owner/repo でも同じ結果" {
	# 打ち方で別セッションが立つと、冪等性 (S5) が成立しない。
	_root="${CCS_TEST_TMP}/ghq/github.com/ken-ty/x01"
	mkdir -p "$_root"
	ccs_stub_ghq "$_root"
	cd "$CCS_TEST_TMP"

	run "$CCS_BIN" resolve x01
	_a="$output"
	run "$CCS_BIN" resolve ken-ty/x01
	_b="$output"
	run "$CCS_BIN" resolve github.com/ken-ty/x01
	_c="$output"

	[ "$_a" = "$_b" ]
	[ "$_b" = "$_c" ]
}

@test "リポジトリ名: 部分一致では当たらない" {
	# `x0` で `x01` に当たると、意図しないリポジトリでセッションが立つ。
	_root="${CCS_TEST_TMP}/ghq/github.com/ken-ty/x01"
	mkdir -p "$_root"
	ccs_stub_ghq "$_root"

	run "$CCS_BIN" resolve x0
	[ "$status" -eq 1 ]
	[[ "$output" == *"ありません"* ]] || return 1
}

@test "リポジトリ名: 見つからなければ 1 で、次の手を示す" {
	run "$CCS_BIN" resolve nosuchrepo
	[ "$status" -eq 1 ]
	[[ "$output" == *"nosuchrepo"* ]] || return 1
	[[ "$output" == *"ghq get"* ]] || return 1
}

@test "リポジトリ名: 曖昧なら候補を挙げて 1 で落ちる" {
	# 勝手に選ばない。どちらを指したかは利用者にしか分からない。
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/alice/dup" \
		"${CCS_TEST_TMP}/ghq/github.com/bob/dup"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/alice/dup
${CCS_TEST_TMP}/ghq/github.com/bob/dup"

	run "$CCS_BIN" resolve dup
	[ "$status" -eq 1 ]
	[[ "$output" == *"alice/dup"* ]] || return 1
	[[ "$output" == *"bob/dup"* ]] || return 1
}

@test "slug: 名前が衝突しているリポジトリは owner を足す" {
	# design.md §4.2。owner/repo で一意に指定できても、slug は衝突する。
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/alice/dup" \
		"${CCS_TEST_TMP}/ghq/github.com/bob/dup"
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/alice/dup
${CCS_TEST_TMP}/ghq/github.com/bob/dup"

	run "$CCS_BIN" resolve alice/dup
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'alice-dup' ]

	run "$CCS_BIN" resolve bob/dup
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'bob-dup' ]
}

@test "リポジトリ名: ghq が無ければパス指定を案内する" {
	export CCS_GHQ_BIN='ccs-absent-ghq'
	run "$CCS_BIN" resolve somerepo
	[ "$status" -eq 1 ]
	[[ "$output" == *"ghq"* ]] || return 1
	[[ "$output" == *"パス"* ]] || return 1
}

# --- 使い捨て作業枠 --------------------------------------------------------

@test "tmp: 最初の枠を確保して tmp-1 になる" {
	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
	[ "$(echo "$output" | cut -f2)" = "$(cd "${CCS_SCRATCH_ROOT}/1" && pwd -P)" ]
	[ -d "${CCS_SCRATCH_ROOT}/1" ]
}

@test "tmp: 空の枠は使い回す" {
	# 毎回新しいディレクトリを作ると trust ダイアログが毎回出る（design.md §4.4）。
	run "$CCS_BIN" resolve tmp
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
	run "$CCS_BIN" resolve tmp
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
}

@test "tmp: 使用中の枠は飛ばして次を取る" {
	mkdir -p "${CCS_SCRATCH_ROOT}/1"
	touch "${CCS_SCRATCH_ROOT}/1/inprogress.txt"

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-2' ]
}

@test "tmp: 隠しファイルだけでも使用中とみなす" {
	# .git だけ残った枠を空と見なすと、前の作業の痕跡が次に漏れる。
	mkdir -p "${CCS_SCRATCH_ROOT}/1/.git"

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-2' ]
}

@test "tmp: 全部埋まっていれば 1 で、片付け方を示す" {
	export CCS_SCRATCH_SLOTS=2
	for i in 1 2; do
		mkdir -p "${CCS_SCRATCH_ROOT}/${i}"
		touch "${CCS_SCRATCH_ROOT}/${i}/busy"
	done

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 1 ]
	[[ "$output" == *"ccs gc"* ]] || return 1
	[[ "$output" == *"CCS_SCRATCH_SLOTS"* ]] || return 1
}

@test "--tmp: tmp と同じ枠を取る" {
	# 正式な綴りはオプションのほう。リポジトリ名の名前空間に置かないため。
	run "$CCS_BIN" resolve --tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
	[ "$(echo "$output" | cut -f2)" = "$(cd "${CCS_SCRATCH_ROOT}/1" && pwd -P)" ]
}

@test "--tmp: <target> との同時指定は 2 で落ちる" {
	run "$CCS_BIN" resolve --tmp x01
	[ "$status" -eq 2 ]
	[[ "$output" == *"同時に指定できません"* ]] || return 1
}

@test "--tmp: --json と併用できる" {
	run bash -c "'$CCS_BIN' resolve --tmp --json | jq -r '.slug'"
	[ "$status" -eq 0 ]
	[ "$output" = 'tmp-1' ]
}

@test "--tmp: 同名のリポジトリがあっても枠を取る" {
	# オプションはリポジトリ名の名前空間の外にあるので、衝突しない。
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/tmp"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/tmp"

	run "$CCS_BIN" resolve --tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
}

@test "tmp: 同名のリポジトリがあれば選ばずに落ちる" {
	# 予約語 tmp はリポジトリ名と名前空間を共有している。どちらを指したかは
	# 打った人にしか分からないので、IceCubesApp の衝突と同じ扱いにする。
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/tmp"
	mkdir -p "${CCS_TEST_TMP}/ghq/github.com/someone/tmp"

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 1 ]
	[[ "$output" == *"someone/tmp"* ]] || return 1
	[[ "$output" == *"--tmp"* ]] || return 1
	# 枠を作ってしまわない。落ちる前に副作用を残さない。
	[ ! -d "${CCS_SCRATCH_ROOT}/1" ]
}

@test "tmp: 名前の一部が tmp のリポジトリは衝突ではない" {
	# 末尾要素が完全一致したときだけ曖昧。`tmpl` や `x-tmp` は別物。
	ccs_stub_ghq "${CCS_TEST_TMP}/ghq/github.com/someone/tmpl"

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-1' ]
}

@test "tmp: 枠の本数は CCS_SCRATCH_SLOTS で変えられる" {
	export CCS_SCRATCH_SLOTS=3
	for i in 1 2; do
		mkdir -p "${CCS_SCRATCH_ROOT}/${i}"
		touch "${CCS_SCRATCH_ROOT}/${i}/busy"
	done

	run "$CCS_BIN" resolve tmp
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-3' ]
}

# --- 出力の形 --------------------------------------------------------------

@test "--json: 妥当な JSON を出す" {
	mkdir -p "${CCS_TEST_TMP}/w/myrepo"
	run "$CCS_BIN" resolve --json "${CCS_TEST_TMP}/w/myrepo"
	[ "$status" -eq 0 ]

	run bash -c "'$CCS_BIN' resolve --json '${CCS_TEST_TMP}/w/myrepo' | jq -r '.slug'"
	[ "$output" = 'myrepo' ]
}

@test "--json: パスに引用符が混じっても壊れない" {
	mkdir -p "${CCS_TEST_TMP}/w/say\"hi"
	run bash -c "'$CCS_BIN' resolve --json '${CCS_TEST_TMP}/w/say\"hi' | jq -e ."
	[ "$status" -eq 0 ]
}

@test "エラーは stderr、結果は stdout" {
	mkdir -p "${CCS_TEST_TMP}/w/myrepo"
	run --separate-stderr "$CCS_BIN" resolve "${CCS_TEST_TMP}/w/myrepo"
	[ "$status" -eq 0 ]
	[ -z "$stderr" ]

	run --separate-stderr "$CCS_BIN" resolve "${CCS_TEST_TMP}/nope"
	[ "$status" -eq 1 ]
	[ -z "$output" ]
	[ -n "$stderr" ]
}

@test "resolve: target が無ければ 2" {
	run "$CCS_BIN" resolve
	[ "$status" -eq 2 ]
}

@test "resolve: 知らないオプションは 2" {
	run "$CCS_BIN" resolve --nope somewhere
	[ "$status" -eq 2 ]
}

# --- 安全策 ----------------------------------------------------------------

@test "解決だけでは tmux も claude も起動しない" {
	# resolve は副作用を持たない（作業枠の mkdir を除く）。
	# ここが崩れると「見るだけ」のつもりが実際に立ってしまう。
	ccs_stub tmux 'echo "tmux was called" >>"$CCS_TEST_TMP/called.log"; exit 0'
	ccs_stub claude 'echo "claude was called" >>"$CCS_TEST_TMP/called.log"; exit 0'
	mkdir -p "${CCS_TEST_TMP}/w/myrepo"

	run "$CCS_BIN" resolve "${CCS_TEST_TMP}/w/myrepo"
	[ "$status" -eq 0 ]
	[ ! -f "${CCS_TEST_TMP}/called.log" ]
}

@test "作業枠を実パスで指しても slug は tmp-N" {
	# 末尾要素は `1` なので、素直に basename を取ると `cc/1` という
	# 無意味なセッションが立ち、`ccs new tmp` で立てたものと別物になる。
	mkdir -p "${CCS_SCRATCH_ROOT}/3"
	run "$CCS_BIN" resolve "${CCS_SCRATCH_ROOT}/3"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'tmp-3' ]
}

@test "作業枠の中のサブディレクトリは枠扱いしない" {
	# 枠そのものだけが枠。中で作ったディレクトリまで tmp- を名乗ると、
	# 別物が同じ名前を取り合う。
	mkdir -p "${CCS_SCRATCH_ROOT}/1/sub"
	run "$CCS_BIN" resolve "${CCS_SCRATCH_ROOT}/1/sub"
	[ "$status" -eq 0 ]
	[ "$(echo "$output" | cut -f1)" = 'sub' ]
}
