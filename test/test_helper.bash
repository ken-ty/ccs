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

	# **素性を書き置く。** 見張り（下）ごと SIGKILL されると、サンドボックスも
	# tmux サーバも残る。次に走らせたときに `test/reap-tmux` がこれを読んで
	# 「持ち主はもう居ない ＝ 取り残し」と判定する。**生きているテストのものに
	# 触らない**ための唯一の手掛かりなので、真っ先に書く。
	printf '%s\n' "${BASHPID:-$$}" >"${CCS_TEST_TMP}/owner.pid"

	export HOME="${CCS_TEST_TMP}/home"
	mkdir -p "$HOME"

	export CCS_SESSIONS_DIR="${CCS_TEST_TMP}/sessions"
	export CCS_TRUST_FILE="${CCS_TEST_TMP}/claude.json"
	export CCS_SCRATCH_ROOT="${CCS_TEST_TMP}/scratch"
	export CCS_PROJECTS_DIR="${CCS_TEST_TMP}/projects"
	# **worktree の差し替え点は要らない**（ADR-0003 決定 6）。置き場所が
	# リポジトリ配下 (`<repo>/.worktrees/`) になったので、テストが作る
	# リポジトリはサンドボックスの中にあり、worktree もそこに落ちる。
	mkdir -p "$CCS_SESSIONS_DIR" "$CCS_SCRATCH_ROOT" "$CCS_PROJECTS_DIR"

	# **本物の tmux の場所を、PATH を汚す前に控える。**
	# この下で PATH の先頭にスタブを差し込むので、あとから `tmux` を引くと
	# テストが置いたスタブに当たりうる。後始末（`kill-server`）がスタブに
	# 当たると「畳んだつもりで畳めていない」になり、サーバが残る。
	CCS_REAL_TMUX="$(command -v tmux 2>/dev/null || echo tmux)"
	export CCS_REAL_TMUX

	# スタブを置く場所。PATH の先頭に差し込む。
	export CCS_STUB_BIN="${CCS_TEST_TMP}/stub-bin"
	mkdir -p "$CCS_STUB_BIN"
	export PATH="${CCS_STUB_BIN}:${PATH}"

	ccs_watch_sandbox
}

# --- 見張り ----------------------------------------------------------------
#
# **bats の teardown は、呼ばれないことがある。** 実測（bats 1.14.0 / macOS）:
#
#   | 止め方 | teardown | tmux サーバ |
#   | --- | --- | --- |
#   | 正常終了 | 走る | 畳まれる |
#   | SIGTERM / SIGHUP | 走る | 畳まれる |
#   | **SIGINT（Ctrl-C）** | **走らない** | **残る** |
#   | **SIGKILL** | 走れない | **残る** |
#
# tmux サーバは端末から切り離された常駐プロセスなので、bats を殺しても、端末を
# 閉じても死なない。しかも別ソケットなので `ccs ls` にも `ccs gc` にも出てこない
# ── 誰も気づけない。2026-08-26 に、丸 1 日生き残った `cc/hub` 入りのサーバが
# 実際に見つかった（`make check` は 6 分かかるので、Ctrl-C の機会は十分ある）。
#
# **teardown に頼らない後始末を、外のプロセスに持たせる。** 見張りは
# プロセスの生死しか見ないので、teardown が呼ばれようが呼ばれまいが同じように効く。
#
# ccs_watch_sandbox [持ち主の pid] [サンドボックス]
#   既定はこのテスト自身と `$CCS_TEST_TMP`。引数を取るのはテストのため
#   （自分自身は殺せないので、見張りの動作を確かめられない）。
ccs_watch_sandbox() {
	local _owner=${1:-${BASHPID:-$$}}
	local _dir=${2:-$CCS_TEST_TMP}
	local _tmux=${CCS_REAL_TMUX:-tmux}

	[ -n "$_dir" ] || return 0

	# - `trap '' INT HUP TERM` … Ctrl-C は**プロセスグループ全体**に届く。
	#   見張り自身が巻き添えで死んだら意味が無い。
	# - `</dev/null >/dev/null 2>&1 3>&-` … **bats は fd 3 で結果を集める**。
	#   バックグラウンドのプロセスが握ったままだと、bats が終われずに固まる。
	# - **サーバを先に畳む。** ディレクトリを消してもプロセスは死なない
	#   （それがまさに 1 日生き残った理由）。
	(
		trap '' INT HUP TERM
		while kill -0 "$_owner" 2>/dev/null; do sleep 1; done
		if [ -S "${_dir}/tmux.sock" ]; then
			"$_tmux" -S "${_dir}/tmux.sock" kill-server 2>/dev/null || true
		fi
		rm -rf "$_dir"
	) </dev/null >/dev/null 2>&1 3>&- &

	disown 2>/dev/null || true
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

# テスト用の git リポジトリを作る。worktree のテストで使う。
#
# **本物の git を使う。** worktree の生成はまさに git の挙動そのものなので、
# スタブに置き換えると「スタブが正しいこと」しか確かめられない。
# git は claude と違って課金されないし、ネットワークにも出ない。
ccs_make_git_repo() {
	local _path=$1
	mkdir -p "$_path"
	git -C "$_path" init -q -b main
	git -C "$_path" config user.email 'test@example.com'
	git -C "$_path" config user.name 'ccs test'
	# **hook を継承させない。** 利用者の core.hooksPath が効くと、
	# テストの commit が本物の pre-commit を走らせる。
	git -C "$_path" config core.hooksPath /dev/null
	printf 'seed\n' >"${_path}/README.md"
	git -C "$_path" add -A
	git -C "$_path" commit -q -m 'seed'
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

	local _root=${2:-${CCS_TEST_TMP}/ghq}
	ccs_stub ghq "
case \"\$1\" in
root) echo '$_root' ;;
list)
  case \"\$2\" in
  -p) grep -v '^\$' '$_file' || true ;;
  *) grep -v '^\$' '$_file' | sed 's#^.*/ghq/##' || true ;;
  esac
  ;;
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
# 論外なので、テストごとに専用のサーバを立てる。
#
# **置き場所を tmux に決めさせない（`-L` ではなく `-S`）。** `-L <名前>` は
# 共有の `/tmp/tmux-<uid>/` にソケットを作る ── **テストが作るもののうち、
# ここだけがサンドボックスの外に出る**。しかも `kill-server` はソケット
# ファイルを消さない（tmux 3.7b で実測）ので、1 テスト 1 個で積み上がる。
# 実際に 3,950 個溜まっていた（2026-08-27 実測）。
#
# `-S <パス>` にしてサンドボックスの中に置けば、`ccs_teardown_sandbox` の
# `rm -rf` が既に消してくれる。**後始末に特別扱いが要らなくなる**のが要点で、
# ついでに共有ディレクトリを一切汚さなくなる ── 利用者の tmux とも、同時に
# 走っている他セッションのテストとも干渉しない。

