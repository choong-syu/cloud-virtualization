#!/usr/bin/env bash
# Ubuntu/Debian 전용. 일반 실습 계정의 호스트 Bash에서 실행합니다.
# GitHub의 setup.sh를 내려받으면 week03-setup.sh라는 이름으로 저장됩니다.
# 실행: bash week03-setup.sh (sudo bash로 실행하지 않습니다.)
#
# 이 스크립트가 하는 일
# 1. 실행 계정과 필수 도구를 확인하고 Ubuntu/Debian 패키지를 설치합니다.
# 2. 하나의 정적 BusyBox 실행 파일과 명령 링크를 rootfs에 준비합니다.
# 3. 실습용 설정 파일과 빈 디렉터리를 만들고 chroot 실행을 검사합니다.
# 기존 rootfs가 올바르면 재사용하며, 다르면 STOP으로 멈춥니다.
# hostname 변경, namespace 생성, procfs 마운트는 이후 README 실습에서 합니다.

# 01. 오류가 발생하면 멈추고, 설정하지 않은 변수 사용도 오류로 처리합니다.
# 파이프(|) 앞 명령의 실패도 확인하며, ERR 트랩은 함수 등에도 이어집니다.
set -Eeuo pipefail
# 도구의 검사 결과가 일관되도록 시스템 메시지 언어를 C로 지정합니다.
export LC_ALL=C


