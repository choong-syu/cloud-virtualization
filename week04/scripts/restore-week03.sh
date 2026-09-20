#!/usr/bin/env bash
# 4주차를 시작하기 위한 이전 학습 환경 복원용입니다.
# prepare: 기존 rootfs를 확인하고 없을 때만 3주차 재료를 준비합니다.
# enter: 학생이 직접 만든 scope 안에서 지난 namespace/procfs/chroot를 복원합니다.
# CPU/메모리 정책 설정, cgroup 읽기, 부하 실행, 결과 판정은 하지 않습니다.
set -Eeuo pipefail
export LC_ALL=C
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[이전 환경 준비] %s\n' "$*"; }
usage() {
  printf '%s\n' \
    '일반 사용자 호스트: bash restore-week03.sh prepare' \
    '교수자 격리 검증: bash restore-week03.sh prepare /홈/검증폴더/cloud-virtualization/assets/busybox-rootfs' \
    '직접 만든 scope 안: bash /절대경로/restore-week03.sh enter /절대경로/busybox-rootfs' \
    'enter는 내부 BusyBox 셸을 열며, 정상 정리는 교안에서 직접 수행합니다.'
}
MODE=${1:---help}
case "$MODE" in
  --help|-h) usage; exit 0 ;;
  prepare|enter|--inside) ;;
  *) usage >&2; exit 2 ;;
esac
[[ $(uname -s) == Linux ]] || fail 'Ubuntu/Debian 실습 VM에서 실행하세요.'
SELF=$(readlink -f -- "$0")
HERE=$(dirname -- "$SELF")
APPLETS=(sh ash ls cat ps hostname sleep echo printf mkdir touch cp mv rm rmdir
         mount umount readlink grep kill true false head pwd test)

# 지정 경로는 교수자의 격리 검증용입니다. 존재하지 않는 하위 경로도 허용하되,
# 홈 밖의 경로, . 또는 .., 링크를 거친 별칭은 어떤 쓰기 작업보다 먼저 거부합니다.
validate_prepare_path() {
  local root=$1 relative current part
  local -a parts
  [[ "$root" == "$HOME/"* && "$root" == /*/cloud-virtualization/assets/busybox-rootfs ]] ||
    fail '홈 아래의 전체 경로이며 끝이 cloud-virtualization/assets/busybox-rootfs여야 합니다.'
  [[ "$root" != *'/./'* && "$root" != *'/../'* && "$root" != *'//'* ]] ||
    fail '. 또는 .., 중복 / 없이 경로를 적으세요.'
  [[ "$root" != *$'\n'* && "$root" != *$'\r'* ]] || fail '줄바꿈이 들어간 경로는 사용할 수 없습니다.'
  [[ -d "$HOME" && $(readlink -f -- "$HOME") == "$HOME" ]] ||
    fail '홈 경로에 링크나 경로 별칭이 있습니다.'
  relative=${root#"$HOME"/}
  current=$HOME
  IFS=/ read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    current+="/$part"
    [[ ! -L "$current" ]] || fail "재료 경로에 심볼릭 링크가 있습니다: $current"
    [[ ! -e "$current" || -d "$current" ]] || fail "폴더가 아닌 경로가 있습니다: $current"
  done
}

# 다른 곳을 가리키는 링크에 재료를 쓰거나 / 자체를 rootfs로 받지 않습니다.
validate_tree() {
  local root=$1 item
  [[ "$root" == /*/cloud-virtualization/assets/busybox-rootfs ]] ||
    fail '3주차의 cloud-virtualization/assets/busybox-rootfs 경로를 사용하세요.'
  [[ -d "$root" && ! -L "$root" ]] || fail "rootfs가 없거나 링크입니다: $root"
  [[ $(readlink -f -- "$root") == "$root" ]] || fail 'rootfs 경로에 다른 곳을 가리키는 링크가 있습니다.'
  for item in bin etc proc tmp dev home; do
    [[ -d "$root/$item" && ! -L "$root/$item" ]] || fail "기존 폴더를 확인하세요: $item"
  done
  [[ -x "$root/bin/busybox" && ! -L "$root/bin/busybox" ]] || fail 'BusyBox 실행 파일이 없습니다.'
  for item in "${APPLETS[@]}"; do
    [[ -L "$root/bin/$item" && $(readlink -- "$root/bin/$item") == busybox ]] ||
      fail "기존 BusyBox 명령 연결을 확인하세요: $item"
  done
  [[ $(cat "$root/etc/hostname") == busybox-rootfs ]] || fail '기존 /etc/hostname 내용이 예상과 다릅니다.'
  [[ -f "$root/etc/passwd" && -f "$root/etc/group" ]] || fail '기존 사용자 표시 파일이 없습니다.'
}
check_empty_proc() {
  local root=$1
  if findmnt -M "$root/proc" >/dev/null; then
    fail '현재 관점에서 rootfs/proc가 마운트되어 있습니다. 이전 실습부터 정리하세요.'
  fi
  [[ -z $(ls -A -- "$root/proc") ]] || fail 'rootfs/proc가 비어 있지 않습니다. 자동으로 지우지 않습니다.'
}

