# cfluxdo Windows 构建工具链：Git、VS 2022 生成工具（C++）、Rust（MSVC）、Flutter 3.44.8
# 在虚拟机里以管理员身份执行；可重复执行（已装的跳过）
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Start-Transcript -Path C:\dev\install-tools.log -Append
New-Item -ItemType Directory -Force C:\dev\dl | Out-Null
function Log($m) { Write-Host "[$(Get-Date -Format HH:mm:ss)] $m" }
function Refresh-Path {
  $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
              [Environment]::GetEnvironmentVariable('Path', 'User')
}

# 1. Git for Windows
if (-not (Test-Path 'C:\Program Files\Git\cmd\git.exe')) {
  Log 'Git: 下载'
  $rel = Invoke-RestMethod 'https://api.github.com/repos/git-for-windows/git/releases/latest'
  $url = ($rel.assets | Where-Object name -match '^Git-[\d.]+-64-bit\.exe$' | Select-Object -First 1).browser_download_url
  Invoke-WebRequest $url -OutFile C:\dev\dl\git.exe
  Log 'Git: 安装'
  Start-Process C:\dev\dl\git.exe -ArgumentList '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES' -Wait
}
Refresh-Path
git config --global core.autocrlf false
git config --global core.longpaths true

# 2. Visual Studio 2022 生成工具 + C++ 桌面开发（含 MSVC、Windows SDK、CMake 工具）
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVc = (Test-Path $vswhere) -and (& $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath)
if (-not $hasVc) {
  Log 'VS 生成工具: 下载'
  Invoke-WebRequest 'https://aka.ms/vs/17/release/vs_BuildTools.exe' -OutFile C:\dev\dl\vs_BuildTools.exe
  Log 'VS 生成工具: 安装（约 20-40 分钟）'
  $p = Start-Process C:\dev\dl\vs_BuildTools.exe -PassThru -Wait -ArgumentList @(
    '--quiet', '--wait', '--norestart', '--nocache',
    '--add', 'Microsoft.VisualStudio.Workload.VCTools',
    '--add', 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
    '--add', 'Microsoft.VisualStudio.Component.Windows11SDK.26100',
    '--add', 'Microsoft.VisualStudio.Component.VC.CMake.Project',
    '--add', 'Microsoft.VisualStudio.Component.VC.ATL',
    '--includeRecommended')
  Log "VS 生成工具: 退出码 $($p.ExitCode)（0 或 3010 为成功）"
}

# 3. Rust（MSVC 工具链）；aws-lc-sys 用随包预编译的 NASM 目标，免装 NASM
if (-not (Test-Path "$env:USERPROFILE\.cargo\bin\cargo.exe")) {
  Log 'Rust: 安装'
  Invoke-WebRequest 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-msvc/rustup-init.exe' -OutFile C:\dev\dl\rustup-init.exe
  & C:\dev\dl\rustup-init.exe -y --default-toolchain stable --profile minimal | Out-Host
}
[Environment]::SetEnvironmentVariable('AWS_LC_SYS_PREBUILT_NASM', '1', 'User')

# 3.5 nuget.exe（flutter_inappwebview_windows 用它拉 WebView2 SDK / WIL / CppWinRT）
New-Item -ItemType Directory -Force C:\dev\tools | Out-Null
if (-not (Test-Path 'C:\dev\tools\nuget.exe')) {
  Log 'nuget: 下载'
  Invoke-WebRequest 'https://dist.nuget.org/win-x86-commandline/latest/nuget.exe' -OutFile C:\dev\tools\nuget.exe
}

# 4. Flutter 3.44.8（与 VPS 同一提交 058e0af）
if (-not (Test-Path 'C:\dev\flutter\bin\flutter.bat')) {
  Log 'Flutter: 克隆 3.44.8'
  git clone --depth 1 --branch 3.44.8 https://github.com/flutter/flutter.git C:\dev\flutter
}
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($p in @('C:\dev\flutter\bin', "$env:USERPROFILE\.cargo\bin", 'C:\dev\tools')) {
  if ($userPath -notlike "*$p*") { $userPath = "$userPath;$p" }
}
[Environment]::SetEnvironmentVariable('Path', $userPath.Trim(';'), 'User')
Refresh-Path
$env:CI = 'true'
Log 'Flutter: precache + doctor'
flutter config --no-analytics | Out-Host
flutter precache --windows | Out-Host
flutter doctor -v | Out-Host
Set-Content C:\dev\install-tools.done (Get-Date -Format o)
Stop-Transcript
