#!/usr/bin/env bash
# ping_matrix_check_from_infra.sh
#
# Infra VM(192.168.14.62)의 script_net/ 안에서 실행 — 13대 VM 전부를 SSH로 돌며
# "같은 Zone 내부" ping 매트릭스를 자동으로 검증.
#
# 멀티홈 VM(LB1/LB2, Worker1~3, DevOps, Infra)은 자기가 속한 Zone마다 각각
# 별도로 테스트되므로(예: Worker1은 MGMT/INTERNAL/DATA 세 번 다 등장), 이 매트릭스 자체가
# "멀티홈 VM 경유 경로" 검증도 포함함 — 별도 로직 불필요
# (1차_IP_주소설계_전체표.md "Zone 배정 근거" 참고: Worker가 Internal+Data를
# 동시에 가져서 DB 접근이 되는 구조 등).
#
# 전제:
#   - 13대 VM 전부 root 비밀번호 = centos
#   - Management(192.168.14.0/24)로 전 VM 22/tcp 접속 가능(ip_addr_check_from_infra.sh와 동일 전제)
#
# 사용법 (Infra VM, script_net/ 안에서):
#   chmod +x ping_matrix_check_from_infra.sh
#   ./ping_matrix_check_from_infra.sh
#   -> 화면 출력 + script_net/logs/ping_matrix_result_YYYYMMDD_HHMM.log 자동 저장
#   -> 대상 약 300여 건(양방향)이라 전체 실행에 몇 분 걸릴 수 있음
#
# 참고: DMZ<->Data처럼 두 Zone을 동시에 가진 VM이 없는 조합은 애초에 경로가 없어서
#       이 스크립트의 매트릭스 생성 로직 자체가 그런 조합을 만들지 않음(설계상 정상).
#       그 전제가 실제로 맞는지 맨 아래에서 격리 체크(DMZ -> Data) 1건을 별도로 확인함.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ping_matrix_result_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOG_FILE") 2>&1
echo ">>> 로그 저장 위치: $LOG_FILE"
echo ""

SSH_PASS="centos"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

if ! command -v sshpass >/dev/null 2>&1; then
    echo ">>> sshpass 미설치 — 설치 시도"
    dnf install -y epel-release >/dev/null 2>&1
    dnf install -y sshpass
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "!! sshpass 설치 실패 — 수동 설치 후 다시 실행하세요 (dnf install sshpass)"
        exit 1
    fi
fi

# ---- Zone별 IP (1차_IP_주소설계_전체표.md Layer 2 표 기준. 소속 없는 Zone은 키가 아예 없음) ----
declare -A MGMT_IP=(
  [lb1]="192.168.14.11" [lb2]="192.168.14.12"
  [cp1]="192.168.14.31" [cp2]="192.168.14.32" [cp3]="192.168.14.33"
  [worker1]="192.168.14.41" [worker2]="192.168.14.42" [worker3]="192.168.14.43"
  [devops]="192.168.14.21"
  [db-primary]="192.168.14.51" [db-replica]="192.168.14.52"
  [nfs]="192.168.14.61" [infra]="192.168.14.62"
)
declare -A DMZ_IP=(
  [lb1]="192.168.24.11" [lb2]="192.168.24.12"
)
declare -A INTERNAL_IP=(
  [lb1]="192.168.34.11" [lb2]="192.168.34.12"
  [cp1]="192.168.34.31" [cp2]="192.168.34.32" [cp3]="192.168.34.33"
  [worker1]="192.168.34.41" [worker2]="192.168.34.42" [worker3]="192.168.34.43"
  [devops]="192.168.34.21" [infra]="192.168.34.62"
)
declare -A DATA_IP=(
  [worker1]="192.168.44.41" [worker2]="192.168.44.42" [worker3]="192.168.44.43"
  [devops]="192.168.44.21"
  [db-primary]="192.168.44.51" [db-replica]="192.168.44.52"
  [nfs]="192.168.44.61" [infra]="192.168.44.62"
)

ALL_VMS=(lb1 lb2 cp1 cp2 cp3 worker1 worker2 worker3 devops db-primary db-replica nfs infra)

TOTAL_OK=0
TOTAL_FAIL=0
declare -A ZONE_OK=( [MGMT]=0 [DMZ]=0 [INTERNAL]=0 [DATA]=0 )
declare -A ZONE_FAIL=( [MGMT]=0 [DMZ]=0 [INTERNAL]=0 [DATA]=0 )
FAIL_LINES=()

