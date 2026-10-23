#!/usr/bin/env python3
"""Run a local diagnostic EXE in an already logged-in Windows console via QGA.

Requires kubectl exec permission on the VM's launcher. Copies only the specified
binary, verifies SHA256, and starts a temporary limited-user scheduled task.
Does not log in, store credentials, change display modes, or replace the agent.
Arguments following -- are passed literally to the executable.
"""

import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import uuid


def ps_literal(value):
    return "'" + value.replace("'", "''") + "'"


class Guest:
    def __init__(self, args):
        self.kubectl = ["kubectl"]
        if args.kubeconfig:
            self.kubectl += ["--kubeconfig", args.kubeconfig]
        if args.context:
            self.kubectl += ["--context", args.context]
        pods = json.loads(subprocess.check_output(self.kubectl + [
            "get", "pods", "-n", args.namespace, "-l",
            "vm.kubevirt.io/name=" + args.vm, "-o", "json"], timeout=20))["items"]
        running = [p for p in pods if p["status"]["phase"] == "Running"
                   and not p["metadata"].get("deletionTimestamp")]
        if len(running) != 1:
            raise RuntimeError("expected exactly one running launcher")
        self.command = self.kubectl + [
            "exec", "-n", args.namespace, running[0]["metadata"]["name"],
            "-c", "compute", "--", "virsh", "-c", "qemu:///session",
            "qemu-agent-command", args.namespace + "_" + args.vm]

    def agent(self, command, **arguments):
        request = {"execute": command, "arguments": arguments}
        response = json.loads(subprocess.check_output(
            self.command + [json.dumps(request)], timeout=20))
        if "error" in response:
            raise RuntimeError(str(response["error"]))
        return response["return"]

    def powershell(self, script, timeout):
        encoded = base64.b64encode(script.encode("utf-16le")).decode()
        pid = self.agent("guest-exec", path=r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
                         arg=["-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
                         **{"capture-output": True})["pid"]
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            result = self.agent("guest-exec-status", pid=pid)
            if result.get("exited"):
                return result
            time.sleep(1)
        raise RuntimeError("QGA diagnostic still running; do not blindly retry")

    def copy(self, source, destination):
        handle = self.agent("guest-file-open", path=destination, mode="wb")
        try:
            with source.open("rb") as stream:
                while chunk := stream.read(24576):
                    result = self.agent("guest-file-write", handle=handle,
                                        **{"buf-b64": base64.b64encode(chunk).decode(), "count": len(chunk)})
                    if result["count"] != len(chunk):
                        raise RuntimeError("short guest-file-write")
        finally:
            self.agent("guest-file-close", handle=handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--vm", required=True)
    parser.add_argument("--kubeconfig")
    parser.add_argument("--context")
    parser.add_argument("--timeout", type=int, default=45, help="task runtime limit, 5..120 seconds")
    parser.add_argument("executable", type=Path)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if not 5 <= args.timeout <= 120:
        parser.error("--timeout must be 5..120")
    if not args.executable.is_file() or not 0 < args.executable.stat().st_size <= 32 * 1024 * 1024:
        parser.error("executable must be a nonempty file of at most 32 MiB")
    arguments = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
    guest = Guest(args)
    name = "KwConsoleProbe-" + uuid.uuid4().hex
    destination = "C:\\Windows\\Temp\\" + name + ".exe"
    digest = hashlib.sha256(args.executable.read_bytes()).hexdigest()
    # Windows Temp is writable to QGA/SYSTEM and executable by the console user.
    # Each invocation owns a unique path; nothing from the installed agent is touched.
    try:
        guest.copy(args.executable, destination)
        invocation = "& " + ps_literal(destination) + " " + " ".join(map(ps_literal, arguments))
        script = r'''
$ErrorActionPreference='Stop';$ProgressPreference='SilentlyContinue'
$binary=BINARY
$name=NAME
if((Get-FileHash -Algorithm SHA256 -LiteralPath $binary).Hash -ne HASH){throw 'SHA256 mismatch'}
$user=(Get-CimInstance Win32_ComputerSystem).UserName
if(-not $user){throw 'No logged-in console user; log in through recovery console first'}
$account=$user.Substring($user.LastIndexOf('\')+1)
$sid=(Get-LocalUser -Name $account).SID.Value
& icacls.exe $binary /grant ($user+':(RX)') | Out-Null
if($LASTEXITCODE -ne 0){throw 'Cannot grant console user read/execute access to diagnostic'}
$profile=(Get-ItemProperty ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\'+$sid)).ProfileImagePath
$output=Join-Path $profile ('AppData\Local\Temp\'+$name+'.out')
$errors=$output+'.err'
$receipt=$output+'.exit'
$cmd='$ErrorActionPreference="Stop"; $code=1; try { '+INVOCATION+' > '+"'"+$output.Replace("'","''")+"'"+' 2> '+"'"+$errors.Replace("'","''")+"'"+'; $code=$LASTEXITCODE } catch { $_ | Out-File '+"'"+$errors.Replace("'","''")+"'"+' }; [IO.File]::WriteAllText('+"'"+$receipt.Replace("'","''")+"'"+', [string]$code); exit $code'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
$action=New-ScheduledTaskAction -Execute 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument ('-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand '+$encoded)
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds LIMIT)
Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Settings $settings | Out-Null
try {
 Start-ScheduledTask -TaskName $name
 $deadline=(Get-Date).AddSeconds(LIMIT)
 while(-not (Test-Path -LiteralPath $receipt)) {
  if((Get-Date) -ge $deadline){Stop-ScheduledTask -TaskName $name;throw 'Task deadline exceeded'}
  Start-Sleep -Milliseconds 500
 }
 $code=[int](Get-Content -LiteralPath $receipt -Raw)
 Get-Content -LiteralPath $output -Raw -ErrorAction SilentlyContinue
 Get-Content -LiteralPath $errors -Raw -ErrorAction SilentlyContinue
 exit $code
} finally {
 Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
 Unregister-ScheduledTask -TaskName $name -Confirm:$false
 Remove-Item -LiteralPath $output,$errors,$receipt -ErrorAction SilentlyContinue
}
'''
        for key, value in [("BINARY", ps_literal(destination)), ("NAME", ps_literal(name)),
                           ("HASH", ps_literal(digest)), ("INVOCATION", ps_literal(invocation)),
                           ("LIMIT", str(args.timeout))]:
            script = script.replace(key, value)
        result = guest.powershell(script, args.timeout + 30)
        for key, stream in [("out-data", sys.stdout), ("err-data", sys.stderr)]:
            if result.get(key):
                print(base64.b64decode(result[key]).decode("utf-8-sig", errors="replace"), file=stream)
        if result.get("out-truncated") or result.get("err-truncated"):
            raise RuntimeError("diagnostic output truncated by QGA")
        return result.get("exitcode", 1)
    finally:
        guest.powershell("$ProgressPreference='SilentlyContinue'; Remove-Item -LiteralPath "
                         + ps_literal(destination) + " -ErrorAction SilentlyContinue", 30)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print("console probe:", error, file=sys.stderr)
        sys.exit(1)
