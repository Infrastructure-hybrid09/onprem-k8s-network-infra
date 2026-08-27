#!/usr/bin/env bash
# firewalld_status_check_from_infra.sh
#
# Infra VM(192.168.14.62)의 script_net/ 안에서 실행 — 13대 VM firewalld 상태를
# 방화벽_정책_1차_정리.md §7(CP/Worker 비활성화) · firewalld_setup.sh(nw-* zone) 기준으로
# 일괄 점검. 마지막에 outside-to-jenkins 정책 옛 IP(10.1.93.82) 자동 정정까지 수행.
#
# 점검 항목:
#   1) devops/db-primary/db-replica/nfs/infra — firewalld 활성 + nw-* zone(예상 목록) 존재 확인
#      + 내장 dmz/internal zone에 우리 NIC이 잘못 붙은 게 없는지(과거 lb1 이슈) 재확인
#   2) cp1~3/worker1~3 — firewalld가 §7 결정대로 비활성 상태인지 확인
#   3) Infra: outside-to-jenkins 정책 rich-rule에 옛 IP(10.1.93.82)가 남아있으면
#      제거 후 정정값(10.1.93.4)으로 자동 재적용
#   4) Infra: external zone 기본 서비스 목록 + masquerade 상태 출력
#
# 전제: 13대 VM 전부 root 비밀번호 = centos, Management 22/tcp 접속 가능
#
# 사용법 (Infra, script_net/ 안에서):
#   chmod +x firewalld_status_check_from_infra.sh
#   ./firewalld_status_check_from_infra.sh
#   -> 화면 출력 + script_net/logs/firewalld_status_result_YYYYMMDD_HHMM.log 자동 저장

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/firewalld_status_result_$(date +%Y%m%d_%H%M).log"
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

declare -A MGMT_IP=(
  [lb1]="192.168.14.11" [lb2]="192.168.14.12"
  [devops]="192.168.14.21"
  [db-primary]="192.168.14.51" [db-replica]="192.168.14.52"
  [nfs]="192.168.14.61"
  [cp1]="192.168.14.31" [cp2]="192.168.14.32" [cp3]="192.168.14.33"
  [worker1]="192.168.14.41" [worker2]="192.168.14.42" [worker3]="192.168.14.43"
)

# firewalld 활성 VM별 기대 nw-* zone 목록 (firewalld_setup.sh의 find_iface 대상과 동일 기준)
declare -A EXPECTED_ZONES=(
  [lb1]="nw-mgmt nw-dmz nw-internal"
  [lb2]="nw-mgmt nw-dmz nw-internal"
  [devops]="nw-mgmt nw-internal nw-data"
  [db-primary]="nw-mgmt nw-data"
  [db-replica]="nw-mgmt nw-data"
  [nfs]="nw-mgmt nw-data"
)

FW_ACTIVE_VMS=(lb1 lb2 devops db-primary db-replica nfs)
FW_DISABLED_VMS=(cp1 cp2 cp3 worker1 worker2 worker3)

WARN_COUNT=0

echo "===================================================================="
echo " 1) firewalld 활성 VM (lb1/lb2/devops/db-primary/db-replica/nfs)"
echo "===================================================================="
for vm in "${FW_ACTIVE_VMS[@]}"; do
    ip_addr="${MGMT_IP[$vm]}"
    echo "----- ${vm} -----"

    remote_out="$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@${ip_addr}" '
        echo "STATE:$(systemctl is-active firewalld 2>/dev/null)"
        echo "---ZONES---"
        firewall-cmd --get-active-zones
        echo "---DMZIF---"
        firewall-cmd --zone=dmz --list-interfaces 2>/dev/null
        echo "---INTIF---"
        firewall-cmd --zone=internal --list-interfaces 2>/dev/null
    ')"

    if [ -z "$remote_out" ]; then
        echo "!! SSH 접속 실패 — 스킵"
        WARN_COUNT=$((WARN_COUNT+1))
        echo ""
        continue
    fi

    state="$(echo "$remote_out" | grep '^STATE:' | cut -d: -f2)"
    if [ "$state" == "active" ]; then
        echo "OK   firewalld active"
    else
        echo "!! firewalld 상태 이상: '$state' (active여야 함) — firewalld_setup.sh 실행 필요"
        WARN_COUNT=$((WARN_COUNT+1))
    fi

    zones_block="$(echo "$remote_out" | sed -n '/---ZONES---/,/---DMZIF---/p')"
    for zone in ${EXPECTED_ZONES[$vm]}; do
        if echo "$zones_block" | grep -qw "$zone"; then
            echo "OK   ${zone} 존재"
        else
            echo "!! ${zone} 없음 — firewalld_setup.sh 미적용/누락 의심"
            WARN_COUNT=$((WARN_COUNT+1))
        fi
    done

    dmz_if="$(echo "$remote_out" | sed -n '/---DMZIF---/,/---INTIF---/p' | grep -v '^---')"
    int_if="$(echo "$remote_out" | sed -n '/---INTIF---/,$p' | grep -v '^---')"
    if [ -n "$(echo "$dmz_if" | tr -d '[:space:]')" ]; then
        echo "!! 내장 dmz zone에 인터페이스(${dmz_if}) 붙어있음 — lb1과 같은 zone 충돌 재발 의심"
        WARN_COUNT=$((WARN_COUNT+1))
    fi
    if [ -n "$(echo "$int_if" | tr -d '[:space:]')" ]; then
        echo "!! 내장 internal zone에 인터페이스(${int_if}) 붙어있음 — lb1과 같은 zone 충돌 재발 의심"
        WARN_COUNT=$((WARN_COUNT+1))
    fi

    echo ""
