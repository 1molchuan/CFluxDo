# 在虚拟机里拉最新代码并编译 cfluxdo Windows 版（release）
# 用法: build.ps1 [-NoPull]
param([switch]$NoPull)
$ErrorActionPreference = 'Continue'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
            [Environment]::GetEnvironmentVariable('Path', 'User')
$env:AWS_LC_SYS_PREBUILT_NASM = '1'
$env:CI = 'true'
Set-Location C:\dev\cfluxdo
if (-not $NoPull) {
  git fetch -q origin
  git checkout -q -B desktop/windows origin/desktop/windows
  git submodule update --init -q
}
git log --oneline -1
# doh_proxy 的 build.rs 需要一套编译期 CA（cargo run --bin gen_ca 也要先过 build.rs），
# 缺失时用 Git 自带的 openssl 按 build.rs 同样的参数生成；不把 Git 的 usr\bin 加进 PATH
# （里面的 link.exe 会顶掉 MSVC 链接器）
$certs = 'C:\dev\cfluxdo\core\doh_proxy\certs'
if (-not (Test-Path "$certs\ca.der")) {
  $openssl = 'C:\Program Files\Git\usr\bin\openssl.exe'
  New-Item -ItemType Directory -Force $certs | Out-Null
  & $openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -keyout "$certs\ca.key" -out "$certs\ca.crt" -days 3650 -nodes -subj '/CN=DOH Proxy CA/O=DOH Proxy/C=CN' 2>&1 | Out-Null
  & $openssl x509 -in "$certs\ca.crt" -outform DER -out "$certs\ca.der"
  'generated embedded CA'
}
$log = 'C:\dev\build-win.log'
dart tool/flutterw.dart build windows --release *> $log
$code = $LASTEXITCODE
Get-Content $log -Tail 25
"BUILD_EXIT=$code"
