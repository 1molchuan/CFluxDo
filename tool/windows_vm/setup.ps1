# cfluxdo Windows 开发虚拟机首次登录配置（由 autounattend.xml 的 FirstLogonCommands 调用）
$ErrorActionPreference = 'Continue'
Start-Transcript -Path C:\cfx-setup.log -Append
$src = Split-Path -Parent $MyInvocation.MyCommand.Path

# 网络设为专用，电源不休眠，不锁屏
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 0
powercfg /hibernate off
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Personalization" /v NoLockScreen /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" /v InactivityTimeoutSecs /t REG_DWORD /d 0 /f

# 长路径；开发者模式（Flutter 带插件构建要符号链接）
reg add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" /v AllowDevelopmentWithoutDevLicense /t REG_DWORD /d 1 /f

# Defender 排除构建相关目录（实时扫描会让 cargo / flutter 构建慢好几倍）
Add-MpPreference -ExclusionPath 'C:\dev', "$env:USERPROFILE\.cargo", "$env:USERPROFILE\.rustup", "$env:LOCALAPPDATA\Pub", "$env:LOCALAPPDATA\Temp"

# OpenSSH 服务端：先走系统自带的可选功能，失败再用 GitHub 上的 MSI
$cap = Get-WindowsCapability -Online | Where-Object Name -like 'OpenSSH.Server*' | Select-Object -First 1
if ($cap -and $cap.State -ne 'Installed') { Add-WindowsCapability -Online -Name $cap.Name }
if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
  $rel = Invoke-RestMethod 'https://api.github.com/repos/PowerShell/Win32-OpenSSH/releases/latest'
  $msi = ($rel.assets | Where-Object name -like 'OpenSSH-Win64-*.msi' | Select-Object -First 1).browser_download_url
  Invoke-WebRequest $msi -OutFile "$env:TEMP\openssh.msi"
  Start-Process msiexec.exe -ArgumentList "/i `"$env:TEMP\openssh.msi`" /qn" -Wait
}
Set-Service sshd -StartupType Automatic
Start-Service sshd
New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -PropertyType String -Force
Copy-Item "$src\administrators_authorized_keys" 'C:\ProgramData\ssh\administrators_authorized_keys' -Force
icacls 'C:\ProgramData\ssh\administrators_authorized_keys' /inheritance:r /grant '*S-1-5-32-544:F' /grant '*S-1-5-18:F'
if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
}
Restart-Service sshd

New-Item -ItemType Directory -Force C:\dev | Out-Null
Set-Content C:\cfx-setup.done (Get-Date -Format o)
Stop-Transcript
