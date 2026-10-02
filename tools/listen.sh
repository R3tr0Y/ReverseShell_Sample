#!/usr/bin/env bash
# 监听端助手 —— 解决「收到 shell 但无法交互」的一半问题在操作员这边：
#   * 终端 raw 模式：Ctrl-C/Ctrl-Z 作为字节发给对端（不被本地吞掉）
#   * 优先 socat（双向 raw tty）→ rlwrap+nc（带 readline）→ 裸 nc
#
# 用法: listen.sh [PORT] [BIND_IP] [--dry-run]
#   --dry-run  只打印将执行的监听命令，不真正监听
# 环境: RS_LISTENER=socat|rlwrap|nc  强制选择监听方式
#       RS_KEEP=1                    支持多会话（nc -k / socat 循环）
#
# 提示: 会话结束后若终端显示异常，执行 `stty sane` 或 `reset` 恢复。

set -u

PORT="${1:-8080}"
BIND=""
DRY=0
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  sed -n '2,13p' "$0"
  exit 0
fi
shift 2>/dev/null || true
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    *) [ -z "$BIND" ] && BIND="$a" ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

nc_flavor() {
  local path
  path="$(readlink -f "$(command -v nc)")"
  case "$path" in
    *openbsd*) echo openbsd; return ;;
    *traditional*) echo traditional; return ;;
  esac
  if nc -h 2>&1 | grep -qi "openbsd"; then echo openbsd; else echo traditional; fi
}

build_nc_cmd() {
  local flavor
  flavor="$(nc_flavor)"
  local base=()
  if [ "$flavor" = "openbsd" ]; then
    base=(nc -lvnp "$PORT")
    [ "${RS_KEEP:-0}" = "1" ] && base=(nc -lvknp "$PORT")
  else
    base=(nc -lv -p "$PORT")
  fi
  [ -n "$BIND" ] && base+=(-s "$BIND")
  printf '%s' "${base[*]}"
}

want="${RS_LISTENER:-auto}"
IS_TTY=0
[ -t 0 ] && IS_TTY=1

pick() {
  case "$want" in
    socat|rlwrap|nc) echo "$want"; return ;;
  esac
  if [ "$IS_TTY" = 1 ] && have socat; then echo socat; return; fi
  if have rlwrap && have nc; then echo rlwrap; return; fi
  if have nc; then echo nc; return; fi
  echo none
}

CMD_KIND="$(pick)"
case "$CMD_KIND" in
  socat)  RUN=(socat "file:$(tty),raw,echo=0" "tcp-listen:$PORT,reuseaddr") ;;
  rlwrap) RUN=(rlwrap -cAr nc -lvnp "$PORT") ;;
  nc)     RUN=($(build_nc_cmd)) ;;
  none)   echo "找不到可用的监听工具（需要 socat / rlwrap+nc / nc 之一）" >&2; exit 1 ;;
esac

if [ "$DRY" = 1 ]; then
  printf 'mode=%s cmd=' "$CMD_KIND"
  printf '%q ' "${RUN[@]}"
  printf '\n'
  exit 0
fi

# raw 模式：让 Ctrl-C 等控制键以字节流穿过 nc 到达对端
if [ "$IS_TTY" = 1 ]; then
  ORIG="$(stty -g 2>/dev/null || true)"
  restore() {
    [ -n "${ORIG:-}" ] && stty "$ORIG" 2>/dev/null
    printf '\n[listen] 终端模式已恢复\n' >&2
  }
  trap restore EXIT INT TERM
  stty raw -echo
fi

printf '[listen] %s 模式，监听 :%s（Ctrl-C 会发给对端；退出后终端自动恢复）\n' \
  "$CMD_KIND" "$PORT" >&2

if [ "$CMD_KIND" = "socat" ] && [ "${RS_KEEP:-0}" = "1" ]; then
  while :; do "${RUN[@]}"; done
else
  "${RUN[@]}"
fi
