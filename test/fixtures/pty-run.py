#!/usr/bin/env python3
"""コマンドを pty の下で走らせ、1 行流し込んで、出力と終了コードを返す。

対話が要る入口（`ccs attach` の番号選択）を検証するために使う。**bats は
パイプ越しに走るので `[ -t 0 ]` が偽になり、対話の枝に入らない。** ここだけ
本物の端末を用意する。

    pty-run <入力行> -- <コマンド> [引数...]

入力行には改行が付く。空文字なら改行だけを送る（＝中止の検証）。
"""

import os
import pty
import select
import sys
import time

TIMEOUT = 20.0


def main() -> int:
    if "--" not in sys.argv[1:]:
        print("usage: pty-run <input> -- <cmd> [args...]", file=sys.stderr)
        return 2
    sep = sys.argv.index("--")
    feed = sys.argv[1] if sep > 1 else ""
    argv = sys.argv[sep + 1 :]
    if not argv:
        print("pty-run: コマンドがありません", file=sys.stderr)
        return 2

    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)

    os.write(fd, (feed + "\n").encode())

    chunks = []
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if not ready:
            if os.waitpid(pid, os.WNOHANG)[0]:
                break
            continue
        try:
            data = os.read(fd, 4096)
        except OSError:  # 子が pty を閉じた
            break
        if not data:
            break
        chunks.append(data)

    os.close(fd)
    _, status = os.waitpid(pid, 0)
    sys.stdout.write(b"".join(chunks).decode("utf-8", "replace"))
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
