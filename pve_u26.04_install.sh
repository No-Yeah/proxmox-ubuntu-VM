#!/usr/bin/env bash
#
# pve_u26.04_install.sh
# Proxmox VE 에서 Ubuntu 26.04 Cloud Image VM 을 생성하는 TUI 스크립트.
#
# 실행: bash pve_u26.04_install.sh   (Proxmox 노드에서 root 로)
#
set -uo pipefail

# ---------------------------------------------------------------- 설정값
REPO1_URL="https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
REPO2_URL="https://ftp.kaist.ac.kr/ubuntu-cloud-images/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"

BACKTITLE="Ubuntu 26.04 Cloud Image VM Installer"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/pve_u2604_install.log-$(date '+%Y%m%d-%H:%M:%S')"
TMP_ERR="$(mktemp)"
trap 'rm -f "$TMP_ERR"' EXIT

IMG_DIR="" IMG_PATH="" SNIP_STORE="" SNIP_DIR="" YAML_NAME=""
VMID="" CPUTYPE="host" CORES="2" MEMORY="2048" IPADDR="" SUBNETBIT="24"
GATEWAY="" BRIDGE="" DISKSIZE="32" DISKAREA="" ROOTPW=""

# ---------------------------------------------------------------- 로그
# 사용자의 선택 값과 에러 원문만 남긴다.
log() { printf '%s | %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"; }

# ---------------------------------------------------------------- TUI 래퍼
# whiptail 은 선택 결과를 stderr 로 내보내므로 3>&1 1>&2 2>&3 로 뒤집는다.

ui_msg() {   # title, text
    whiptail --backtitle "$BACKTITLE" --title "$1" --ok-button "확인" \
             --msgbox "$2" 16 72
}

ui_err() {   # title, text
    whiptail --backtitle "$BACKTITLE" --title "$1" --ok-button "확인" \
             --scrolltext --msgbox "$2" 20 76
}

ui_yesno() { # title, text -> 0=예 1=아니오
    whiptail --backtitle "$BACKTITLE" --title "$1" \
             --yes-button "예" --no-button "아니오" \
             --scrolltext --yesno "$2" 20 76
}

ui_menu() {  # title, text, tag item tag item ... -> 선택 tag. 취소 시 rc=1
    local title="$1" text="$2"; shift 2
    whiptail --backtitle "$BACKTITLE" --title "$title" \
             --ok-button "확인" --cancel-button "취소하고 종료" \
             --menu "$text" 20 72 9 "$@" 3>&1 1>&2 2>&3
}

ui_input() { # title, text, default -> 입력값. 취소 시 rc=1
    whiptail --backtitle "$BACKTITLE" --title "$1" \
             --ok-button "확인" --cancel-button "취소하고 종료" \
             --inputbox "$2" 11 72 "$3" 3>&1 1>&2 2>&3
}

ui_passwd() { # title, text
    whiptail --backtitle "$BACKTITLE" --title "$1" \
             --ok-button "확인" --cancel-button "취소하고 종료" \
             --passwordbox "$2" 11 72 3>&1 1>&2 2>&3
}

# ---------------------------------------------------------------- 사전 점검
precheck() {
    [[ $EUID -eq 0 ]] || { echo "root 권한으로 실행해야 합니다." >&2; exit 1; }
    command -v qm >/dev/null 2>&1 || {
        echo "qm 명령을 찾을 수 없습니다. Proxmox 노드에서 실행하세요." >&2; exit 1; }
    [[ -t 0 && -t 1 ]] || { echo "대화형 터미널에서 실행하세요." >&2; exit 1; }

    : >"$LOG_FILE"; chmod 600 "$LOG_FILE"
    log "스크립트 시작 (pid=$$)"

    # 필수 패키지. whiptail 은 없으면 TUI 자체가 불가하므로 먼저 확인한다.
    local p out
    for p in whiptail wget; do
        command -v "$p" >/dev/null 2>&1 && continue
        echo "$p 설치를 시도합니다..."
        out=$(apt-get install -y "$p" 2>&1) || {
            log "ERROR apt install $p: $out"
            echo "$p 설치에 실패했습니다." >&2; echo "$out" >&2; exit 1
        }
    done
}

# ---------------------------------------------------------------- 공용 조회
list_bridges() { ls /sys/class/net 2>/dev/null | grep -E '^vmbr[0-9]+$' | sort; }
list_storages() { pvesm status --content "$1" 2>/dev/null | awk 'NR>1 {print $1}'; }

storage_path() {  # dir 타입 스토리지의 path
    awk -v s="$1" '
        $1=="dir:" && $2==s {f=1; next}
        f && /^[a-z]+:/ {f=0}
        f && $1=="path" {print $2; exit}
    ' /etc/pve/storage.cfg
}

# ---------------------------------------------------------------- 1단계: 정보수집
pick_from_list() {  # title, text, 항목들(개행 구분) -> 선택값
    local title="$1" text="$2" items="$3"
    local args=() it
    while read -r it; do [[ -n "$it" ]] && args+=("$it" ""); done <<<"$items"
    [[ ${#args[@]} -eq 0 ]] && return 1
    ui_menu "$title" "$text" "${args[@]}"
}

validate_input() {
    local msg=""
    [[ "$VMID"      =~ ^[0-9]+$ ]] || msg+="VMID 는 숫자여야 합니다.\n"
    [[ "$CORES"     =~ ^[0-9]+$ ]] || msg+="Cores 는 숫자여야 합니다.\n"
    [[ "$MEMORY"    =~ ^[0-9]+$ ]] || msg+="Memory 는 숫자(MiB)여야 합니다.\n"
    [[ "$DISKSIZE"  =~ ^[0-9]+$ ]] || msg+="Disk Size 는 숫자(GiB)여야 합니다.\n"
    { [[ "$SUBNETBIT" =~ ^[0-9]+$ ]] && (( SUBNETBIT >= 1 && SUBNETBIT <= 32 )); } \
        || msg+="Subnet Bit 는 1~32 여야 합니다.\n"
    [[ "$IPADDR"  =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || msg+="IP 형식이 올바르지 않습니다.\n"
    [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || msg+="Gateway 형식이 올바르지 않습니다.\n"
    [[ -n "$ROOTPW" ]] || msg+="Root Password 가 비어 있습니다.\n"

    if [[ -z "$msg" ]] && qm config "$VMID" >/dev/null 2>&1; then
        msg+="VMID $VMID 는 이미 사용 중입니다.\n"
    fi
    [[ -z "$msg" ]] && return 0

    log "ERROR 입력 검증: ${msg//$'\n'/ }"
    ui_err "입력 오류" "$msg"
    return 1
}

step_collect() {
    local brs sts
    while true; do
        VMID=$(ui_input "공통단계 정보수집 (1/10)" "VMID 를 입력하세요." "$VMID") || return 2

        CPUTYPE=$(ui_menu "공통단계 정보수집 (2/10)" "CPU Type 을 선택하세요." \
            "host"          "물리 CPU 그대로 노출 (단일 노드 권장)" \
            "x86-64-v3"     "Haswell 이후 공통 기능 (마이그레이션용)" \
            "x86-64-v2-AES" "Nehalem 이후 + AES" \
            "kvm64"         "최대 호환, 성능 낮음") || return 2

        CORES=$(ui_input   "공통단계 정보수집 (3/10)" "Cores 를 입력하세요." "$CORES") || return 2
        MEMORY=$(ui_input  "공통단계 정보수집 (4/10)" "Memory 를 MiB 단위로 입력하세요." "$MEMORY") || return 2
        IPADDR=$(ui_input  "공통단계 정보수집 (5/10)" "IP 를 입력하세요. (예: 192.168.0.50)" "$IPADDR") || return 2
        SUBNETBIT=$(ui_input "공통단계 정보수집 (6/10)" "Subnet Bit 를 입력하세요. (예: 24)" "$SUBNETBIT") || return 2
        GATEWAY=$(ui_input "공통단계 정보수집 (7/10)" "Gateway IP 를 입력하세요." "$GATEWAY") || return 2

        brs=$(list_bridges)
        if [[ -n "$brs" ]]; then
            BRIDGE=$(pick_from_list "공통단계 정보수집 (8/10)" "Bridge 를 선택하세요." "$brs") || return 2
        else
            BRIDGE=$(ui_input "공통단계 정보수집 (8/10)" "Bridge 를 입력하세요." "vmbr0") || return 2
        fi

        DISKSIZE=$(ui_input "공통단계 정보수집 (9/10)" "Disk Size 를 GiB 단위로 입력하세요." "$DISKSIZE") || return 2

        sts=$(list_storages images)
        if [[ -z "$sts" ]]; then
            ui_err "오류" "VM 디스크를 둘 수 있는 스토리지가 없습니다."
            return 2
        fi
        DISKAREA=$(pick_from_list "공통단계 정보수집 (10/10)" "Disk Area 를 선택하세요." "$sts") || return 2

        ROOTPW=$(ui_passwd "Root Password" "root 계정 비밀번호를 입력하세요.") || return 2

        validate_input || continue

        log "정보수집: VMID=$VMID CPU=$CPUTYPE cores=$CORES mem=$MEMORY ip=$IPADDR/$SUBNETBIT gw=$GATEWAY br=$BRIDGE disk=${DISKSIZE}G area=$DISKAREA"
        if ui_yesno "입력 확인" "\
VMID        : $VMID
CPU Type    : $CPUTYPE
Cores       : $CORES
Memory      : $MEMORY MiB
IP          : $IPADDR/$SUBNETBIT
Gateway     : $GATEWAY
Bridge      : $BRIDGE
Disk Size   : $DISKSIZE GiB
Disk Area   : $DISKAREA
Root Passwd : (입력됨)

이대로 진행할까요?"; then
            return 0
        fi
        log "사용자 선택: 입력 단계로 복귀"
    done
}

# ---------------------------------------------------------------- 2단계: 이미지 폴더
step_imgdir() {
    local args=() n p pick
    while true; do
        args=()
        while read -r n; do
            [[ -z "$n" ]] && continue
            p=$(storage_path "$n"); [[ -n "$p" ]] && args+=("$n" "$p/template/iso")
        done < <(list_storages iso)

        if [[ ${#args[@]} -eq 0 ]]; then
            ui_err "이미지 폴더" "디렉터리 타입 스토리지를 찾을 수 없습니다."
            return 2
        fi

        pick=$(ui_menu "Ubuntu 26.04 Cloud Image 다운로드" \
                       "파일을 다운로드할 폴더를 선택하세요." "${args[@]}") \
            || { log "사용자 종료 (이미지 폴더)"; return 2; }

        IMG_DIR="$(storage_path "$pick")/template/iso"
        if ui_yesno "확인" "'$IMG_DIR' 에 설치할까요?"; then
            mkdir -p "$IMG_DIR"
            IMG_PATH="$IMG_DIR/ubuntu-26.04-server-cloudimg-amd64.img"
            log "이미지 폴더 선택: $IMG_DIR"
            return 0
        fi
        log "사용자 선택: 이미지 폴더 재선택"
    done
}

# ---------------------------------------------------------------- 3단계: 다운로드
repo_alive() { wget -q --spider --timeout=10 --tries=1 "$1" 2>>"$LOG_FILE"; }

do_download() {  # $1 = url
    log "다운로드 시도: $1"
    : >"$TMP_ERR"
    wget --progress=dot:giga -O "$IMG_PATH" "$1" 2>&1 \
        | tee "$TMP_ERR" \
        | stdbuf -oL tr '\r' '\n' \
        | sed -une 's/.* \([0-9]\+\)% .*/\1/p' \
        | whiptail --backtitle "$BACKTITLE" --title "다운로드" \
                   --gauge "Cloud Image 를 내려받는 중입니다..." 8 70 0
    return "${PIPESTATUS[0]}"
}

step_download() {
    local url="" pick
    if repo_alive "$REPO1_URL"; then
        url="$REPO1_URL"; log "레포1 사용 가능"
    elif repo_alive "$REPO2_URL"; then
        url="$REPO2_URL"; log "레포1 불가, 레포2 사용 가능"
    else
        log "ERROR 레포1/레포2 모두 통신 불가"
        pick=$(ui_menu "레포 사이트 통신 불가" \
            "사설 레포지토리 이용 등의 경우 직접 주소를 입력하시겠습니까?" \
            "input" "직접 주소를 입력한다" \
            "back"  "이전 단계로 이동") \
            || { log "사용자 종료 (다운로드)"; return 2; }
        [[ "$pick" == "back" ]] && return 1

        url=$(ui_input "주소 입력" "Cloud Image 의 전체 URL 을 입력하세요." "") || return 1
        [[ -n "$url" ]] || return 1
        log "직접 입력 URL: $url"
    fi

    if do_download "$url"; then
        log "다운로드 완료: $IMG_PATH"
        return 0
    fi

    log "ERROR wget: $(cat "$TMP_ERR")"
    rm -f "$IMG_PATH"
    ui_err "다운로드 실패" "$(tail -n 20 "$TMP_ERR")"
    return 1
}

# ---------------------------------------------------------------- 4단계: yaml 생성
write_yaml() {
    local f="$SNIP_DIR/$YAML_NAME"
    umask 077
    cat >"$f" <<EOS
#cloud-config

# SSH 비밀번호 로그인 허용
ssh_pwauth: true
disable_root: false

# 부팅 시 apt update
package_update: true

packages:
  - net-tools
  - qemu-guest-agent

# 루트 파티션을 디스크 끝까지 확장
growpart:
  mode: auto
  devices: ['/']

# 네트워크 대기로 인한 부팅 지연 방지
bootcmd:
  - systemctl disable NetworkManager-wait-online.service
  - systemctl mask NetworkManager-wait-online.service
  - systemctl disable systemd-networkd-wait-online.service
  - systemctl mask systemd-networkd-wait-online.service

runcmd:
  - echo 'root:${ROOTPW}' | chpasswd
  - echo "PermitRootLogin yes" > /etc/ssh/sshd_config.d/99-custom.conf
  - echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config.d/99-custom.conf
  - systemctl restart ssh
  - systemctl enable --now qemu-guest-agent
EOS
    local rc=$?
    chmod 600 "$f"
    [[ $rc -eq 0 ]] && return 0
    log "ERROR yaml 쓰기 실패: $f"
    ui_err "yaml 생성 실패" "$f 에 쓸 수 없습니다."
    return 1
}

step_yaml() {
    local args=() n p
    while true; do
        args=()
        while read -r n; do
            [[ -z "$n" ]] && continue
            p=$(storage_path "$n"); [[ -n "$p" ]] && args+=("$n" "$p/snippets")
        done < <(list_storages snippets)

        if [[ ${#args[@]} -eq 0 ]]; then
            ui_err "snippets 폴더" \
"snippets 를 지원하는 스토리지가 없습니다.

데이터센터 > 스토리지 > local > 편집 > 내용 에서
'Snippets' 를 추가한 뒤 다시 실행하세요."
            return 2
        fi

        SNIP_STORE=$(ui_menu "yaml 파일 생성" "파일을 생성할 폴더를 선택하세요." "${args[@]}") \
            || { log "사용자 종료 (snippets 폴더)"; return 2; }

        SNIP_DIR="$(storage_path "$SNIP_STORE")/snippets"
        if ! ui_yesno "확인" "'$SNIP_DIR' 에 생성할까요?"; then
            log "사용자 선택: snippets 폴더 재선택"; continue
        fi

        mkdir -p "$SNIP_DIR"
        YAML_NAME="u2604-${VMID}.yaml"
        write_yaml || return 2
        log "yaml 생성: $SNIP_DIR/$YAML_NAME"
        ui_msg "yaml 파일 생성" "$SNIP_DIR/$YAML_NAME\n\n생성을 완료했습니다."
        return 0
    done
}

# ---------------------------------------------------------------- 5단계: VM 생성
vm_commands() {
    cat <<EOS
qm create $VMID --name ubuntu-2604-$VMID --memory $MEMORY --cores $CORES --sockets 1 --cpu $CPUTYPE --net0 virtio,bridge=$BRIDGE --scsihw virtio-scsi-single --ostype l26 --vga std --agent enabled=1
qm set $VMID --virtio0 $DISKAREA:0,import-from=$IMG_PATH
qm disk resize $VMID virtio0 ${DISKSIZE}G
qm set $VMID --ide2 $DISKAREA:cloudinit
qm set $VMID --boot order=virtio0
qm set $VMID --ipconfig0 ip=$IPADDR/$SUBNETBIT,gw=$GATEWAY
qm set $VMID --cicustom user=$SNIP_STORE:snippets/$YAML_NAME
EOS
}

run_vm_commands() {  # whiptail --gauge 형식으로 진행도를 흘린다
    local -a cmds; mapfile -t cmds < <(vm_commands)
    local total=${#cmds[@]} i=0 out rc c
    : >"$TMP_ERR"
    for c in "${cmds[@]}"; do
        i=$((i+1))
        printf 'XXX\n%d\n(%d/%d) %s\nXXX\n' $(( i * 100 / total )) "$i" "$total" "${c:0:56}"
        out=$(eval "$c" 2>&1); rc=$?
        if [[ $rc -ne 0 ]]; then
            log "ERROR $c"
            log "ERROR 원문: $out"
            printf '%s\n%s\n' "$c" "$out" >"$TMP_ERR"
            return 1
        fi
    done
    printf 'XXX\n100\n완료\nXXX\n'
    return 0
}

step_create() {
    log "VM 생성 확인 요청"
    if ! ui_yesno "VM 실제 생성" "아래 설정으로 생성합니다.

$(vm_commands)

이대로 생성할까요?"; then
        log "사용자 종료 (VM 생성 취소)"
        return 2
    fi

    run_vm_commands | whiptail --backtitle "$BACKTITLE" --title "VM 생성" \
                               --gauge "VM 을 생성하는 중입니다..." 10 70 0
    if [[ ${PIPESTATUS[0]} -eq 0 ]]; then
        log "VM $VMID 생성 완료"
        ui_msg "완료" "설치가 완료되었습니다.\n\nVMID : $VMID\nIP   : $IPADDR/$SUBNETBIT\n로그 : $LOG_FILE"
    else
        ui_err "실패" "설치가 실패하였습니다.\n\n$(cat "$TMP_ERR")\n\n로그: $LOG_FILE"
    fi
    return 2   # 마지막 단계이므로 정상 종료
}

# ---------------------------------------------------------------- 메인
precheck

step=1
while true; do
    case $step in
        1) step_collect;  rc=$? ;;
        2) step_imgdir;   rc=$? ;;
        3) step_download; rc=$? ;;
        4) step_yaml;     rc=$? ;;
        5) step_create;   rc=$? ;;
        *) break ;;
    esac
    case $rc in
        0) step=$((step+1)) ;;
        1) step=$((step-1)); (( step < 1 )) && step=1 ;;
        2) break ;;
    esac
done

log "스크립트 종료"
clear
echo "로그: $LOG_FILE"
exit 0
