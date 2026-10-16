#!/usr/bin/env bash
# cfluxdo Windows 开发虚拟机（QEMU/KVM，q35 + OVMF 安全启动 + swtpm）
# 用法: vm.sh start [install] | stop | ssh <命令...> | shot <名字> | key <qemu 按键...> | tunnel | status
# VNC 127.0.0.1:5902（经 ssh -R 映射到 Mac 同端口），SSH 127.0.0.1:2222 → 来宾 22
D=/srv/winvm
MON=$D/monitor.sock
mon() { printf '%s\n' "$*" | socat - UNIX-CONNECT:$MON >/dev/null; }
case $1 in
  start)
    pgrep -f "^swtpm socket.*$D/tpm" >/dev/null || \
      swtpm socket --tpm2 --tpmstate dir=$D/tpm --ctrl type=unixio,path=$D/tpm/swtpm-sock \
        --log file=$D/tpm/swtpm.log --daemon
    CD=()
    if [ "$2" = install ]; then
      CD=(-drive id=cd0,file=$D/win11-ent-eval-zh-cn.iso,media=cdrom,if=none,readonly=on -device ide-cd,drive=cd0,bus=ahci.1,bootindex=0
          -drive id=cd1,file=$D/unattend.iso,media=cdrom,if=none,readonly=on -device ide-cd,drive=cd1,bus=ahci.2)
    fi
    qemu-system-x86_64 -name cfx-win -machine q35,accel=kvm,smm=on \
      -global driver=cfi.pflash01,property=secure,value=on \
      -cpu host,hv_relaxed,hv_spinlocks=0x1fff,hv_vapic,hv_time,hv_vpindex,hv_synic,hv_stimer \
      -smp 4,sockets=1,cores=4,threads=1 -m 8G -rtc base=localtime \
      -drive if=pflash,format=raw,unit=0,file=/usr/share/OVMF/OVMF_CODE_4M.ms.fd,readonly=on \
      -drive if=pflash,format=raw,unit=1,file=$D/OVMF_VARS.fd \
      -chardev socket,id=chrtpm,path=$D/tpm/swtpm-sock -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
      -device ahci,id=ahci \
      -drive id=disk0,file=$D/win.qcow2,if=none,format=qcow2,cache=writeback,discard=unmap \
      -device ide-hd,drive=disk0,bus=ahci.0,bootindex=1 \
      "${CD[@]}" \
      -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device e1000e,netdev=n0 \
      -vga std -device qemu-xhci -device usb-tablet \
      -vnc 127.0.0.1:2,password=on -monitor unix:$MON,server,nowait \
      -pidfile $D/qemu.pid -daemonize
    sleep 1
    [ -f $D/.vnc_password ] && mon "change vnc password $(cat $D/.vnc_password)"
    ;;
  stop)   mon system_powerdown ;;
  kill)   kill "$(cat $D/qemu.pid)" ;;
  key)    shift; for k in "$@"; do mon "sendkey $k"; sleep 0.2; done ;;
  shot)   mon "screendump $D/$2.ppm" && sleep 1 && convert $D/$2.ppm $D/$2.png && rm -f $D/$2.ppm && echo $D/$2.png ;;
  ssh)    shift; ssh -i $D/id_winvm -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=$D/known_hosts \
            -o ConnectTimeout=10 dev@127.0.0.1 "$@" ;;
  tunnel)
    pgrep -f '^ssh .*-R 127.0.0.1:5902:' >/dev/null ||
      ssh -f -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o AddressFamily=any \
        -R 127.0.0.1:5902:127.0.0.1:5902 mac ;;
  status) pgrep -af '^qemu-system-x86_64 -name cfx-win' | cut -c1-60 ;;
esac
