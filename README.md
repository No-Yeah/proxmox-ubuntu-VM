# pve_u26.04_install.sh

Proxmox VE 에서 Ubuntu 26.04 Cloud Image VM 을 생성하는 TUI 스크립트입니다.

`whiptail` 기반으로 동작합니다.

---

## 요구 사항

- Proxmox VE 8 이상 (`qm set --virtio0 ... import-from=` 문법 사용)
- root 권한
- 대화형 터미널 (SSH 또는 노드 콘솔)
- `whiptail`, `wget` — 없으면 스크립트가 자동으로 설치합니다

스토리지에 **Snippets** 콘텐츠가 활성화되어 있어야 합니다. 없으면 yaml 생성 단계에서 중단됩니다.

```
데이터센터 > 스토리지 > local > 편집 > 내용 > Snippets 체크
```

---

## 실행 방법

Proxmox 노드에 root 로 접속한 뒤 실행합니다.

```bash
wget https://raw.githubusercontent.com/<사용자명>/<저장소명>/main/pve_u26.04_install.sh
chmod +x pve_u26.04_install.sh
./pve_u26.04_install.sh
```

git 으로 받아도 됩니다.

```bash
git clone https://github.com/<사용자명>/<저장소명>.git
cd <저장소명>
./pve_u26.04_install.sh
```

> Proxmox 웹 콘솔(noVNC / xterm.js)에서도 정상 동작합니다.

---

## 진행 단계

화면 안내를 따라가면 됩니다. 각 단계에서 `취소하고 종료` 또는 `ESC` 로 빠져나올 수 있습니다.

| 단계 | 내용 |
|---|---|
| 1 | VMID, CPU Type, Cores, Memory, IP/Subnet, Gateway, Bridge, Disk Size, Disk Area, Root Password 입력 후 재확인 |
| 2 | Cloud Image 를 내려받을 폴더 선택 |
| 3 | 이미지 다운로드 (레포1 → 레포2 → 직접 주소 입력 순으로 시도) |
| 4 | cloud-init yaml 을 snippets 폴더에 생성 |
| 5 | VM 생성 및 결과 표시 |

입력 확인 화면에서 `아니오` 를 고르면 이전 값이 기본값으로 채워진 채 입력 단계로 돌아갑니다.

---

## 생성되는 VM

| 항목 | 값 |
|---|---|
| 디스크 | `virtio0`, 지정한 크기로 확장 |
| 디스플레이 | `std` (시리얼 콘솔 미사용) |
| 네트워크 | `virtio`, cloud-init 으로 고정 IP 설정 |
| 게스트 에이전트 | 활성화 |
| 부팅 후 | `net-tools`, `qemu-guest-agent` 설치, root 비밀번호 로그인 허용 |

디스플레이를 시리얼이 아닌 `std` 로 두는 이유는, systemd 258 부터 콘솔에 출력되는 OSC 3008 제어 문자열이 `vt220` 터미널에서 그대로 글자로 표시되기 때문입니다.

---

## 설정 변경

이미지 URL 은 스크립트 상단 두 줄에서 바꿉니다.

```bash
REPO1_URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
REPO2_URL="https://ftp.kaist.ac.kr/ubuntu-cloud-images/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
```

---

## 로그

실행 경로에 다음 형식으로 남습니다. 사용자가 선택한 값과 에러 원문만 기록되며, 비밀번호는 기록하지 않습니다.

```
pve_u2604_install.log-YYYYmmdd-HH:MM:SS
```

---

## 주의

생성되는 cloud-init yaml 에는 root 비밀번호가 평문으로 들어갑니다. 파일 권한은 `600` 으로 설정되지만, cloud-init 특성상 게스트의 `/var/lib/cloud` 에도 남습니다. 운영 환경에서는 SSH 키 인증으로 전환하시기 바랍니다.
