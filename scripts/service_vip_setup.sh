#!/bin/bash
# =====================================================================
# 4조(뉴로플랜) Service VIP(192.168.24.100:443) 추가 스크립트 — LB1/LB2 전용
# 대응 문서: claude/Service_VIP_HAProxy_설정_0824.md
#
# ⚠️ 이 스크립트는 기존 API VIP(192.168.34.100:6443, vrrp_instance k8s_api /
# frontend k8s_api) 설정을 절대 건드리지 않습니다 — 윤준호님 요청(2026-08-24)
# 에 따라 keepalived.conf/haproxy.cfg에 새 블록만 "추가"하고 기존 블록은
# 원본 그대로 둡니다. 이미 실행해서 블록이 있으면 재실행해도 중복 추가하지
# 않습니다(idempotent, 마커 문자열로 판별).
#
# 사용법: LB1/LB2에서 sudo ./service_vip_setup.sh
#         (hostname이 lb1/lb2가 아니면 sudo VM_NAME=lb1 ./service_vip_setup.sh)
#
# 전제조건: keepalived_VIP_트러블슈팅_0821.md의 k8s_api 구성(vrrp_script
# check_haproxy 포함)이 이미 완료되어 있어야 함 — 이 스크립트는 그 track_script
# (check_haproxy)를 그대로 재사용하고 새로 정의하지 않음.
# =====================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root(sudo)로 실행해야 합니다." >&2
  exit 1
fi

VM_NAME="${VM_NAME:-$(hostname -s)}"
VM_NAME="$(echo "$VM_NAME" | tr '[:upper:]' '[:lower:]')"

case "$VM_NAME" in
  lb1) STATE="MASTER"; PRIORITY=110; SRC_IP=192.168.24.11; PEER_IP=192.168.24.12 ;;
  lb2) STATE="BACKUP"; PRIORITY=100; SRC_IP=192.168.24.12; PEER_IP=192.168.24.11 ;;
  *)
    echo "이 스크립트는 lb1/lb2 전용입니다. (VM_NAME=${VM_NAME})" >&2
    exit 1
    ;;
esac

echo ">>> VM_NAME=${VM_NAME}  state=${STATE}  priority=${PRIORITY}"

KEEPALIVED_CONF=/etc/keepalived/keepalived.conf
HAPROXY_CONF=/etc/haproxy/haproxy.cfg
MARKER="vrrp_instance service_vip"
HA_MARKER="frontend service_vip"

if [[ ! -f "$KEEPALIVED_CONF" ]] || [[ ! -f "$HAPROXY_CONF" ]]; then
  echo "keepalived.conf 또는 haproxy.cfg가 없습니다 — k8s_api(API VIP) 구성이 먼저 끝나 있어야 합니다." >&2
  exit 1
fi

if ! grep -q "vrrp_instance k8s_api" "$KEEPALIVED_CONF"; then
  echo "⚠️  keepalived.conf에 vrrp_instance k8s_api 블록이 안 보입니다 — API VIP 구성부터 확인하세요." >&2
  exit 1
fi

# DMZ NIC 자동 탐지 (192.168.24.x 대역) — firewalld_setup.sh의 find_iface와 동일한 방식
DMZ_IF="$(ip -4 -o addr show 2>/dev/null | awk '$4 ~ /^192\.168\.24\./ {print $2; exit}')"
if [[ -z "$DMZ_IF" ]]; then
  echo "DMZ NIC(192.168.24.x)을 찾지 못했습니다 — 인터페이스가 아직 안 붙어있는지 확인하세요." >&2
  exit 1
fi
echo ">>> DMZ NIC=${DMZ_IF}"

# ---------------------------------------------------------------------
# 1. 백업 (keepalived_VIP_트러블슈팅_0821.md의 안전장치 절차 그대로 재사용)
# ---------------------------------------------------------------------
TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
cp -a "$KEEPALIVED_CONF" "${KEEPALIVED_CONF}.bak.${TS}"
cp -a "$HAPROXY_CONF" "${HAPROXY_CONF}.bak.${TS}"
echo ">>> 백업 완료: ${KEEPALIVED_CONF}.bak.${TS}, ${HAPROXY_CONF}.bak.${TS}"

