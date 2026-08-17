# bats の共通ヘルパ。
#
# すべてのテストは、本物の claude / ~/.claude.json / ~/.cc-scratch に触らない。
# その保証をここに集約する。個々のテストで HOME や差し替え点を組み立てないこと
# ——1 箇所でも漏れると、テストがユーザーの実環境を壊す。

# リポジトリのルート。BATS_TEST_FILENAME は test/<層>/<名前>.bats を指す。
CCS_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
export CCS_REPO_ROOT
export CCS_BIN="${CCS_REPO_ROOT}/bin/ccs"

# 各テストを使い捨てのサンドボックスに閉じ込める。
#
# HOME ごと差し替えるのは、差し替え点の設定を 1 つ書き忘れても
# 本物の ~/.claude に落ちないようにするため（多重の安全策）。
ccs_setup_sandbox() {
	CCS_TEST_TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/ccs-test.XXXXXX")"
	export CCS_TEST_TMP

	export HOME="${CCS_TEST_TMP}/home"
	mkdir -p "$HOME"

	export CCS_SESSIONS_DIR="${CCS_TEST_TMP}/sessions"
	export CCS_TRUST_FILE="${CCS_TEST_TMP}/claude.json"
	export CCS_SCRATCH_ROOT="${CCS_TEST_TMP}/scratch"
	mkdir -p "$CCS_SESSIONS_DIR" "$CCS_SCRATCH_ROOT"

	# スタブを置く場所。PATH の先頭に差し込む。
	export CCS_STUB_BIN="${CCS_TEST_TMP}/stub-bin"
	mkdir -p "$CCS_STUB_BIN"
	export PATH="${CCS_STUB_BIN}:${PATH}"
}

ccs_teardown_sandbox() {
	[ -n "${CCS_TEST_TMP:-}" ] && [ -d "$CCS_TEST_TMP" ] && rm -rf "$CCS_TEST_TMP"
	return 0
}

# PATH 上に実行可能なスタブを置く。
#   ccs_stub jq 'echo stubbed'
ccs_stub() {
	_name=$1
	_body=$2
	printf '#!/bin/sh\n%s\n' "$_body" >"${CCS_STUB_BIN}/${_name}"
	chmod +x "${CCS_STUB_BIN}/${_name}"
}

# 依存（tmux / jq）が揃っているように見せる。
# 依存チェック自体を検証するテスト以外は、これを呼んでから ccs を叩く。
ccs_stub_deps() {
	ccs_stub tmux 'exit 0'
	ccs_stub jq 'exit 0'
}

# 依存が「無い」状態を作る。
#
# PATH から消すのではなく、差し替え点を存在しない名前に向ける。PATH を削ると
# ccs 自身が使う cat や mktemp まで巻き添えになり、何を検証しているのか
# 分からないテストになる。
ccs_hide_dep() {
	case $1 in
	tmux) export CCS_TMUX_BIN='ccs-absent-tmux' ;;
	jq) export CCS_JQ_BIN='ccs-absent-jq' ;;
	*) return 1 ;;
	esac
}
