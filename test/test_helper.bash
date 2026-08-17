# bats の共通ヘルパ。
#
# すべてのテストは、本物の claude / ~/.claude.json / ~/.cc-scratch に触らない。
# その保証をここに集約する。個々のテストで HOME や差し替え点を組み立てないこと
# ——1 箇所でも漏れると、テストがユーザーの実環境を壊す。

# リポジトリのルート。BATS_TEST_FILENAME は test/<層>/<名前>.bats を指す。
CCS_REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
export CCS_REPO_ROOT
export CCS_BIN="${CCS_REPO_ROOT}/bin/ccs"
export CCS_FAKE_CLAUDE="${CCS_REPO_ROOT}/test/fixtures/fake-claude"

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
	export CCS_PROJECTS_DIR="${CCS_TEST_TMP}/projects"
	mkdir -p "$CCS_SESSIONS_DIR" "$CCS_SCRATCH_ROOT" "$CCS_PROJECTS_DIR"

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

# unit テストが本物の tmux を起動しないようにする。
#
# **jq は差し替えない。** テスト自身が JSON の検証に jq を使うので、
# ダミーに置き換えると「jq が常に成功する」だけの空虚なテストになる
# （実際に一度そうなった）。jq はこのプロジェクトの必須依存なので、
# 無い環境ではテストが落ちてよい。
ccs_stub_deps() {
	# has-session は「無い」を返す。常に 0 を返すダミーにすると
	# 「セッションが全部立っている」ことになり、作業枠の確保が回らない。
	ccs_stub tmux '
case "$1" in
has-session) exit 1 ;;
*) exit 0 ;;
esac
'
	export CCS_TMUX_BIN="${CCS_STUB_BIN}/tmux"
}

# ghq を「決まったリポジトリ一覧を返すもの」に差し替える。
# 引数は絶対パスの改行区切り。`ghq list` と `ghq list -p` の両方に答える。
#
# 本物の ghq を使わないのは、テストが実行環境の clone 状況に依存すると、
# マシンによって落ちたり通ったりするため。
ccs_stub_ghq() {
	local _paths=$1
	local _file="${CCS_TEST_TMP}/ghq-paths.txt"
	printf '%s' "$_paths" >"$_file"

	ccs_stub ghq "
case \"\$1 \$2\" in
'list -p') grep -v '^\$' '$_file' || true ;;
'list ') grep -v '^\$' '$_file' | sed 's#^.*/ghq/##' || true ;;
*) grep -v '^\$' '$_file' | sed 's#^.*/ghq/##' || true ;;
esac
exit 0
"
	export CCS_GHQ_BIN="${CCS_STUB_BIN}/ghq"
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

# --- 本物の tmux を、自分専用のサーバで使う --------------------------------
#
# **既定のソケットを使わない。** teardown の `kill-server` が、利用者が実際に
# 開いている tmux セッションを巻き添えにする。テストがユーザーの作業を消すのは
# 論外なので、テストごとに専用ソケット（`tmux -L <名前>`）を立てる。

ccs_use_own_tmux_server() {
	CCS_TMUX_SOCKET="ccs-test-${BASHPID:-$$}-${RANDOM}"
	export CCS_TMUX_SOCKET

	# ccs から見える tmux を「-L 付きの本物」に差し替える。
	# 名前を tmux にしないのは、この中から本物の tmux を引くため。
	{
		echo '#!/bin/sh'
		echo "exec tmux -L '${CCS_TMUX_SOCKET}' \"\$@\""
	} >"${CCS_STUB_BIN}/tmux-own"
	chmod +x "${CCS_STUB_BIN}/tmux-own"

	export CCS_TMUX_BIN="${CCS_STUB_BIN}/tmux-own"
}

# テストから同じサーバを覗く。
ccs_tmux() {
	tmux -L "$CCS_TMUX_SOCKET" "$@"
}

ccs_kill_own_tmux_server() {
	[ -n "${CCS_TMUX_SOCKET:-}" ] || return 0
	tmux -L "$CCS_TMUX_SOCKET" kill-server 2>/dev/null || true
	return 0
}

# claude を fake に差し替える。
ccs_use_fake_claude() {
	export CCS_CLAUDE_BIN="$CCS_FAKE_CLAUDE"
}

# --- 非同期を待つ ----------------------------------------------------------
#
# fake-claude は起動してからレジストリを書くまでに間がある（本物もそう）。
# 固定の sleep で待つと、遅いマシンで falky になり、速いマシンで無駄に遅くなる。
# 条件が満たされるまでポーリングする。

# ccs_wait_until <秒> <コマンド...>
# コマンドが 0 を返すまで 0.05 秒刻みで待つ。時間切れなら 1 を返す。
ccs_wait_until() {
	local _timeout=$1
	shift
	local _deadline=$((SECONDS + _timeout))
	while [ "$SECONDS" -lt "$_deadline" ]; do
		if "$@"; then return 0; fi
		sleep 0.05
	done
	return 1
}

# fake-claude をバックグラウンドで起動し、PID を CCS_FAKE_PID に入れる。
# teardown で確実に止めるため、起動はこの関数に集約する。
ccs_start_fake_claude() {
	"$CCS_FAKE_CLAUDE" "$@" &
	CCS_FAKE_PID=$!
	export CCS_FAKE_PID
}

# ccs_start_fake_claude で起動したものを止める。teardown から呼ぶ。
ccs_stop_fake_claude() {
	[ -n "${CCS_FAKE_PID:-}" ] || return 0
	kill "$CCS_FAKE_PID" 2>/dev/null || true
	wait "$CCS_FAKE_PID" 2>/dev/null || true
	CCS_FAKE_PID=''
	return 0
}

# レジストリに <n> 件並ぶまで待つ。
ccs_registry_count() {
	find "$CCS_SESSIONS_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' '
}

# 述語として渡す。ccs_wait_until は毎回これを呼び直すので、
# `test "$(...)" = n` のように呼び出し時点で 1 度だけ評価してはいけない。
ccs_registry_count_is() {
	[ "$(ccs_registry_count)" = "$1" ]
}

ccs_wait_registry_count() {
	ccs_wait_until "${2:-5}" ccs_registry_count_is "$1"
}
