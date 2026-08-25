#!/bin/bash
# =====================================================================
# 4조(뉴로플랜) firewalld 1차 적용 스크립트
# 기준 문서: claude/방화벽_정책_1차_정리.md (§4 VM별 인바운드 허용 규칙, §7 Calico-firewalld 충돌 공지)
#
# 사용법: (팀 명명 규칙 — hostname은 서버이름 소문자, 예: LB1 → lb1)
#   1) 이 스크립트를 13대 VM 전부에 그대로 복사
#   2) 그냥 sudo ./firewalld_setup.sh 실행 — hostname(-s)을 자동으로 읽음
#      (hostname이 아직 규칙대로 안 되어 있으면 sudo VM_NAME=cp1 ./firewalld_setup.sh 처럼 지정)
#
# 지원하는 hostname / VM_NAME 값 (대소문자 무관하게 소문자로 변환해서 비교):
#   lb1 lb2 cp1 cp2 cp3 worker1 worker2 worker3 devops
#   db-primary db-replica nfs infra
#
# ⚠️ 2026-08-24 공지 반영: cp1/cp2/cp3/worker1/worker2/worker3(K8s 클러스터
# 멤버, kubelet+Calico가 도는 노드)는 더 이상 firewalld 규칙을 적용하지
# 않고 firewalld 자체를 완전히 비활성화합니다. Calico 공식 문서가 "호스트에
# firewalld 등 iptables 매니저가 있으면 비활성화해야 한다"고 명시하고
# 있고(Calico가 자체 iptables 규칙을 심는데 firewalld와 관리 주체가 겹치면
# 충돌해서 Pod 통신/DNS/NetworkPolicy가 깨짐), 아래 5절의 VM별 상세 규칙은
# 이 6대 한정으로는 더 이상 쓰이지 않습니다(비-K8s 노드 7대는 그대로 적용).
# 근거/트레이드오프는 방화벽_정책_1차_정리.md §7 참고.
#
# 이 스크립트는 "이 VM이 실제로 어떤 Zone NIC을 갖고 있는지"를
# IP 대역(192.168.14/24/34/44.0/24)으로 자동 탐지해서 해당 인터페이스만
# firewalld 커스텀 zone(nw-mgmt/nw-dmz/nw-internal/nw-data)에 묶습니다.
# NIC이 아직 안 붙어있는 Zone은 자동으로 건너뜁니다.
#
# ⚠️ zone 이름을 nw- 접두어로 지은 이유: firewalld는 dmz/internal/trusted/home
# 등을 이미 내장 zone으로 갖고 있고 각자 기본 서비스(ssh, samba-client 등)가
# 미리 들어있음. 예전 버전에서 zone 이름을 mgmt/dmz/internal/data로 그대로
# 썼다가 dmz·internal이 내장 zone과 겹쳐서 원치 않는 서비스가 같이 열리는
# 문제가 있었음(2026-08-21 lb1에서 발견). nw- 접두어를 붙이면 내장 zone과
# 절대 겹치지 않음.
# =====================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "root(sudo)로 실행해야 합니다." >&2
  exit 1
fi

VM_NAME="${VM_NAME:-$(hostname -s)}"
VM_NAME="$(echo "$VM_NAME" | tr '[:upper:]' '[:lower:]')"
echo ">>> VM_NAME = ${VM_NAME}"

# ---------------------------------------------------------------------
# -1. K8s 클러스터 노드는 firewalld 자체를 끄고 즉시 종료 (2026-08-24 공지)
#     Calico가 노드에 직접 iptables 규칙을 심는데 firewalld와 충돌하므로,
#     zone/규칙을 만들지 않고 여기서 바로 비활성화 후 스크립트를 마칩니다.
#     기존에 이 VM에 규칙을 걸어둔 적이 있어도(cp1/worker1 등) 상관없이
#     firewalld 서비스 자체를 끄면 그 규칙도 같이 무효화됩니다.
# ---------------------------------------------------------------------
case "$VM_NAME" in
  cp1|cp2|cp3|worker1|worker2|worker3)
    echo ">>> ${VM_NAME}은 K8s 클러스터 노드(Calico) — firewalld 규칙 적용 대신 완전 비활성화합니다."
    echo "    근거: Calico 공식 문서 — firewalld 등 iptables 매니저는 비활성화 권장(방화벽_정책_1차_정리.md §7 참고)"
    systemctl disable --now firewalld
    echo ">>> ${VM_NAME} firewalld 비활성화 완료. 규칙은 적용하지 않았습니다(정상 동작)."
    exit 0
    ;;
esac

# ---------------------------------------------------------------------
# 0. firewalld 기동 (여기부터는 비-K8s 노드 7대: lb1 lb2 devops
#    db-primary db-replica nfs infra)
# ---------------------------------------------------------------------
systemctl enable --now firewalld

# ---------------------------------------------------------------------
# 1. Zone별 물리 인터페이스 자동 탐지 (3번째 옥텟 기준)
#    Management=14 / DMZ=24 / Internal=34 / Data=44
# ---------------------------------------------------------------------
find_iface() {
  local octet="$1"
  local pat="192.168.${octet}."
  ip -4 -o addr show 2>/dev/null | awk -v pat="$pat" 'index($4, pat) == 1 {print $2; exit}'
}

