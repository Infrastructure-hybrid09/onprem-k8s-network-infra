#!/bin/bash
# =====================================================================
# 4조(뉴로플랜) BIND DNS 설정 스크립트 (Infra VM 전용, 192.168.14.62)
# 대응 문서: claude/BIND_DNS_설정.md
# 원래 계획상 Week 2(09/03~) 작업이었으나, Week 1 선수작업(NAT/게이트웨이)이
# 먼저 끝나서 앞당겨 진행함 (2026-08-21).
#
# 역할: 13대 VM 이름 해석(내부 zone) + 외부 도메인(mirrors.centos.org 등)
#      forwarder 역할 겸용. Infra가 이미 인터넷 게이트웨이(NAT)이기도 하므로
#      "인터넷 나가는 길"과 "이름 해석"이 같은 VM에 모이는 구조 — 의도된 설계.
#
# 사용법: Infra VM에서 sudo ./bind_dns_setup.sh
# =====================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root(sudo)로 실행해야 합니다." >&2
  exit 1
fi

MGMT_IP="192.168.14.62"
DOMAIN="nplan.local"

echo ">>> bind 설치"
dnf install -y bind bind-utils

echo ">>> /etc/named.conf 작성"
cat > /etc/named.conf <<EOF
options {
    listen-on port 53 { 127.0.0.1; ${MGMT_IP}; };
    listen-on-v6 port 53 { none; };
    directory       "/var/named";
    allow-query     { localhost; 192.168.14.0/24; };
    recursion yes;
    forwarders      { 8.8.8.8; 1.1.1.1; };
    forward first;
    dnssec-validation yes;
};

logging {
    channel default_debug {
        file "data/named.run";
        severity dynamic;
    };
};

zone "${DOMAIN}" IN {
    type master;
    file "${DOMAIN}.zone";
    allow-update { none; };
};
EOF

echo ">>> zone 파일 작성 (/var/named/${DOMAIN}.zone)"
cat > "/var/named/${DOMAIN}.zone" <<EOF
\$TTL 86400
@   IN  SOA   infra.${DOMAIN}. admin.${DOMAIN}. (
        2026082101 ; serial (YYYYMMDDNN, 수정할 때마다 올릴 것)
        3600       ; refresh
        1800       ; retry
        604800     ; expire
        86400 )    ; minimum
    IN  NS    infra.${DOMAIN}.

; ---- Infra ----
infra        IN A 192.168.14.62

; ---- LB (HAProxy+Keepalived) ----
lb1          IN A 192.168.14.11
lb2          IN A 192.168.14.12

; ---- Control Plane ----
cp1          IN A 192.168.14.31
cp2          IN A 192.168.14.32
cp3          IN A 192.168.14.33

; ---- Worker ----
worker1      IN A 192.168.14.41
worker2      IN A 192.168.14.42
worker3      IN A 192.168.14.43

; ---- DevOps ----
devops       IN A 192.168.14.21

; ---- DB / NFS ----
db-primary   IN A 192.168.14.51
db-replica   IN A 192.168.14.52
nfs          IN A 192.168.14.61

; ---- VIP (참고용 — Mgmt 대역 아님, 실제는 DMZ/Internal에 있음) ----
service-vip  IN A 192.168.24.100
k8s-api      IN A 192.168.34.100
EOF

chown root:named "/var/named/${DOMAIN}.zone"
chmod 640 "/var/named/${DOMAIN}.zone"
restorecon -Rv /var/named >/dev/null 2>&1 || true

echo ">>> 문법 검증"
named-checkconf /etc/named.conf
named-checkzone "${DOMAIN}" "/var/named/${DOMAIN}.zone"

echo ">>> firewalld 53/tcp+udp 오픈 (Mgmt NIC이 현재 속한 zone 기준)"
MGMT_IFACE="$(ip -4 -o addr show 2>/dev/null | awk -v ip="$MGMT_IP" 'index($4, ip)==1{print $2; exit}')"
ACTIVE_ZONE="$(firewall-cmd --get-zone-of-interface="$MGMT_IFACE" 2>/dev/null || true)"
ACTIVE_ZONE="${ACTIVE_ZONE:-public}"
echo "    Mgmt NIC=${MGMT_IFACE:-확인불가}  zone=${ACTIVE_ZONE}"
firewall-cmd --zone="$ACTIVE_ZONE" --add-port=53/tcp --permanent
firewall-cmd --zone="$ACTIVE_ZONE" --add-port=53/udp --permanent
firewall-cmd --reload

echo ">>> named 기동"
systemctl enable --now named

echo ">>> 완료. 검증 명령:"
echo "  dig @${MGMT_IP} devops.${DOMAIN} +short        # 내부 이름"
echo "  dig @${MGMT_IP} mirrors.centos.org +short       # 외부 포워딩"
echo ""
echo ">>> 참고: 이 스크립트는 claude/firewalld_setup.sh 의 infra 케이스가"
echo "    이미 포함하고 있는 53/tcp,udp 규칙과 겹쳐도 문제 없음(멱등)."
echo "    나머지 VM 쪽 DNS 클라이언트 설정은 claude/BIND_DNS_설정.md 참고."
