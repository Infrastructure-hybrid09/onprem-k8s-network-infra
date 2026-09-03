#!/bin/bash
# =====================================================================
# 4조(뉴로플랜) HAProxy DR K3s Failover 연동 스크립트 — LB1/LB2 전용
# 대응 문서: claude/HAProxy_DR_Failover_연동_0902.md
# 요청자: 김예린 (2026-09-02) — DR K3s(192.168.34.71:30443) 애플리케이션
#         검증 완료, Main Worker 전원 장애 시에만 DR로 넘어가는 backup
#         backend로 붙여달라는 요청.
#
# ⚠️ 이 스크립트는 기존 vrrp_instance / frontend 블록을 절대 건드리지
# 않습니다 — Keepalived·VIP 구조(LB1/LB2 이중화)는 이번 작업 범위 밖입니다.
# 기존 backend(Main Worker1~3가 등록된 블록, 운영 중 실제 이름은
# ngf_https_backend — Service_VIP_HAProxy_설정_0824.md 2026-09-01 참고)의
# "server worker..." 줄들 뒤에 dr-k3s 한 줄만 "check backup"으로 추가합니다.
# 이미 추가돼 있으면 재실행해도 중복 추가하지 않습니다(idempotent).
#
# ⚠️ 가장 중요한 포인트: 반드시 줄 끝에 "check backup"이 붙어야 합니다.
#    그냥 4번째 server로 넣으면(= backup 없이) 정상 상태에서도 DR로
#    트래픽이 분산돼 버려 원하는 구조가 아니게 됩니다.
#
# 사용법: LB1/LB2에서 sudo ./haproxy_dr_failover_setup.sh
# =====================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root(sudo)로 실행해야 합니다." >&2
  exit 1
fi

HAPROXY_CONF=/etc/haproxy/haproxy.cfg
DR_IP=192.168.34.71
DR_PORT=30443
DR_SERVER_LINE="    server dr-k3s ${DR_IP}:${DR_PORT} check backup"

if [[ ! -f "$HAPROXY_CONF" ]]; then
  echo "haproxy.cfg가 없습니다 — Service VIP(app_workers/ngf_https_backend) 구성이 먼저 끝나 있어야 합니다." >&2
  exit 1
fi

if ! grep -Eq '^[[:space:]]*server[[:space:]]+worker[0-9]+[[:space:]]' "$HAPROXY_CONF"; then
  echo "haproxy.cfg에서 'server worker...' 줄을 찾지 못했습니다 — Main backend가 아직 없는 것 같습니다. 먼저 확인하세요." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 0. (참고용) DR K3s 연결성 사전 확인 — 실패해도 스크립트를 막지는 않음
#    (LB1/LB2는 Internal NIC으로 192.168.34.0/24에 있고, dr-k3s도 같은
#    대역(.34.71)이라 방화벽 규칙 없이도 도달 가능해야 정상 — 방화벽_정책_1차_정리.md §11 참고)
# ---------------------------------------------------------------------
if command -v nc >/dev/null 2>&1; then
  echo ">>> DR K3s 연결성 사전 확인: nc -zv ${DR_IP} ${DR_PORT}"
  if nc -zv -w 3 "${DR_IP}" "${DR_PORT}" 2>&1; then
    echo ">>> DR K3s(${DR_IP}:${DR_PORT}) 연결 확인됨."
  else
    echo "⚠️  DR K3s(${DR_IP}:${DR_PORT})에 연결이 안 됩니다 — 계속 진행은 하되, 반영 전에 원인을 먼저 확인하세요." >&2
  fi
else
  echo "⚠️  nc 명령이 없어 사전 연결성 확인을 건너뜁니다 — 수동으로 'nc -zv ${DR_IP} ${DR_PORT}' 확인 권장." >&2
fi

# ---------------------------------------------------------------------
# 1. 백업
# ---------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
cp -a "$HAPROXY_CONF" "${HAPROXY_CONF}.bak.${TS}"
echo ">>> 백업 완료: ${HAPROXY_CONF}.bak.${TS}"

# ---------------------------------------------------------------------
# 2. dr-k3s server 줄 추가 (idempotent) — 마지막 "server worker..." 줄
#    바로 뒤에 삽입. 기존 frontend/vrrp_instance 블록은 전혀 건드리지 않음.
# ---------------------------------------------------------------------
if grep -q 'server[[:space:]]\+dr-k3s[[:space:]]' "$HAPROXY_CONF"; then
  echo ">>> haproxy.cfg에 'server dr-k3s' 줄이 이미 있습니다 — 건너뜁니다(수정 없음)."
  echo ">>> 현재 줄:"
  grep -n 'server[[:space:]]\+dr-k3s[[:space:]]' "$HAPROXY_CONF"
else
  awk -v newline="$DR_SERVER_LINE" '
    { lines[NR] = $0 }
    /^[[:space:]]*server[[:space:]]+worker[0-9]+[[:space:]]/ { last_worker = NR }
    END {
      for (i = 1; i <= NR; i++) {
        print lines[i]
        if (i == last_worker) print newline
      }
    }
  ' "$HAPROXY_CONF" > "${HAPROXY_CONF}.new"
  mv "${HAPROXY_CONF}.new" "$HAPROXY_CONF"
  echo ">>> haproxy.cfg에 dr-k3s backup server 추가 완료:"
  grep -n -B1 'server[[:space:]]\+dr-k3s[[:space:]]' "$HAPROXY_CONF"
fi

# ---------------------------------------------------------------------
# 3. 반드시 "check backup"이 붙어 있는지 최종 확인 (가장 중요한 포인트)
# ---------------------------------------------------------------------
if grep -Eq 'server[[:space:]]+dr-k3s[[:space:]]+[0-9.]+:[0-9]+[[:space:]]+check[[:space:]]+backup' "$HAPROXY_CONF"; then
  echo ">>> ✅ dr-k3s 줄에 'check backup'이 정확히 붙어 있는 것 확인 — 정상 상태에서는 DR로 트래픽이 분산되지 않습니다."
else
  echo "❌ dr-k3s 줄에 'check backup'이 없습니다! 이대로 반영하면 정상 상태에서도 DR로 트래픽이 나갈 수 있습니다 — 반드시 수정 후 재확인하세요." >&2
  exit 1
fi

# ---------------------------------------------------------------------
# 4. 문법 검사만 수행 — 서비스 재시작은 자동으로 하지 않음
#    (Keepalived/VIP 구조는 이번 작업과 무관하므로 keepalived.conf는 건드리지 않음)
# ---------------------------------------------------------------------
echo ">>> 문법 검사"
haproxy -c -f "$HAPROXY_CONF"

cat <<MSG
>>> 문법 검사 통과. 서비스 반영은 LB1 먼저 → 상태 확인 → LB2 순서로 진행하세요.
    (keepalived는 이번 작업과 무관하므로 재시작 불필요 — haproxy만 reload)

    systemctl reload haproxy
    echo "show servers state" | socat stdio /var/run/haproxy/admin.sock 2>/dev/null | grep dr-k3s || true
    # 또는:
    systemctl status haproxy

    # Main이 정상일 때 dr-k3s는 다음처럼 보여야 합니다(예시, 실제 명령은 운영 방식에 따라 다를 수 있음):
    #   dr-k3s ... 상태: no check (backup, 정상 상태에서는 헬스체크만 되고 트래픽은 안 감) 또는 UP(backup)
MSG