MGMT_IF="$(find_iface 14 || true)"
DMZ_IF="$(find_iface 24 || true)"
INT_IF="$(find_iface 34 || true)"
DATA_IF="$(find_iface 44 || true)"

echo "    Mgmt NIC=${MGMT_IF:-없음}  DMZ NIC=${DMZ_IF:-없음}  Internal NIC=${INT_IF:-없음}  Data NIC=${DATA_IF:-없음}"

# ---------------------------------------------------------------------
# 2. 커스텀 zone 생성(없으면) + 인터페이스 바인딩 + 기본 거부(DROP)
# ---------------------------------------------------------------------
ensure_zone() {
  local zone="$1"
  if ! firewall-cmd --permanent --get-zones | grep -qw "$zone"; then
    firewall-cmd --permanent --new-zone="$zone"
  fi
  firewall-cmd --permanent --zone="$zone" --set-target=DROP
}

bind_zone() {
  local zone="$1" iface="$2"
  [[ -z "$iface" ]] && return 0
  ensure_zone "$zone"
  firewall-cmd --permanent --zone="$zone" --change-interface="$iface"
}

bind_zone nw-mgmt     "$MGMT_IF"
bind_zone nw-dmz      "$DMZ_IF"
bind_zone nw-internal "$INT_IF"
bind_zone nw-data     "$DATA_IF"

MGMT_NET="192.168.14.0/24"
DMZ_NET="192.168.24.0/24"
INT_NET="192.168.34.0/24"
DATA_NET="192.168.44.0/24"

# ---------------------------------------------------------------------
# 2-1. 같은 zone 대역에서 오는 ping(ICMP echo-request) 허용
#      target=DROP이면 ICMP도 기본 차단되어 내부-내부 ping이 안 됨.
#      각 zone에 "자기 zone 대역에서 오는 ping"만 허용 (2026-08-21 cp1에서 발견)
#      ※ 이 7대(lb1 lb2 devops db-primary db-replica nfs infra) 기준.
#        K8s 노드 6대는 위에서 이미 종료되어 여기 도달하지 않음.
# ---------------------------------------------------------------------
allow_ping() {
  local zone="$1" net="$2"
  firewall-cmd --permanent --zone="$zone" \
    --add-rich-rule="rule family=\"ipv4\" source address=\"${net}\" icmp-type name=\"echo-request\" accept"
}

[[ -n "$MGMT_IF" ]] && allow_ping nw-mgmt     "$MGMT_NET"
[[ -n "$DMZ_IF"  ]] && allow_ping nw-dmz      "$DMZ_NET"
[[ -n "$INT_IF"  ]] && allow_ping nw-internal "$INT_NET"
[[ -n "$DATA_IF" ]] && allow_ping nw-data     "$DATA_NET"

# ---------------------------------------------------------------------
# 2-2. (참고용, 실질적으로 더 이상 쓰이지 않음 — 2026-08-24)
#      원래는 Calico Pod CIDR(10.244.0.0/16)이 direct routing될 때 대비해
#      Internal zone에서 전부 허용해두려던 규칙이었으나, Internal NIC을
#      가진 VM은 CP1~3/Worker1~3/LB1~2뿐이고 CP/Worker는 이제 firewalld가
#      아예 꺼지므로 이 규칙이 실제로 붙는 대상은 LB1~2뿐(K8s 노드가
#      아니라 Pod CIDR 트래픽과 무관). 그대로 남겨둬도 무해해서 유지.
# ---------------------------------------------------------------------
POD_CIDR="10.244.0.0/16"
if [[ -n "$INT_IF" ]]; then
  firewall-cmd --permanent --zone=nw-internal \
    --add-rich-rule="rule family=\"ipv4\" source address=\"${POD_CIDR}\" accept"
fi

# ---------------------------------------------------------------------
# 3. 규칙 추가 헬퍼
# ---------------------------------------------------------------------
allow() {
  # allow <zone> <proto> <port> <source_cidr_or_ip>
  local zone="$1" proto="$2" port="$3" src="$4"
  firewall-cmd --permanent --zone="$zone" \
    --add-rich-rule="rule family=\"ipv4\" source address=\"${src}\" port protocol=\"${proto}\" port=\"${port}\" accept"
}

allow_proto() {
  # allow_proto <zone> <protocol_name> <source_cidr_or_ip>   (예: vrrp)
  local zone="$1" proto="$2" src="$3"
  firewall-cmd --permanent --zone="$zone" \
    --add-rich-rule="rule family=\"ipv4\" source address=\"${src}\" protocol value=\"${proto}\" accept"
}

allow_open() {
  # 소스 제한 없이 여는 경우 (DMZ 공개 웹 포트용)
  local zone="$1" proto="$2" port="$3"
  firewall-cmd --permanent --zone="$zone" --add-port="${port}/${proto}"
}