# 원격/로컬 공통으로 쓰는 ping 루프 — "zone dstname dstip"를 stdin으로 받아
# "OK|FAIL zone dstname dstip" 한 줄씩 출력. src 이름은 여기서 다루지 않고
# 호출부(로컬)에서 붙임 — 변수 이스케이프 이슈를 피하기 위함.
read -r -d '' PING_LOOP <<'EOF'
while read -r zone dstname dstip; do
    [ -z "$dstip" ] && continue
    if ping -c 1 -W 1 -q "$dstip" >/dev/null 2>&1; then
        echo "OK $zone $dstname $dstip"
    else
        echo "FAIL $zone $dstname $dstip"
    fi
done
EOF

run_matrix_for() {
    local src="$1"
    local src_mgmt_ip="${MGMT_IP[$src]}"
    local -a targets=()

    for dst in "${ALL_VMS[@]}"; do
        [ "$dst" == "$src" ] && continue
        if [[ -n "${MGMT_IP[$src]:-}" && -n "${MGMT_IP[$dst]:-}" ]]; then
            targets+=("MGMT $dst ${MGMT_IP[$dst]}")
        fi
        if [[ -n "${DMZ_IP[$src]:-}" && -n "${DMZ_IP[$dst]:-}" ]]; then
            targets+=("DMZ $dst ${DMZ_IP[$dst]}")
        fi
        if [[ -n "${INTERNAL_IP[$src]:-}" && -n "${INTERNAL_IP[$dst]:-}" ]]; then
            targets+=("INTERNAL $dst ${INTERNAL_IP[$dst]}")
        fi
        if [[ -n "${DATA_IP[$src]:-}" && -n "${DATA_IP[$dst]:-}" ]]; then
            targets+=("DATA $dst ${DATA_IP[$dst]}")
        fi
    done

    [ "${#targets[@]}" -eq 0 ] && return

    echo "----- ${src} 기준 (${#targets[@]}건) -----"

    local result
    if [ "$src" == "infra" ]; then
        result="$(printf '%s\n' "${targets[@]}" | bash -c "$PING_LOOP")"
    else
        result="$(printf '%s\n' "${targets[@]}" | sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@${src_mgmt_ip}" "$PING_LOOP")"
        if [ -z "$result" ]; then
            echo "!! ${src} SSH 접속 실패 — 스킵 (sshd/방화벽/비밀번호 확인)"
            echo ""
            return
        fi
    fi

    while read -r status zone dstname dstip; do
        [ -z "$status" ] && continue
        if [ "$status" == "OK" ]; then
            echo "OK   [$zone] ${src} -> $dstname ($dstip)"
            TOTAL_OK=$((TOTAL_OK+1))
            ZONE_OK[$zone]=$(( ${ZONE_OK[$zone]:-0} + 1 ))
        else
            local line="FAIL [$zone] ${src} -> $dstname ($dstip)"
            echo "$line"
            TOTAL_FAIL=$((TOTAL_FAIL+1))
            ZONE_FAIL[$zone]=$(( ${ZONE_FAIL[$zone]:-0} + 1 ))
            FAIL_LINES+=("$line")
        fi
    done <<< "$result"

    echo ""
}

for vm in "${ALL_VMS[@]}"; do
    run_matrix_for "$vm"
done

echo "===== 격리 확인 (DMZ -> Data, 실패가 정상) ====="
iso_result="$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@${MGMT_IP[lb1]}" \
    "ping -c 1 -W 1 -q 192.168.44.41 >/dev/null 2>&1 && echo REACHABLE || echo UNREACHABLE")"
if [ -z "$iso_result" ]; then
    echo "!! lb1 SSH 접속 실패로 격리 확인 스킵"
elif [ "$iso_result" == "UNREACHABLE" ]; then
    echo "OK   — lb1(DMZ) -> worker1 Data(192.168.44.41) 도달 불가 확인(설계대로 정상)"
else
    echo "!! 경고 — lb1(DMZ)에서 worker1 Data(192.168.44.41)로 ping이 성공함. 의도치 않은 경로(라우팅/방화벽) 재확인 필요"
fi
echo ""

echo "===== 요약 ====="
echo "전체: OK ${TOTAL_OK} / FAIL ${TOTAL_FAIL}"
for zone in MGMT DMZ INTERNAL DATA; do
    echo "  ${zone}: OK ${ZONE_OK[$zone]:-0} / FAIL ${ZONE_FAIL[$zone]:-0}"
done

if [ "${#FAIL_LINES[@]}" -gt 0 ]; then
    echo ""
    echo "!! FAIL 목록:"
    for l in "${FAIL_LINES[@]}"; do
        echo "   $l"
    done
fi
