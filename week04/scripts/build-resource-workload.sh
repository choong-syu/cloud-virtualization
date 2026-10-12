#!/usr/bin/env bash
# 교수자용: Linux x86-64에서 정적 실행 파일을 다시 빌드함.
set -euo pipefail
cd -- "$(dirname -- "$0")"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || {
    printf 'Linux x86-64에서 빌드하세요.\n' >&2
    exit 1
}
gcc -std=c11 -O2 -Wall -Wextra -Werror -static -s \
    resource-workload.c -o resource-workload-linux-x86_64
chmod 755 resource-workload-linux-x86_64
./resource-workload-linux-x86_64 --version
sha256sum resource-workload-linux-x86_64
