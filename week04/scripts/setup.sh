#!/usr/bin/env bash
# 4주차를 처음 시작할 때 한 번 실행하는 재료 준비입니다.
# 압축파일 안의 재료로 rootfs를 준비하며, 개별 파일을 다운로드하지 않습니다.
# 학생: bash "$HOME/week04-v1.1.0/setup.sh"
# 교수자 격리 검증: CV4_BASE="$HOME/검증폴더/cloud-virtualization" bash setup.sh
# Ubuntu/Debian을 대상으로 하며, 수업 검증 기준 환경은 Ubuntu 24.04입니다.
set -Eeuo pipefail
export LC_ALL=C

fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
say() { printf '\n[4주차 처음 한 번 준비] %s\n' "$*"; }

[[ $# == 0 ]] || fail '인자 없이 압축을 푼 폴더의 setup.sh를 실행하세요.'
[[ $(uname -s) == Linux ]] || fail 'Ubuntu/Debian 실습 VM에서 실행하세요.'
(( EUID != 0 )) || fail 'sudo bash가 아니라 일반 사용자 호스트에서 실행하세요.'
[[ $(uname -m) == x86_64 ]] || fail '제공 부하 실행 파일은 Linux x86-64용입니다.'
[[ -r /etc/os-release ]] || fail 'Ubuntu/Debian 실습 VM인지 확인하세요.'
OS_ID=$(. /etc/os-release; printf '%s' "${ID:-}")
[[ "$OS_ID" == ubuntu || "$OS_ID" == debian ]] || fail '이 준비 파일은 Ubuntu/Debian 실습 VM용입니다.'
[[ $(cat /proc/1/comm) == systemd ]] || fail '내부 BusyBox 환경을 나와 호스트에서 실행하세요.'
for cmd in sha256sum readlink dirname mkdir mktemp cp mv chmod rm bash; do
  command -v "$cmd" >/dev/null || fail "호스트에 필요한 도구가 없습니다: $cmd (교수자에게 확인하세요.)"
done
[[ -n ${HOME:-} && "$HOME" == /* && "$HOME" != / ]] || fail '사용자 홈 경로를 확인하세요.'
[[ -d "$HOME" && $(readlink -f -- "$HOME") == "$HOME" ]] || fail '홈 경로에 링크나 경로 별칭이 있습니다.'

BASE=${CV4_BASE-"$HOME/cloud-virtualization"}
SOURCE_DIR=$(dirname -- "$(readlink -f -- "$0")")
[[ "$BASE" == "$HOME/"* && "$BASE" == */cloud-virtualization ]] ||
  fail 'CV4_BASE는 홈 아래의 전체 경로이며 끝이 cloud-virtualization이어야 합니다.'
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
  f0f745444870423512f2d9a77244530206b4cb13ea0e023e0993c92dd13f4acd
  732939ce48a64d7ddf255e3283f05270f44ef1148d08e4e18fafa16fbd649e8f
  d4556bfbd140a2a78df34130712bd8b53c70e194af57ea01c114033feb7910f3
)
check_file() {
  local path=$1 expected=$2 actual
  [[ -f "$path" && ! -L "$path" ]] || fail "일반 파일이 아니거나 링크입니다: $path"
  actual=$(sha256sum -- "$path")
  [[ "${actual%% *}" == "$expected" ]] ||
    fail "배포 파일과 내용이 다릅니다. 자동으로 덮어쓰지 않습니다: $path"
}

# 압축파일의 재료와 기존 자료를 쓰기 작업 전에 확인합니다.
for index in "${!FILES[@]}"; do
  check_file "$SOURCE_DIR/${FILES[$index]}" "${HASHES[$index]}"
  target="$PAYLOAD_DIR/${FILES[$index]}"
  if [[ -e "$target" || -L "$target" ]]; then check_file "$target" "${HASHES[$index]}"; fi
done

say "준비 파일 위치: $PAYLOAD_DIR"
mkdir -p -- "$PAYLOAD_DIR"
[[ $(readlink -f -- "$PAYLOAD_DIR") == "$PAYLOAD_DIR" ]] || fail '준비 파일 경로가 예상 위치와 다릅니다.'
TMP_FILE=
# 삭제 대상은 이 실행에서 만든 임시 복사 파일 하나뿐입니다.
trap 'if [[ -n "$TMP_FILE" ]]; then rm -f -- "$TMP_FILE"; fi' EXIT

for index in "${!FILES[@]}"; do
  name=${FILES[$index]}
  target="$PAYLOAD_DIR/$name"
  if [[ -e "$target" || -L "$target" ]]; then
    check_file "$target" "${HASHES[$index]}"
    printf '같은 파일이 있어 그대로 사용합니다: %s\n' "$name"
    continue
  fi
  say "압축파일의 준비 재료를 복사합니다: $name"
  TMP_FILE=$(mktemp "$PAYLOAD_DIR/.week04-copy.XXXXXX")
  cp -- "$SOURCE_DIR/$name" "$TMP_FILE"
  check_file "$TMP_FILE" "${HASHES[$index]}"
  if [[ "$name" == resource-workload-linux-x86_64 ]]; then chmod 0755 "$TMP_FILE"; else chmod 0644 "$TMP_FILE"; fi
  # 동시에 다른 실행이 만든 파일도 덮어쓰지 않습니다.
  mv -Tn -- "$TMP_FILE" "$target"
  [[ ! -e "$TMP_FILE" ]] || fail "다른 준비 실행이 같은 파일을 만들었습니다: $target"
  TMP_FILE=
  printf '복사와 파일 확인 완료: %s\n' "$name"
done

say '3주차 rootfs를 확인합니다. 없으면 이전 학습 재료부터 만듭니다.'
bash "$PAYLOAD_DIR/restore-week03.sh" prepare "$ROOTFS"
say '처음 한 번 준비가 끝났습니다.'
printf '준비 파일: %s\nrootfs: %s\n' "$PAYLOAD_DIR" "$ROOTFS"
printf '%s\n' 'README의 실습 전 준비 확인을 진행하세요. 아직 namespace나 cgroup은 만들지 않았습니다.'