ccs_use_own_tmux_server() {
	# **サンドボックスの直下に置く。** Unix ドメインソケットのパスには
	# 104 バイト程度の上限があり、macOS の $TMPDIR (/var/folders/…/T) は
	# それだけで 48 バイト使う。深く掘ると足が出る（実測 75 バイト）。
	CCS_TMUX_SOCKET="${CCS_TEST_TMP}/tmux.sock"
	export CCS_TMUX_SOCKET

	# ccs から見える tmux を「-S 付きの本物」に差し替える。
	# 名前を tmux にしないのは、この中から本物の tmux を引くため。
	{
		echo '#!/bin/sh'
		echo "exec tmux -S '${CCS_TMUX_SOCKET}' \"\$@\""
	} >"${CCS_STUB_BIN}/tmux-own"
	chmod +x "${CCS_STUB_BIN}/tmux-own"

	export CCS_TMUX_BIN="${CCS_STUB_BIN}/tmux-own"
}

# テストから同じサーバを覗く。
ccs_tmux() {
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_TMUX_SOCKET" "$@"
}

# **ソケットファイルは消さない。** サンドボックスの中にあるので
# `ccs_teardown_sandbox` の `rm -rf` が持っていく。ここで消すのは
# 「サーバというプロセス」だけ。
ccs_kill_own_tmux_server() {
	[ -n "${CCS_TMUX_SOCKET:-}" ] || return 0
	# **本物の tmux を名指しで呼ぶ。** PATH の先頭はスタブ置き場なので、
	# `tmux` という名前のスタブ（`ccs_stub_deps` が置く）があると、
	# 畳んだつもりで畳めていない。
	"${CCS_REAL_TMUX:-tmux}" -S "$CCS_TMUX_SOCKET" kill-server 2>/dev/null || true
	return 0
}

# claude を fake に差し替える。
ccs_use_fake_claude() {
	export CCS_CLAUDE_BIN="$CCS_FAKE_CLAUDE"
}

# **注意: tmux サーバの環境はサーバ起動時に固定される。**
# 最初の `ccs new` でサーバが立ち上がるので、それ以降に export した
# FAKE_CLAUDE_* は、あとから立てるセッションには届かない。
# セッションごとに挙動を変えたいときは、この関数でプロセスを落とす。
#
# ccs_kill_claude_of <slug> — その slug の claude だけを終了させる
# （tmux セッションは残る = 「ペインは生きているが claude は死んだ」状態）。
ccs_kill_claude_of() {
	local _slug=$1
	local _f _pid
	for _f in "$CCS_SESSIONS_DIR"/*.json; do
		[ -e "$_f" ] || continue
		if grep -q "\"tmux\":\"cc/${_slug}:" "$_f" 2>/dev/null; then
			_pid=$(jq -r '.pid' "$_f")
			# **残骸を掴まない。** 同じ slug のファイルが 2 件あることがある
			# （前のセッションの残骸 + いま立っているもの）。glob の順は pid の
			# 文字列順なので、どちらが先に来るかはマシンに依る。死んだ方を
			# 掴むと kill が何もせず、ファイルも消えないまま時間切れになる。
			# ccs 側の registry_is_live と同じ判定をする。
			kill -0 "$_pid" 2>/dev/null || continue
			kill "$_pid" 2>/dev/null || true
			ccs_wait_until 5 bash -c "[ ! -f '$_f' ]"
			return 0
		fi
	done
	return 1
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

# tmux の外にいる claude を再現する。
#
# **TMUX を明示的に外す。** ccs はまさに tmux の中から使う道具なので、
# テストを tmux の中から走らせている人がいる。環境任せにすると
# 「tmux の外なら tmux フィールドは無い」が、走らせる場所で結果が変わる。
ccs_start_fake_claude_outside_tmux() {
	env -u TMUX -u TMUX_PANE "$CCS_FAKE_CLAUDE" "$@" &
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