done

echo "===================================================================="
echo " 2) firewalld 비활성 대상 VM (cp1~3 / worker1~3, §7 결정)"
echo "===================================================================="
for vm in "${FW_DISABLED_VMS[@]}"; do
    ip_addr="${MGMT_IP[$vm]}"
    state="$(sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@${ip_addr}" "systemctl is-active firewalld 2>/dev/null")"
    if [ -z "$state" ]; then
        echo "!! ${vm} SSH 접속 실패 — 스킵"
        WARN_COUNT=$((WARN_COUNT+1))
    elif [ "$state" == "inactive" ] || [ "$state" == "unknown" ]; then
        echo "OK   ${vm}: firewalld 비활성 (${state}) — §7 결정대로 정상"
    else
        echo "!! ${vm}: firewalld 상태 '${state}' — §7 결정(비활성화)과 다름, 확인 필요"
        WARN_COUNT=$((WARN_COUNT+1))
    fi
done
echo ""

echo "===================================================================="
echo " 3) Infra — outside-to-jenkins 정책 rich-rule 옛 IP 자동 정정"
echo "===================================================================="
rules="$(firewall-cmd --policy=outside-to-jenkins --list-rich-rules 2>&1)"
if echo "$rules" | grep -q "NO_POLICY\|not exist\|No such"; then
    echo "!! outside-to-jenkins 정책 자체가 없음 — 아직 §6 규칙이 한 번도 적용 안 된 상태일 수 있음. 직접 확인 필요"
    WARN_COUNT=$((WARN_COUNT+1))
elif echo "$rules" | grep -q "10.1.93.82"; then
    old_line="$(echo "$rules" | grep "10.1.93.82")"
    new_line="${old_line//10.1.93.82/10.1.93.4}"
    echo "!! 옛 IP(10.1.93.82) 발견 — 자동 정정 시도"
    echo "   제거: $old_line"
    echo "   추가: $new_line"
    firewall-cmd --permanent --policy=outside-to-jenkins --remove-rich-rule="$old_line"
    firewall-cmd --permanent --policy=outside-to-jenkins --add-rich-rule="$new_line"
    firewall-cmd --reload
    echo "OK   정정 완료 — 재확인:"
    firewall-cmd --policy=outside-to-jenkins --list-rich-rules
elif echo "$rules" | grep -q "10.1.93.4"; then
    echo "OK   이미 정정값(10.1.93.4)으로 적용되어 있음"
else
    echo "?? rich-rule 목록에서 10.1.93.82/10.1.93.4 둘 다 안 보임 — 아래 원본 출력 직접 확인"
    echo "$rules"
fi
echo ""

echo "===================================================================="
echo " 4) Infra — external zone 기본 서비스 / masquerade 상태"
echo "===================================================================="
echo "서비스: $(firewall-cmd --zone=external --list-services 2>&1)"
echo "masquerade: $(firewall-cmd --zone=external --query-masquerade 2>&1)"
echo ""

echo "===================================================================="
echo " 요약"
echo "===================================================================="
if [ "$WARN_COUNT" -eq 0 ]; then
    echo "전부 정상 — 경고 0건"
else
    echo "경고/확인 필요 ${WARN_COUNT}건 — 위 !! 표시 줄 참고"
fi
echo ""
echo ">>> 남은 수동 확인: 예린님께 §7 공지(CP/Worker firewalld 비활성화) 전달 여부는 스크립트로 못 봄 — 직접 확인 필요"
