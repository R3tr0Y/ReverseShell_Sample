# C 语言反弹交互式 Shell 样本
#
#   make linux    本机 Linux 可执行文件  -> ../dist/reverse-linux-c
#   make windows  x86_64 PE32+ 交叉产物  -> ../dist/reverse-windows-c.exe
#   make clean    清理产物

CC    ?= gcc
WINCC ?= x86_64-w64-mingw32-gcc
CFLAGS ?= -O2 -Wall -std=c99
DIST   := ../dist

LINUX_BIN := $(DIST)/reverse-linux-c
WIN_BIN   := $(DIST)/reverse-windows-c.exe

.PHONY: linux windows clean

linux: $(LINUX_BIN)

$(LINUX_BIN): reverse.c
	@mkdir -p $(DIST)
	$(CC) $(CFLAGS) -o $@ $< -lutil

windows: $(WIN_BIN)

$(WIN_BIN): reverse.c
	@mkdir -p $(DIST)
	$(WINCC) $(CFLAGS) -o $@ $< -lws2_32

clean:
	rm -f $(LINUX_BIN) $(WIN_BIN)