# ---------------------------------------------------------------------
# 2. keepalived.conf — vrrp_instance service_vip 추가 (기존 k8s_api 블록 무변경)
#    virtual_router_id는 24(DMZ Zone 옥텟, 니모닉) — k8s_api의 34와 절대 안 겹침
# ---------------------------------------------------------------------
if grep -q "$MARKER" "$KEEPALIVED_CONF"; then
  echo ">>> keepalived.conf에 service_vip 블록이 이미 있습니다 — 건너뜁니다(수정 없음)."
else
  cat >> "$KEEPALIVED_CONF" <<EOF

vrrp_instance service_vip {
    state ${STATE}
    interface ${DMZ_IF}
    virtual_router_id 24
    priority ${PRIORITY}
    advert_int 1
    unicast_src_ip ${SRC_IP}
    unicast_peer {
        ${PEER_IP}
    }
    virtual_ipaddress {
        192.168.24.100/24 dev ${DMZ_IF}
    }
    track_script {
        check_haproxy
    }
}
EOF
  echo ">>> keepalived.conf에 vrrp_instance service_vip 추가 완료 (기존 k8s_api 블록은 그대로)."
fi

# ---------------------------------------------------------------------
# 3. haproxy.cfg — frontend/backend 추가 (기존 frontend k8s_api 블록 무변경)
#    send-proxy 미사용, TLS passthrough(mode tcp) — 요청받은 값 그대로
# ---------------------------------------------------------------------
if grep -q "$HA_MARKER" "$HAPROXY_CONF"; then
  echo ">>> haproxy.cfg에 service_vip frontend가 이미 있습니다 — 건너뜁니다(수정 없음)."
else
  cat >> "$HAPROXY_CONF" <<EOF

frontend service_vip
    bind 192.168.24.100:443
    mode tcp
    default_backend app_workers

backend app_workers
    mode tcp
    balance roundrobin
    option tcp-check
    server worker1 192.168.34.41:30443 check
    server worker2 192.168.34.42:30443 check
    server worker3 192.168.34.43:30443 check
EOF
  echo ">>> haproxy.cfg에 frontend service_vip / backend app_workers 추가 완료 (기존 frontend k8s_api는 그대로)."
fi

# ---------------------------------------------------------------------
# 4. 마크다운/메일 복붙 과정에서 생기는 백슬래시 이스케이프 오염 확인
# ---------------------------------------------------------------------
if grep -n '\\_' "$KEEPALIVED_CONF" "$HAPROXY_CONF" 2>/dev/null | grep -v '\.bak\.'; then
  echo "⚠️  백슬래시 이스케이프 오염 의심 라인 발견 — 위 출력 확인 후 직접 수정하세요." >&2
fi

# ---------------------------------------------------------------------
# 5. 문법 검사만 수행 — 서비스 재시작은 자동으로 하지 않음
#    (API VIP에 영향 없는지 LB1에서 먼저 눈으로 확인 후 수동으로 반영할 것)
# ---------------------------------------------------------------------
echo ">>> 문법 검사"
haproxy -c -f "$HAPROXY_CONF"
keepalived -t -f "$KEEPALIVED_CONF"

cat <<MSG
>>> 문법 검사 통과. 서비스 반영은 아래를 LB1 먼저 실행 → VIP 확인 → LB2 순서로 진행하세요.
    (재시작은 API VIP(k8s_api)에도 영향을 줄 수 있으니 반드시 한쪽씩)

    systemctl restart haproxy
    systemctl restart keepalived
    ip -4 addr show dev ${DMZ_IF} | grep 192.168.24.100   # LB1에만 있어야 정상
    ss -lntp | grep ':443'
    # k8s_api(API VIP)가 그대로 살아있는지도 같이 확인:
    ip -4 addr show | grep 192.168.34.100
    ss -lntp | grep ':6443'
MSG
