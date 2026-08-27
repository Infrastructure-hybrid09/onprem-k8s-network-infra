#!/usr/bin/env bash
# ip_addr_check_from_infra.sh
#
# Infra VM(192.168.14.62)에서 실행 — 13대 VM(Infra 자신 포함) 전부에서
# ip -br addr을 뽑아 한 화면에 모아줌. 1차_IP_주소설계_전체표.md의
# Layer 2 IP 설계표와 대조하는 용도.
#
# 전제:
#   - 13대 VM 전부 root 비밀번호 = centos
#   - Management(192.168.14.0/24) 대역에서 22/tcp 허용됨
#     (firewalld_setup.sh 기준: 6개 K8s 노드는 firewalld 자체가 꺼져 있어 통과,
#      나머지 7대는 nw-mgmt zone에서 Mgmt 대역 22/tcp 허용)
#
# 사용법 (Infra VM에서 root로, script_net/ 안에서 실행):
#   chmod +x ip_addr_check_from_infra.sh
#   ./ip_addr_check_from_infra.sh
#   -> 화면 출력 + script_net/logs/ip_addr_result_YYYYMMDD_HHMM.log 로 자동 저장(tee 안 붙여도 됨)

set -uo pipefail

# 스크립트가 있는 위치(script_net/) 기준으로 logs/ 폴더 자동 생성 후,
# 화면 출력과 동시에 그 안에 타임스탬프 로그 파일로 남김.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="${LOG_DIR}/ip_addr_result_$(date +%Y%m%d_%H%M).log"
exec > >(tee "$LOG_FILE") 2>&1
echo ">>> 로그 저장 위치: $LOG_FILE"
echo ""

SSH_PASS="centos"
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5 -o LogLevel=ERROR"

# sshpass 없으면 설치 시도 (CentOS Stream 9 / dnf, EPEL 필요할 수 있음)
if ! command -v sshpass >/dev/null 2>&1; then
    echo ">>> sshpass 미설치 — 설치 시도"
    dnf install -y epel-release >/dev/null 2>&1
    dnf install -y sshpass
    if ! command -v sshpass >/dev/null 2>&1; then
        echo "!! sshpass 설치 실패 — 수동 설치 후 다시 실행하세요 (dnf install sshpass)"
        exit 1
    fi
fi

# VM 이름 → Management IP (1차_IP_주소설계_전체표.md Layer 2 표 기준)
# Infra 자신은 로컬에서 바로 조회하므로 목록에서 제외.
VM_ORDER=(lb1 lb2 cp1 cp2 cp3 worker1 worker2 worker3 devops db-primary db-replica nfs)
declare -A VM_IP=(
  [lb1]="192.168.14.11"
  [lb2]="192.168.14.12"
  [cp1]="192.168.14.31"
  [cp2]="192.168.14.32"
  [cp3]="192.168.14.33"
  [worker1]="192.168.14.41"
  [worker2]="192.168.14.42"
  [worker3]="192.168.14.43"
  [devops]="192.168.14.21"
  [db-primary]="192.168.14.51"
  [db-replica]="192.168.14.52"
  [nfs]="192.168.14.61"
)

FAILED=()

echo "===== infra (local, 192.168.14.62) ====="
ip -br addr
echo ""

for vm in "${VM_ORDER[@]}"; do
    ip_addr="${VM_IP[$vm]}"
    echo "===== ${vm} (${ip_addr}) ====="
    if ! sshpass -p "$SSH_PASS" ssh $SSH_OPTS "root@${ip_addr}" "ip -br addr"; then
        echo "!! 접속 실패"
        FAILED+=("$vm")
    fi
    echo ""
done

echo "===== 완료 ====="
if [ "${#FAILED[@]}" -gt 0 ]; then
    echo "!! 접속 실패한 VM: ${FAILED[*]}"
    echo "   -> sshd 상태 / firewalld nw-mgmt 규칙 / 비밀번호(centos) 먼저 확인"
else
    echo "13대 전부 정상 응답"
fi