# 02. 실행할 수 있는 환경인지 검사합니다.
# fail 함수는 이유를 STOP 메시지로 알리고 실패 상태(1)로 종료합니다.
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
# 일반 사용자의 홈에 만들기 위해 root 계정으로 시작한 실행은 거부합니다.
(( EUID != 0 )) || fail 'sudo bash가 아닌 일반 사용자로 bash setup.sh를 실행하세요.'
# 관리자 작업을 위한 sudo와 Ubuntu/Debian 패키지 도구 apt-get이 필요합니다.
command -v sudo >/dev/null || fail 'sudo가 필요합니다. 교수자에게 VM 계정 준비를 요청하세요.'
command -v apt-get >/dev/null || fail '이 준비 스크립트는 Ubuntu/Debian VM용입니다.'
# HOME은 비어 있지 않은 절대 경로여야 하며 시스템 루트(/)이면 안 됩니다.
[[ -n "${HOME:-}" && "$HOME" = /* && "$HOME" != / ]] || fail '사용자 HOME 경로를 확인하세요.'

# 03. rootfs를 만들 위치와 필요한 BusyBox 명령 이름을 정합니다.
# TARGET: 완성된 rootfs, PARENT: 그것을 담는 assets 디렉터리
TARGET="$HOME/cloud-virtualization/assets/busybox-rootfs"
PARENT="$(dirname "$TARGET")"
# applet은 BusyBox 하나가 제공하는 개별 명령 기능을 뜻합니다.
# 나중에 bin/sh, bin/ls 등의 링크를 같은 bin/busybox 파일로 연결합니다.
APPLETS=(sh ash ls cat ps hostname sleep echo printf mkdir touch cp mv rm rmdir
         mount umount readlink grep kill true false head pwd test)

printf '일반 사용자: %s\nrootfs 경로: %s\n' "$(id -un)" "$TARGET"
# 클라우드 이미지의 암호 없는 sudo 정책도 지원합니다.
sudo -n true 2>/dev/null || sudo -v
# 04. 패키지 목록을 갱신한 뒤 실습에 필요한 패키지를 설치합니다.
# busybox-static: 라이브러리 파일을 따로 복사하지 않아도 실행되는 정적 BusyBox
# procps: 호스트의 프로세스 확인 도구
# util-linux: unshare, mount, umount, findmnt 등
# hostname: 호스트 이름 확인, file·libc-bin: 실행 파일 종류와 의존성 확인
# coreutils: chroot, ls, cat, readlink 등 기본 명령, wget: 파일 다운로드
sudo apt-get update
# 설치 과정의 대화형 질문을 줄이며, 이미 설치된 패키지도 확인합니다.
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  busybox-static procps util-linux hostname file libc-bin coreutils wget

# 05. 설치 후 필요한 명령을 실제로 찾을 수 있는지 검사합니다.
# 하나라도 없으면 rootfs를 만들기 전에 중단합니다.
for cmd in sudo env unshare chroot mount umount findmnt readlink hostname ldd file ls cat; do
  command -v "$cmd" >/dev/null || fail "필수 명령이 없습니다: $cmd"
done
# 설치된 BusyBox의 경로를 찾고, file 출력으로 정적 실행 파일인지 확인합니다.
BUSYBOX_BIN="$(command -v busybox)"
file -L "$BUSYBOX_BIN" | grep -Eq 'statically linked|static-pie linked' ||
  fail '설치된 BusyBox가 정적 실행 파일이 아닙니다.'
# BusyBox가 제공하는 기능 목록에 실습에서 쓸 모든 applet이 있는지 검사합니다.
available="$("$BUSYBOX_BIN" --list)"
for applet in "${APPLETS[@]}"; do
  grep -qx "$applet" <<<"$available" || fail "BusyBox 기능 누락: $applet"
done

# 06. rootfs가 실습 시작 조건을 만족하는지 검사하는 함수를 정의합니다.
# 아래 함수는 기존 rootfs를 재사용할 때와 새로 만든 rootfs를 확정할 때 호출됩니다.
# 조건이 맞지 않으면 return 1로 실패를 알리고, 호출한 곳에서 STOP 처리합니다.
validate_rootfs() {
  local root="$1" applet
  # 실제 디렉터리인지 확인합니다. 다른 위치를 가리키는 심볼릭 링크는 허용하지 않습니다.
  [[ -d "$root" && ! -L "$root" ]] || return 1
  for directory in bin etc proc tmp dev home; do
    [[ -d "$root/$directory" && ! -L "$root/$directory" ]] || return 1
  done
  # BusyBox가 링크가 아닌 실행 가능한 정적 파일인지 다시 검사합니다.
  [[ -x "$root/bin/busybox" && ! -L "$root/bin/busybox" ]] || return 1
  file -L "$root/bin/busybox" | grep -Eq 'statically linked|static-pie linked' || return 1
  # 각 명령 링크의 대상은 같은 bin 안에 있는 busybox여야 합니다.
  for applet in "${APPLETS[@]}"; do
    [[ -L "$root/bin/$applet" && "$(readlink "$root/bin/$applet")" = busybox ]] || return 1
  done
  # 실습용 hostname 파일 내용과 최소 사용자·그룹 정보 파일을 확인합니다.
  [[ "$(cat "$root/etc/hostname")" = busybox-rootfs ]] || return 1
  [[ -f "$root/etc/passwd" && -f "$root/etc/group" ]] || return 1
  # 현재 마운트 관점에서 proc가 마운트되어 있지 않고 비어 있어야 합니다.
  # 다른 namespace의 실습 셸은 이 검사로 정리되지 않으므로 재실행 전에 종료합니다.
  if findmnt -M "$root/proc" >/dev/null; then return 1; fi
  [[ -z "$(ls -A "$root/proc")" ]] || return 1
  # rootfs 안의 sh를 잠깐 실행해 /, 설정 파일, 필수 명령을 확인합니다.
  # -c 뒤의 검사만 수행하고 종료합니다. procfs는 마운트하지 않습니다.
  sudo chroot "$root" /bin/sh -c '
    test "$(pwd)" = / &&
    test "$(cat /etc/hostname)" = busybox-rootfs &&
    test -x /bin/ps && test -x /bin/readlink && test -x /bin/umount
  '
}

# 07. 기존 rootfs가 있으면 덮어쓰지 않고 검증하여 재사용합니다.
# 문제가 있으면 STOP으로 종료하므로 기존 파일은 유지됩니다.
if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  validate_rootfs "$TARGET" || fail '기존 rootfs가 실습 시작 조건과 다릅니다. 자동 덮어쓰기하지 않으니 교수자와 확인하세요.'
  printf '기존 rootfs 검증 통과: %s\n' "$TARGET"
else
  # 08. rootfs가 없으면 assets 아래의 새 임시 디렉터리에 먼저 만듭니다.
  # mktemp는 다른 작업과 이름이 겹치지 않는 디렉터리를 만듭니다.
  mkdir -p "$PARENT"
  TMP="$(mktemp -d "$PARENT/.busybox-rootfs.XXXXXX")"
  # 이번 실행이 만든 임시 디렉터리만 정리합니다.
  trap '[[ -z "${TMP:-}" ]] || rm -rf -- "$TMP"' EXIT
  # 7개 기본 디렉터리와 mnt/host-share를 만듭니다.
  # proc, dev, home, tmp, mnt/host-share에는 아직 내용이나 마운트가 없습니다.
  mkdir -p "$TMP"/{bin,etc,proc,tmp,mnt/host-share,dev,home}
  # 정적 BusyBox를 복사하고 실행 권한(0755)을 줍니다.
  install -m 0755 "$BUSYBOX_BIN" "$TMP/bin/busybox"
  # 여러 실행 파일을 복사하는 대신 명령 이름마다 busybox로 향하는 링크를 만듭니다.
  for applet in "${APPLETS[@]}"; do ln -s busybox "$TMP/bin/$applet"; done
  # 09. rootfs 안에서 읽을 최소 설정 파일을 만듭니다.
  # etc/hostname은 실습용 파일 내용일 뿐, 현재 VM의 hostname을 바꾸지 않습니다.
  # passwd·group은 root 계정 표시용 정보이며, 로그인 암호를 저장하지 않습니다.
  # lab-environment·os-release는 이 파일 트리가 실습용임을 알려 줍니다.
  printf '%s\n' busybox-rootfs > "$TMP/etc/hostname"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$TMP/etc/passwd"
  printf '%s\n' 'root:x:0:' > "$TMP/etc/group"
  printf '%s\n' 'cloud-virtualization week03 BusyBox rootfs' > "$TMP/etc/lab-environment"
  printf '%s\n' 'NAME="Cloud Virtualization BusyBox rootfs"' \
    'ID=cloudvirt-busybox' 'PRETTY_NAME="Cloud Virtualization Week03 BusyBox rootfs"' > "$TMP/etc/os-release"
  # tmp는 모든 사용자가 쓸 수 있게 하되 sticky bit(맨 앞의 1)를 적용합니다.
  # 일반 사용자는 다른 사용자가 소유한 파일을 함부로 지우거나 바꿔치기할 수 없습니다.
  chmod 1777 "$TMP/tmp"
  # 10. 새 rootfs가 검증을 통과한 경우에만 최종 위치로 옮깁니다.
  # 검증 전 실패하면 EXIT 트랩이 이번 실행의 임시 디렉터리를 정리합니다.
  validate_rootfs "$TMP" || fail '새 rootfs 검증에 실패했습니다.'
  mv -T -- "$TMP" "$TARGET"
  # 완성된 rootfs를 지우지 않도록 임시 경로와 정리 트랩을 해제합니다.
  TMP=''
  trap - EXIT
fi

# 준비가 끝나면 학생이 사용할 경로와 다음 진행 위치를 안내합니다.
printf '\n준비 완료: %s\n' "$TARGET"
printf '%s\n' 'rootfs/proc는 비어 있고 마운트되지 않았습니다.' \
  'SSH 창 A와 B를 열고 README의 명령 01부터 시작하세요.'