if [[ "$MODE" == prepare ]]; then
  [[ $# == 1 || $# == 2 ]] || fail 'prepare에는 선택적으로 rootfs 전체 경로 하나만 전달하세요.'
  (( EUID != 0 )) || fail 'sudo bash가 아니라 일반 사용자 호스트에서 실행하세요.'
  [[ -n ${HOME:-} && "$HOME" == /* && "$HOME" != / ]] || fail '사용자 홈 경로를 확인하세요.'
  ROOTFS=${2-"$HOME/cloud-virtualization/assets/busybox-rootfs"}
  validate_prepare_path "$ROOTFS"
  [[ $(cat /proc/1/comm) == systemd ]] || fail '내부 환경이 아닌 호스트에서 실행하세요.'
  PARENT=$(dirname -- "$ROOTFS")
  WORKER="$HERE/resource-workload-linux-x86_64"
  [[ $(uname -m) == x86_64 ]] || fail '제공 실행 파일은 Linux x86-64용입니다. 다른 CPU는 교수자 준비 안내를 따르세요.'
  [[ -f "$WORKER" && ! -L "$WORKER" ]] || fail '같은 폴더의 부하 실행 파일이 필요합니다.'
  # 전송 중 파일이 바뀌지 않았는지만 확인합니다. 실험 결과를 판정하지 않습니다.
  EXPECTED=f7baa72d3c79197f21fb8ff1c0dbe45f623589863bc9f5f17eec9fc688fe382f
  ACTUAL=$(sha256sum -- "$WORKER")
  [[ "${ACTUAL%% *}" == "$EXPECTED" ]] || fail '제공 실행 파일의 지문이 다릅니다. 배포 파일을 확인하세요.'
  command -v sudo >/dev/null || fail 'sudo 권한이 준비된 학생 VM이 필요합니다.'
  command -v apt-get >/dev/null || fail 'Ubuntu/Debian 준비 절차입니다.'
  say "일반 사용자 $(id -un), 기존 경로 $ROOTFS"
  printf '%s\n' '다른 창에 남아 있는 지난 실습 셸은 먼저 정상 정리해야 합니다.'
  # 학교 이미지의 NOPASSWD 정책도 사용합니다. 필요한 경우에만 암호를 묻습니다.
  sudo -n true 2>/dev/null || sudo -v
  # 일반 계정은 /proc/1/ns를 읽지 못할 수 있어 호스트 기준값만 sudo로 읽습니다.
  for kind in pid mnt uts; do
    [[ "$(readlink "/proc/self/ns/$kind")" == "$(sudo readlink "/proc/1/ns/$kind")" ]] ||
      fail '이전 namespace 안입니다. 정상 정리 후 호스트에서 다시 실행하세요.'
  done

  if [[ -e "$ROOTFS" || -L "$ROOTFS" ]]; then
    say '기존 rootfs를 검사합니다. 파일 트리와 설정을 덮어쓰지 않습니다.'
    validate_tree "$ROOTFS"
  else
    say 'rootfs가 없습니다. 공식 VM 패키지의 정적 BusyBox로 3주차 재료만 만듭니다.'
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade \
      busybox-static procps util-linux hostname file coreutils
    # PATH의 다른 BusyBox 대신 설치한 패키지가 제공하는 실행 파일을 선택합니다.
    BUSYBOX_FILES=$(dpkg-query -L busybox-static) || fail 'busybox-static 패키지의 파일 목록을 읽지 못했습니다.'
    BUSYBOX=
    while IFS= read -r path; do
      case "$path" in
        /bin/busybox|/usr/bin/busybox|/bin/busybox-static|/usr/bin/busybox-static)
          if [[ -f "$path" && -x "$path" ]]; then BUSYBOX=$path; break; fi ;;
      esac
    done <<< "$BUSYBOX_FILES"
    [[ -n "$BUSYBOX" ]] || fail 'busybox-static 패키지의 실행 파일을 찾지 못했습니다.'
    BUSYBOX_INFO=$(file -Lb -- "$BUSYBOX")
    [[ "$BUSYBOX_INFO" == *'statically linked'* || "$BUSYBOX_INFO" == *'static-pie linked'* ]] ||
      fail '정적 BusyBox가 아닙니다.'
    # 전체 출력을 먼저 읽어 pipefail과 grep의 조기 종료가 충돌하지 않게 합니다.
    APPLET_LIST=$("$BUSYBOX" --list)
    validate_prepare_path "$ROOTFS"
    mkdir -p -- "$PARENT"
    [[ $(readlink -f -- "$PARENT") == "$PARENT" ]] || fail '재료 경로가 예상 위치와 다릅니다.'
    STAGE=$(mktemp -d "$PARENT/.week04-prepare.XXXXXX")
    printf '새 재료를 만드는 임시 위치: %s\n' "$STAGE"
    # 실패해도 기존 rootfs를 지우지 않습니다. 이 임시 폴더도 자동 삭제하지 않습니다.
    mkdir -p "$STAGE"/{bin,etc,proc,tmp,mnt/host-share,dev,home}
    install -m 0755 "$BUSYBOX" "$STAGE/bin/busybox"
    for applet in "${APPLETS[@]}"; do
      grep -Fx -- "$applet" <<< "$APPLET_LIST" >/dev/null || fail "BusyBox 기능 누락: $applet"
      ln -s busybox "$STAGE/bin/$applet"
    done
    printf '%s\n' busybox-rootfs > "$STAGE/etc/hostname"
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$STAGE/etc/passwd"
    printf '%s\n' 'root:x:0:' > "$STAGE/etc/group"
    printf '%s\n' 'cloud-virtualization week03 BusyBox rootfs' > "$STAGE/etc/lab-environment"
    printf '%s\n' 'NAME="Cloud Virtualization BusyBox rootfs"' \
      'ID=cloudvirt-busybox' 'PRETTY_NAME="Cloud Virtualization Week03 BusyBox rootfs"' > "$STAGE/etc/os-release"
    chmod 1777 "$STAGE/tmp"
    sudo chroot "$STAGE" /bin/sh -c 'test "$(pwd)" = / && test "$(cat /etc/hostname)" = busybox-rootfs'
    # 다른 실행이 먼저 만든 대상이 있다면 -n으로 보존하고 멈춥니다.
    mv -Tn -- "$STAGE" "$ROOTFS"
    [[ ! -e "$STAGE" ]] || fail '동시에 다른 준비가 진행되었습니다. 남은 임시 폴더를 교수자와 확인하세요.'
    validate_tree "$ROOTFS"
  fi

  for cmd in unshare mount umount findmnt chroot; do
    command -v "$cmd" >/dev/null || fail "호스트 도구가 없습니다: $cmd"
  done
  check_empty_proc "$ROOTFS"
  say '자료를 사용하는 프로그램 하나를 기존 bin 폴더에 준비합니다.'
  DEST="$ROOTFS/bin/resource-workload"
  if [[ -e "$DEST" || -L "$DEST" ]]; then
    [[ -f "$DEST" && ! -L "$DEST" && -x "$DEST" ]] || fail '기존 부하 파일 형식/권한을 확인하세요.'
    cmp -s -- "$WORKER" "$DEST" || fail '기존 부하 파일이 다릅니다. 자동 교체하지 않습니다.'
    printf '%s\n' '같은 부하 파일이 이미 있어 그대로 사용합니다.'
  else
    sudo install -m 0755 -- "$WORKER" "$DEST"
  fi
  sudo chroot "$ROOTFS" /bin/resource-workload --help
  say '준비 완료. 아직 namespace나 cgroup을 만들지 않았습니다.'
  printf 'rootfs: %s\n다음: README의 실습 전 준비 확인을 진행합니다.\n' "$ROOTFS"
  exit 0
fi

[[ $# == 2 ]] || fail 'enter에는 rootfs의 전체 경로 하나를 전달하세요.'
(( EUID == 0 )) || fail '교안의 sudo systemd-run 명령 안에서 enter를 실행하세요.'
ROOTFS=$2
validate_tree "$ROOTFS"
[[ -x "$ROOTFS/bin/resource-workload" && ! -L "$ROOTFS/bin/resource-workload" ]] ||
  fail 'prepare에서 부하 실행 파일을 먼저 준비하세요.'

if [[ "$MODE" == enter ]]; then
  [[ $(cat /proc/1/comm) == systemd ]] || fail '호스트에서 시작하세요.'
  for kind in pid mnt uts; do
    [[ "$(readlink "/proc/self/ns/$kind")" == "$(readlink "/proc/1/ns/$kind")" ]] ||
      fail '이미 다른 namespace 안입니다. 환경을 중첩하지 않습니다.'
  done
  check_empty_proc "$ROOTFS"
  say '1/4: 3주차의 UTS·PID·Mount namespace를 다시 만듭니다.'
  # 자원 그룹은 이 명령 전에 학생이 만들었습니다. 여기서는 소속을 바꾸지 않습니다.
  exec unshare --uts --pid --mount --fork /bin/bash "$SELF" --inside "$ROOTFS"
fi

# 이 아래는 unshare가 새 PID namespace에서 실행하는 부분입니다.
[[ $$ == 1 ]] || fail '새 PID namespace의 PID 1이 아닙니다. 마운트하지 않습니다.'
say '2/4: 내부 이름을 cv-resource-lab으로 정합니다.'
hostname cv-resource-lab
say '3/4: 새 PID 관점의 procfs를 rootfs/proc에 연결합니다.'
mount -t proc proc "$ROOTFS/proc"
# chroot 이전 오류가 나면 방금 연결한 procfs만 해제합니다.
trap 'umount "$ROOTFS/proc" 2>/dev/null || true' EXIT
[[ $(cat "$ROOTFS/proc/1/comm") == bash ]] || fail 'procfs의 PID 1 관점이 예상과 다릅니다.'
say '4/4: PID 1 Bash를 BusyBox sh로 교체하고 rootfs를 /로 사용합니다.'
printf '%s\n' '이제 터미널 A는 내부입니다. README 명령 02부터 확인하세요.' \
  '정상 종료: 부하를 멈춘 뒤 cd / → umount /proc → exit를 한 명령씩 실행합니다.'
exec chroot "$ROOTFS" /bin/sh
