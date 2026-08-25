# On-Premise Kubernetes 인프라 네트워크 자동화

VMware Workstation 기반 온프레미스 환경에 4-Zone 네트워크(Management/DMZ/Internal/Data)를 구성하고,
BIND DNS, HAProxy+Keepalived HA, firewalld 보안 정책을 자동화한 셸 스크립트 모음입니다.
4인 팀 프로젝트에서 **네트워크 담당**으로 설계·구현한 부분만 정리했습니다.

## 아키텍처 개요

- **VM 13대** / 4개 Zone (Management `192.168.14.0/24`, DMZ `192.168.24.0/24`, Internal `192.168.34.0/24`, Data `192.168.44.0/24`)
- **Kubernetes**: Control Plane 3중화(etcd), Worker 3대, Calico CNI
- **HA**: HAProxy + Keepalived로 K8s API VIP(`192.168.34.100:6443`)와 Service VIP(`192.168.24.100:443`) 이중화
- **DNS**: BIND9로 내부 도메인(`nplan.local`) 구성, K8s 클러스터 내부 도메인(`neuroplan.local`, NodeLocal DNS)과 분리 운영
- **보안**: firewalld로 Zone별 최소 권한 방화벽 정책 적용 (단, Calico가 도는 K8s 노드는 iptables 충돌 방지를 위해 의도적으로 firewalld 비활성화)

## 스크립트 구성

| 스크립트 | 실행 대상 | 역할 |
|---|---|---|
| `bind_dns_setup.sh` | Infra VM | BIND9 설치, 내부 zone(`nplan.local`) 생성, 13대 VM 이름 해석 + 외부 도메인 forwarding, firewalld 53포트 오픈까지 원샷 구성 |
| `bind_add_service_vip_record.sh` | Infra VM | 운영 중인 zone 파일에 A 레코드 추가(멱등) — serial 자동 증가, 문법 검사·reload까지 포함 |
| `firewalld_setup.sh` | VM 13대 전체 | hostname 기반으로 자기 Zone NIC을 자동 탐지해 커스텀 zone(`nw-mgmt`/`nw-dmz`/`nw-internal`/`nw-data`)에 바인딩, VM 역할별 최소 허용 규칙 적용. K8s 클러스터 노드는 조기 분기로 firewalld 자체를 비활성화 |
| `service_vip_setup.sh` | LB1/LB2 | 기존 API VIP(`k8s_api`) 설정은 절대 건드리지 않고 Service VIP용 `vrrp_instance`/`frontend`만 추가(멱등, 자동 백업, 서비스 재시작은 수동 확인 후 진행하도록 의도적으로 분리) |

모든 스크립트는 **멱등성(idempotent)**을 기본 원칙으로 작성했습니다 — 여러 번 실행해도 안전하고, 실행 전 자동 백업을 남깁니다.

## 설계 하이라이트

- **VRRP를 멀티캐스트 대신 unicast로 설계**: Bridged 네트워크가 실습 스위치를 통과하는 환경이라 멀티캐스트 도달을 보장할 수 없어, LB1↔LB2 간 unicast peer로 설계해 이 리스크 자체를 제거
- **Keepalived track_script는 HAProxy 프로세스 생존만 체크**: Control Plane backend 상태를 직접 체크하면 클러스터 생성 전 정상적인 DOWN 상태에서도 VRRP가 FAULT로 흔들리는 문제가 있어, 헬스체크 책임을 HAProxy backend health check와 분리
- **Calico-firewalld 충돌을 사전에 판단해 K8s 노드는 firewalld를 완전히 비활성화**: Calico 공식 문서 근거로 두 iptables 관리 주체가 충돌하는 문제를 회피하고, 물리 Zone 분리 + 격리망이라는 근거로 트레이드오프를 문서화
- **DNS 이원화 설계**: Kubernetes 내부 DNS(`neuroplan.local`, clusterDomain/NodeLocal DNS)와 인프라 DNS(`nplan.local`, BIND) 영역을 명확히 분리해, 두 시스템이 서로 forwarding으로만 연결되고 이름 충돌이 없도록 구성. 실제로 이 분리 원칙 덕분에 kubectl 접속 장애를 레코드 네이밍 문제 하나로 좁혀서 빠르게 원인 파악

## 사용법

```bash
# Infra VM
sudo ./bind_dns_setup.sh
sudo ./bind_add_service_vip_record.sh

# 13대 VM 전체 (hostname을 자동으로 읽음)
sudo ./firewalld_setup.sh

# LB1 / LB2
sudo ./service_vip_setup.sh
```

## 기술 스택

`VMware Workstation Pro` `CentOS Stream 9` `BIND9` `HAProxy` `Keepalived` `firewalld` `Kubernetes` `Calico` `Bash`
