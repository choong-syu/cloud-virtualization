#!/usr/bin/env bash
# GitHub에서 받거나 교수자가 배포한 ~/week07에서 일반 사용자로 실행합니다.
# 준비만 수행합니다. 컨테이너 실행과 Docker 설치는 학생이 본문에서 합니다.

# 1. 오류 처리 방식
# 명령 실패(-e), 미정의 변수 사용(-u), 파이프 앞쪽 명령 실패(pipefail) 시 중단합니다.
# -E는 ERR 트랩을 함수·서브셸에도 상속하는 옵션입니다.
set -Eeuo pipefail

# file 등의 출력 언어를 고정해 아래 문자열 검사가 환경에 따라 달라지지 않게 합니다.
export LC_ALL=C

# 조건을 만족하지 못하면 이유를 표준 오류로 출력하고 종료합니다.
fail() {
  printf 'STOP: %s\n' "$*" >&2
  exit 1
}

# 2. 실행 계정·운영체제·자료 위치 확인
# 전체 스크립트를 root로 실행하지 않고, 설치 등 필요한 명령에만 sudo를 씁니다.
(( EUID != 0 )) || fail 'sudo를 붙이지 말고 bash prepare.sh로 실행하세요.'

# 운영체제 정보를 읽어 수업에서 검증한 Ubuntu 버전인지 확인합니다.
. /etc/os-release
[[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || fail '검증 대상은 Ubuntu 24.04 VM입니다.'

# 현재 터미널 위치가 아니라 이 스크립트가 저장된 실제 디렉터리를 기준으로 합니다.
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[[ "$BASE" == "$HOME/week07" ]] || fail '~/week07에 배치한 뒤 실행하세요.'

# Cgroup v2와 수업용 설정 파일 두 개가 준비되어 있어야 합니다.
[[ -f /sys/fs/cgroup/cgroup.controllers ]] || fail 'Cgroup v2가 필요합니다.'
for name in shell sleep-128; do
  [[ -f "$BASE/configs/$name.json" ]] || fail "설정 파일 누락: configs/$name.json"
done

# 3. 설치 권한 확인과 실습 도구 설치
# NOPASSWD 정책이면 명령 실행을 먼저 확인합니다. sudo -v는 검증 정책에
# 따라 명령이 암호 없이 허용되어도 비밀번호를 요구할 수 있습니다.
sudo -n true 2>/dev/null || sudo -v

# 패키지 목록을 갱신하고 런타임·BusyBox·관찰 도구를 설치합니다.
# libcap2-bin은 Capability 값을 권한 이름으로 해석하는 capsh를 제공합니다.
# DEBIAN_FRONTEND는 이 설치 명령에서 대화형 설정 질문을 줄이기 위한 값입니다.
sudo apt-get update
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
  runc busybox-static curl iproute2 procps util-linux file nano libcap2-bin

# Python 3는 마지막 JSON 문법 검사에 사용합니다. 없으면 여기서 중단합니다.
command -v python3 >/dev/null || fail 'python3가 필요합니다.'

# 정적 BusyBox는 rootfs에 별도 공유 라이브러리를 복사하지 않아도 실행됩니다.
BUSYBOX_BIN="$(command -v busybox)"
file -L "$BUSYBOX_BIN" | grep -Eq 'statically linked|static-pie linked' || fail '정적 BusyBox가 필요합니다.'

# 4. 컨테이너용 파일 시스템(rootfs) 준비
# DEST: 이번 주 rootfs 위치 / OLD: 재사용할 수 있는 3주차 rootfs 위치
mkdir -p "$BASE/bundle"
DEST="$BASE/bundle/rootfs"
OLD="$HOME/cloud-virtualization/assets/busybox-rootfs"

# 경우 A: 기존 7주차 rootfs가 있으면 기본 조건을 확인하고 유지합니다.
if [[ -e "$DEST" || -L "$DEST" ]]; then
  [[ -d "$DEST" && ! -L "$DEST" && -x "$DEST/bin/busybox" ]] || fail '기존 bundle/rootfs를 교수자와 확인하세요.'
  printf '%s\n' '기존 7주차 rootfs를 유지합니다.'
else
  # 경우 B: 7주차 rootfs가 없고 3주차 자료가 있으면 복사합니다.
  if [[ -d "$OLD" && ! -L "$OLD" && -x "$OLD/bin/busybox" ]]; then
    # 이전 주차 원본을 변경하지 않습니다. 남은 마운트가 있으면 복사하지 않습니다.
    if findmnt -rn -o TARGET | grep -F "$OLD/" >/dev/null; then
      fail '3주차 rootfs 아래에 마운트가 남아 있습니다. 이전 실습을 먼저 정리하세요.'
    fi
    # -a는 파일 권한과 심볼릭 링크 등의 속성을 보존합니다.
    cp -a -- "$OLD" "$DEST"
    printf '%s\n' '3주차 rootfs를 7주차 폴더로 복사했습니다.'
  else
    # 경우 C: 재사용할 자료도 없으면 최소 rootfs를 새로 만듭니다.
    mkdir -p "$DEST"/{bin,etc,proc,sys,dev,tmp,root}
    # BusyBox 실행 파일 하나가 여러 기본 명령의 역할을 담당합니다.
    install -m 0755 "$BUSYBOX_BIN" "$DEST/bin/busybox"

    # 각 명령 이름을 busybox로 연결하면, 호출한 이름에 맞는 기능이 실행됩니다.
    for applet in sh ls cat ps hostname sleep echo pwd readlink grep touch uname ip ping; do
      ln -s busybox "$DEST/bin/$applet"
    done

    # rootfs 내부에서 사용할 최소 계정·그룹·호스트 이름·실습 안내 파일입니다.
    # 호스트의 /etc 파일은 변경하지 않습니다.
    printf '%s\n' 'root:x:0:0:root:/root:/bin/sh' > "$DEST/etc/passwd"
    printf '%s\n' 'root:x:0:' > "$DEST/etc/group"
    printf '%s\n' busybox-rootfs > "$DEST/etc/hostname"
    printf '%s\n' 'Cloud Virtualization BusyBox rootfs' > "$DEST/etc/lab-environment"
    printf '%s\n' '3주차와 같은 방식의 정적 BusyBox rootfs를 새로 준비했습니다.'
  fi
fi

# 5. 기존·복사·신규 rootfs에 공통으로 필요한 항목 보완
mkdir -p "$DEST"/{proc,sys,dev,tmp,root}

# /tmp는 모두 쓸 수 있게 하되, sticky bit로 다른 사용자 파일의 삭제를 제한합니다.
chmod 1777 "$DEST/tmp"

# 기존 명령이나 심볼릭 링크는 유지하고, 없는 기본 명령만 연결합니다.
for applet in sh ls cat ps hostname sleep echo pwd readlink grep touch uname; do
  if [[ ! -e "$DEST/bin/$applet" && ! -L "$DEST/bin/$applet" ]]; then
    ln -s busybox "$DEST/bin/$applet"
  fi
done

# 6. 준비된 rootfs의 실행 조건 확인
file -L "$DEST/bin/busybox" | grep -Eq 'statically linked|static-pie linked' || fail 'rootfs의 BusyBox가 정적 파일이 아닙니다.'

# rootfs를 루트 디렉터리로 삼아 셸을 잠시 실행하고 필수 실행 파일을 확인합니다.
# 이 검사는 runc 컨테이너를 생성하거나 실행하는 단계가 아닙니다.
sudo chroot "$DEST" /bin/sh -c 'test -x /bin/sleep && test -x /bin/ps && test -x /bin/hostname'

# 7. JSON 문법 검사
# 정상인 파일은 출력하지 않고, 문법 오류가 있으면 오류 메시지와 함께 중단합니다.
for name in shell sleep-128; do
  python3 -m json.tool "$BASE/configs/$name.json" >/dev/null
done

# 8. 준비 완료 안내: 이후 runc·Docker 실습은 README에서 진행합니다.
printf '\n준비 완료: %s\n' "$BASE/bundle"
printf '%s\n' '이 준비 단계는 Docker를 설치하지 않습니다. README의 실행 도구 확인 단계부터 진행하세요.'