DEVOPS=192.168.44.21
DBP_DATA=192.168.44.51; DBR_DATA=192.168.44.52
W1_DATA=192.168.44.41; W2_DATA=192.168.44.42; W3_DATA=192.168.44.43
W1_INT=192.168.34.41; W2_INT=192.168.34.42; W3_INT=192.168.34.43
LB1_INT=192.168.34.11; LB2_INT=192.168.34.12
INFRA_MGMT=192.168.14.62; INFRA_DATA=192.168.44.62

# ---------------------------------------------------------------------
# 4. VM별 규칙 (문서 §4 기준)
#    ⚠️ cp1/cp2/cp3/worker1/worker2/worker3 케이스는 위 -1단계에서 이미
#    종료되어 여기 도달하지 않습니다(firewalld 비활성화 처리됨, §7 참고).
#    아래는 나머지 7대(lb1 lb2 devops db-primary db-replica nfs infra)만
#    대상입니다.
# ---------------------------------------------------------------------
case "$VM_NAME" in

  db-primary)
    allow nw-data tcp 3306 "$DEVOPS"
    allow nw-data tcp 3306 "$DBR_DATA"
    allow nw-data tcp 9104 "$W1_DATA"; allow nw-data tcp 9104 "$W2_DATA"; allow nw-data tcp 9104 "$W3_DATA"
    allow nw-mgmt tcp 22   "$MGMT_NET"
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    ;;

  db-replica)
    allow nw-data tcp 3306 "$DEVOPS"
    allow nw-data tcp 3306 "$DBP_DATA"
    allow nw-data tcp 9104 "$W1_DATA"; allow nw-data tcp 9104 "$W2_DATA"; allow nw-data tcp 9104 "$W3_DATA"
    allow nw-mgmt tcp 22   "$MGMT_NET"
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    ;;

  nfs)
    allow nw-data tcp 2049 "$DATA_NET"          # §3-2 통합 규칙 (DB덤프+etcd스냅샷+설정백업)
    allow nw-mgmt tcp 22   "$MGMT_NET"
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    ;;

  devops)
    allow nw-data tcp 4006 "$W1_DATA"; allow nw-data tcp 4006 "$W2_DATA"; allow nw-data tcp 4006 "$W3_DATA"
    allow nw-mgmt tcp 22   "$MGMT_NET"
    allow nw-mgmt tcp 8080 "$MGMT_NET"          # Jenkins, §3-6
    allow nw-mgmt tcp 8989 "$MGMT_NET"          # MaxScale 관리, §3-6
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    # DevOps는 Internal도 갖고 있음(Ansible/Jenkins → K8s API 접근은 아웃바운드라 별도 inbound 불필요)
    ;;

  infra)
    allow nw-data udp 123 "$DBP_DATA"; allow nw-data udp 123 "$DBR_DATA"; allow nw-data udp 123 192.168.44.61  # chrony(Data 경로), §1
    allow nw-mgmt udp 53  "$MGMT_NET"           # DNS, §3-5
    allow nw-mgmt tcp 53  "$MGMT_NET"           # DNS
    allow nw-mgmt udp 123 "$MGMT_NET"           # chrony(Mgmt 경로, 전체 VM용), §3-5-부가
    allow nw-mgmt tcp 22  "$MGMT_NET"
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    # Infra는 Outside NIC(인터넷 게이트웨이)도 있으나 이 스크립트는 Zone NIC만 다룸 — NAT/forwarding은 별도 설정
    ;;

  lb1|lb2)
    allow nw-mgmt tcp 22   "$MGMT_NET"
    allow nw-mgmt tcp 9100 "$MGMT_NET"
    allow_open nw-dmz tcp 80
    allow_open nw-dmz tcp 443
    allow nw-internal tcp 6443 "$INT_NET"        # K8s API VIP를 LB가 호스팅
    # lb1<->lb2 VRRP (protocol 112), DMZ·Internal 양쪽 다
    if [[ "$VM_NAME" == "lb1" ]]; then PEER_DMZ=192.168.24.12; PEER_INT=$LB2_INT; else PEER_DMZ=192.168.24.11; PEER_INT=$LB1_INT; fi
    allow_proto nw-dmz vrrp "$PEER_DMZ"
    allow_proto nw-internal vrrp "$PEER_INT"
    ;;

  *)
    echo "알 수 없는 VM_NAME: ${VM_NAME}" >&2
    echo "지원 목록: lb1 lb2 cp1 cp2 cp3 worker1 worker2 worker3 devops db-primary db-replica nfs infra" >&2
    echo "(cp1/cp2/cp3/worker1/worker2/worker3는 위 -1단계에서 이미 처리되어 여기로 오지 않습니다)" >&2
    exit 1
    ;;
esac

# ---------------------------------------------------------------------
# 5. 적용
# ---------------------------------------------------------------------
firewall-cmd --reload

echo ">>> ${VM_NAME} firewalld 설정 완료. 아래로 확인:"
echo "    firewall-cmd --get-active-zones"
echo "    firewall-cmd --zone=<zone> --list-all"
