#!/usr/bin/env bash
# 一键构建所有语言产物到 dist/（缺少工具链的语言自动跳过）。
#   bash build.sh            # 构建本机能构建的全部（含 Windows 交叉编译）
#   bash build.sh linux      # 只构建 Linux 目标
#   bash build.sh windows    # 只构建 Windows 交叉编译目标
set -u
cd "$(dirname "$0")"
TARGET="${1:-all}"
mkdir -p dist
have() { command -v "$1" >/dev/null 2>&1; }

build_linux() {
  echo "== Linux 目标 =="
  if have nim; then
    nim c -d:release --hints:off --verbosity:0 -o:dist/reverse-linux-nim nim/reverse.nim \
      && echo "  dist/reverse-linux-nim"
  else echo "  [跳过 nim] 未安装"; fi
  if have gcc; then
    make -C c linux >/dev/null && echo "  dist/reverse-linux-c"
  else echo "  [跳过 c] 未安装 gcc"; fi
  if have go; then
    (cd go && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o ../dist/reverse-linux-go .) \
      && echo "  dist/reverse-linux-go"
  else echo "  [跳过 go] 未安装"; fi
  echo "  [脚本] bash/shell.sh、python/reverse.py、powershell/reverse.ps1 无需构建"
}

build_windows() {
  echo "== Windows 目标（交叉编译） =="
  if have nim && have x86_64-w64-mingw32-gcc; then
    nim c -d:release --threads:on --os:windows --cpu:amd64 -d:mingw \
      --gcc.exe:x86_64-w64-mingw32-gcc --gcc.linkerexe:x86_64-w64-mingw32-gcc \
      --hints:off --verbosity:0 -o:dist/reverse-windows-nim.exe nim/reverse.nim \
      && echo "  dist/reverse-windows-nim.exe"
  else echo "  [跳过 nim] 需要 nim + mingw-w64"; fi
  if have x86_64-w64-mingw32-gcc; then
    make -C c windows >/dev/null && echo "  dist/reverse-windows-c.exe"
  else echo "  [跳过 c] 需要 mingw-w64"; fi
  if have go; then
    (cd go && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 go build -o ../dist/reverse-windows-go.exe .) \
      && echo "  dist/reverse-windows-go.exe"
  else echo "  [跳过 go] 未安装"; fi
}

case "$TARGET" in
  linux)   build_linux ;;
  windows) build_windows ;;
  all)     build_linux; echo; build_windows ;;
  *) echo "用法: bash build.sh [linux|windows|all]"; exit 1 ;;
esac
echo
echo "完成。产物在 dist/ 下。"
