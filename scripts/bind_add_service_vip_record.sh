#!/bin/bash
# =====================================================================
# 4조(뉴로플랜) BIND zone에 app.nplan.local A 레코드 추가 — Infra VM 전용
# 대응 문서: claude/Service_VIP_HAProxy_설정_0824.md, claude/BIND_DNS_설정.md
#
# 전제조건: claude/bind_dns_setup.sh가 먼저 실행되어 nplan.local zone이
# 이미 존재하는 상태여야 함.
#
# 사용법: Infra VM(192.168.14.62)에서 sudo ./bind_add_service_vip_record.sh
# =====================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root(sudo)로 실행해야 합니다." >&2
  exit 1
fi

DOMAIN="nplan.local"
ZONE_FILE="/var/named/${DOMAIN}.zone"
RECORD_NAME="app"
RECORD_IP="192.168.24.100"

if [[ ! -f "$ZONE_FILE" ]]; then
  echo "${ZONE_FILE}이 없습니다 — bind_dns_setup.sh가 먼저 실행돼 있어야 합니다." >&2
  exit 1
fi

if grep -qE "^${RECORD_NAME}[[:space:]]+IN[[:space:]]+A[[:space:]]+${RECORD_IP}" "$ZONE_FILE"; then
  echo ">>> ${RECORD_NAME}.${DOMAIN} A ${RECORD_IP} 레코드가 이미 있습니다 — 건너뜁니다(수정 없음)."
  exit 0
fi

TS="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo now)"
cp -a "$ZONE_FILE" "${ZONE_FILE}.bak.${TS}"
echo ">>> 백업 완료: ${ZONE_FILE}.bak.${TS}"

# serial 값 올리기 (bind_dns_setup.sh가 만든 형식: YYYYMMDDNN, 그대로 +1)
OLD_SERIAL="$(grep -oE '[0-9]{10}' "$ZONE_FILE" | head -1)"
NEW_SERIAL=$((OLD_SERIAL + 1))
sed -i "0,/${OLD_SERIAL}/s//${NEW_SERIAL}/" "$ZONE_FILE"
echo ">>> serial ${OLD_SERIAL} → ${NEW_SERIAL}"

cat >> "$ZONE_FILE" <<EOF
${RECORD_NAME}     IN  A     ${RECORD_IP}   ; Service VIP (DMZ, 2026-08-25 추가)
EOF

named-checkzone "$DOMAIN" "$ZONE_FILE"
systemctl reload named

cat <<MSG
>>> 완료. 검증:
    dig @192.168.14.62 app.${DOMAIN} +short   # ${RECORD_IP} 나와야 정상
MSG
