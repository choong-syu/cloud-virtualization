# 터미널 B에서 사용하는 조회 전용 함수임. 한도나 프로세스를 변경하지 않음.
measure_cpu() (
    local cg="${1:-}" before after key value
    local -a keys=(usage_usec nr_periods nr_throttled throttled_usec)
    local -a labels=('전체 CPU 사용 시간' '전체 CPU 제한 주기 수' 'CPU 제한이 걸린 주기 수' 'CPU 제한으로 대기한 누적 시간')
    local -a units=('μs' '회' '회' 'μs')
    local -A start=() end=()
    if [[ -z "$cg" || ! -r "$cg/cpu.stat" ]]; then
        printf '측정할 cpu.stat을 찾을 수 없습니다. CG와 그룹 실행 상태를 확인하세요.\n' >&2
        return 1
    fi
    printf '5초간 cpu.stat의 변화를 확인합니다.\n'
    before=$(cat "$cg/cpu.stat") || return 1
    while read -r key value; do
        [[ -n "$key" ]] && start["$key"]="$value"
    done <<< "$before"
    for key in "${keys[@]}"; do
        [[ ${start[$key]:-} =~ ^[0-9]+$ ]] || {
            printf '필요한 항목이 없습니다: %s\n' "$key" >&2; return 1;
        }
    done
    printf '\n[측정 시작: cpu.stat 원본]\n%s\n\n' "$before"
    printf '5초 동안 sleep\n'
    sleep 5 || return 1
    after=$(cat "$cg/cpu.stat") || return 1
    while read -r key value; do
        [[ -n "$key" ]] && end["$key"]="$value"
    done <<< "$after"
    for key in "${keys[@]}"; do
        [[ ${end[$key]:-} =~ ^[0-9]+$ ]] && (( end[$key] >= start[$key] )) || {
            printf '측정 중 그룹이나 통계가 변경되었습니다. 다시 측정하세요.\n' >&2; return 1;
        }
    done
    printf '\n[측정 종료: cpu.stat 원본]\n%s\n\n' "$after"
    printf '\n[측정 전/후 차이: 종료값 - 시작값]\n'
    for i in "${!keys[@]}"; do
        key=${keys[i]}
        printf '%s(%s)의 측정 전/후 차이는 %s%s입니다.\n' "$key" "${labels[i]}" "$((end[$key] - start[$key]))" "${units[i]}"
    done
)
