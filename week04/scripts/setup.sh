#!/usr/bin/env bash
# 4주차를 처음 시작할 때 한 번 실행하는 재료 준비입니다.
# 파일 다운로드와 rootfs 준비만 하며, namespace 진입과 cgroup 설정은 하지 않습니다.
# 학생: bash week04-setup.sh
# 교수자 격리 검증: CV4_BASE="$HOME/검증폴더/cloud-virtualization" bash week04-setup.sh
# CV4_REF는 기본 main이며, 검증할 40자리 Git 커밋 SHA도 지정할 수 있습니다.
# Ubuntu/Debian을 대상으로 하며, 수업 검증 기준 환경은 Ubuntu 24.04입니다.
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[4주차 처음 한 번 준비] %s\n' "$*"; }

[[ $# == 0 ]] || fail '인자 없이 bash week04-setup.sh로 실행하세요.'
[[ $(uname -s) == Linux ]] || fail 'Ubuntu/Debian 실습 VM에서 실행하세요.'
(( EUID != 0 )) || fail 'sudo bash가 아니라 일반 사용자 호스트에서 실행하세요.'
[[ $(uname -m) == x86_64 ]] || fail '제공 부하 실행 파일은 Linux x86-64용입니다.'
[[ -r /etc/os-release ]] || fail 'Ubuntu/Debian 실습 VM인지 확인하세요.'
OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
[[ "$OS_ID" == ubuntu || "$OS_ID" == debian ]] || fail '이 준비 파일은 Ubuntu/Debian 실습 VM용입니다.'
[[ $(cat /proc/1/comm) == systemd ]] || fail '내부 BusyBox 환경을 나와 호스트에서 실행하세요.'
for cmd in wget timeout sha256sum readlink mkdir mktemp mv chmod rm bash; do
  command -v "$cmd" >/dev/null || fail "호스트에 필요한 도구가 없습니다: $cmd (교수자에게 확인하세요.)"
done
[[ -n ${HOME:-} && "$HOME" == /* && "$HOME" != / ]] || fail '사용자 홈 경로를 확인하세요.'
[[ -d "$HOME" && $(readlink -f -- "$HOME") == "$HOME" ]] || fail '홈 경로에 링크나 경로 별칭이 있습니다.'

BASE=${CV4_BASE-"$HOME/cloud-virtualization"}
REF=${CV4_REF-main}
[[ "$BASE" == "$HOME/"* && "$BASE" == */cloud-virtualization ]] ||
  fail 'CV4_BASE는 홈 아래의 전체 경로이며 끝이 cloud-virtualization이어야 합니다.'
[[ "$REF" == main || "$REF" =~ ^[0-9a-fA-F]{40}$ ]] ||
  fail 'CV4_REF는 main 또는 40자리 Git 커밋 SHA만 사용할 수 있습니다.'
PAYLOAD_DIR="$BASE/week04/scripts"
ROOTFS="$BASE/assets/busybox-rootfs"

# 폴더가 아직 없어도 허용합니다. 쓰기 전에 모든 기존 경로 요소를 확인합니다.
validate_directory_path() {
  local path=$1 current=$HOME relative part
  local -a parts
  [[ "$path" == "$HOME/"* && "$path" != *'/./'* && "$path" != *'/../'* && "$path" != *'//'* ]] ||
    fail '홈 아래 경로를 . 또는 .., 중복 / 없이 적으세요.'
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || fail '줄바꿈이 들어간 경로는 사용할 수 없습니다.'
  relative=${path#"$HOME"/}
  IFS=/ read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    current+="/$part"
    [[ ! -L "$current" ]] || fail "재료 경로에 심볼릭 링크가 있습니다: $current"
    [[ ! -e "$current" || -d "$current" ]] || fail "폴더가 아닌 경로가 있습니다: $current"
  done
}
validate_directory_path "$BASE"
validate_directory_path "$PAYLOAD_DIR"
validate_directory_path "$ROOTFS"

# 교육용 C 소스도 함께 받습니다. 원격에서 받은 검사표를 그대로 믿지 않고
# 이 배포본에서 확인한 파일 지문과 비교합니다.
FILES=(restore-week03.sh resource-workload-linux-x86_64 resource-workload.c)
HASHES=(
  90c29b7ee0954711ddbacf829a38c9d95dbea1d7b21d5261d501d0b5aa00aa33
  f7baa72d3c79197f21fb8ff1c0dbe45f623589863bc9f5f17eec9fc688fe382f
  08503a6be1dc240e155495471242498c29f461ae78da8756743b80402c0918d3
)
check_file() {
  local path=$1 expected=$2 actual
  [[ -f "$path" && ! -L "$path" ]] || fail "일반 파일이 아니거나 링크입니다: $path"
  actual=$(sha256sum -- "$path")
  [[ "${actual%% *}" == "$expected" ]] ||
    fail "배포 파일과 내용이 다릅니다. 자동으로 덮어쓰지 않습니다: $path"
}

# 기존 자료가 다르면 다운로드나 폴더 생성 전에 멈춥니다.
for index in "${!FILES[@]}"; do
  target="$PAYLOAD_DIR/${FILES[$index]}"
  if [[ -e "$target" || -L "$target" ]]; then check_file "$target" "${HASHES[$index]}"; fi
done

say "준비 파일 위치: $PAYLOAD_DIR"
mkdir -p -- "$PAYLOAD_DIR"
[[ $(readlink -f -- "$PAYLOAD_DIR") == "$PAYLOAD_DIR" ]] || fail '준비 파일 경로가 예상 위치와 다릅니다.'
TMP_FILE=
# 삭제 대상은 이 실행에서 만든 임시 다운로드 파일 하나뿐입니다.
trap 'if [[ -n "$TMP_FILE" ]]; then rm -f -- "$TMP_FILE"; fi' EXIT

for index in "${!FILES[@]}"; do
  name=${FILES[$index]}
  target="$PAYLOAD_DIR/$name"
  if [[ -e "$target" || -L "$target" ]]; then
    check_file "$target" "${HASHES[$index]}"
    printf '같은 파일이 있어 그대로 사용합니다: %s\n' "$name"
    continue
  fi
  say "준비 파일을 받습니다: $name"
  TMP_FILE=$(mktemp "$PAYLOAD_DIR/.week04-download.XXXXXX")
  # 학교 VM에서 잘 연결되는 API를 먼저 사용합니다. 각 경로의 전체 대기는 35초로 제한합니다.
  if ! timeout 35s wget --quiet --timeout=15 --tries=2 --header='Accept: application/vnd.github.raw+json' \
    -O "$TMP_FILE" "https://api.github.com/repos/choong-syu/cloud-virtualization/contents/week04/scripts/$name?ref=$REF"; then
    printf '%s\n' 'GitHub API 연결이 어려워 원본 파일 주소(raw)로 다시 받습니다.'
    timeout 35s wget --quiet --timeout=15 --tries=2 \
      -O "$TMP_FILE" "https://raw.githubusercontent.com/choong-syu/cloud-virtualization/$REF/week04/scripts/$name" ||
      fail "다운로드하지 못했습니다. 인터넷 연결을 확인한 뒤 다시 실행하세요: $name"
  fi
  check_file "$TMP_FILE" "${HASHES[$index]}"
  if [[ "$name" == resource-workload-linux-x86_64 ]]; then chmod 0755 "$TMP_FILE"; else chmod 0644 "$TMP_FILE"; fi
  # 동시에 다른 실행이 만든 파일도 덮어쓰지 않습니다.
  mv -Tn -- "$TMP_FILE" "$target"
  [[ ! -e "$TMP_FILE" ]] || fail "다른 준비 실행이 같은 파일을 만들었습니다: $target"
  TMP_FILE=
  printf '다운로드와 파일 확인 완료: %s\n' "$name"
done

say '3주차 rootfs를 확인합니다. 없으면 이전 학습 재료부터 만듭니다.'
bash "$PAYLOAD_DIR/restore-week03.sh" prepare "$ROOTFS"
say '처음 한 번 준비가 끝났습니다.'
printf '준비 파일: %s\nrootfs: %s\n' "$PAYLOAD_DIR" "$ROOTFS"
printf '%s\n' 'README의 실습 전 준비 확인을 진행하세요. 아직 namespace나 cgroup은 만들지 않았습니다.'
