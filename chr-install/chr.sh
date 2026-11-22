#!/bin/bash

# MikroTik RouterOS CHR Installer
# Enhanced with universal network configuration & pre-install summary
# Version: 2.0

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "$1 is required but not installed. Aborting."
        exit 1
    }
}

LOOP_DEVICE=""

cleanup() {
    log_info "Cleaning up temporary files..."
    if mountpoint -q /mnt 2>/dev/null; then
        umount /mnt 2>/dev/null || true
    fi
    if [ -n "${LOOP_DEVICE:-}" ]; then
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    fi
    qemu-nbd -d /dev/nbd0 2>/dev/null || true
    qemu-nbd -d /dev/nbd1 2>/dev/null || true
    rm -f chr-*.*.* chr.img.zip chr.qcow2 chr-efi.qcow2 2>/dev/null || true
    rm -rf /tmp/chr-bios /tmp/chr-efi 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Check required commands
required_commands=(wget gunzip fdisk lsblk ip losetup dd awk)
for cmd in "${required_commands[@]}"; do
    check_command "$cmd"
done

# Show welcome banner
clear
echo -e "${CYAN}=================================================================${NC}"
echo -e "${CYAN}             MikroTik RouterOS CHR Installer v2.0                ${NC}"
echo -e "${CYAN}=================================================================${NC}"
echo

# 1. RouterOS Version
DEFAULT_ROS_VERSION="7.16.1"
log_info "Fetching latest RouterOS version..."
DETECTED_ROS_VERSION=$(wget -qO- --timeout=5 https://upgrade.mikrotik.com/routeros/NEWESTa7.long-term 2>/dev/null | awk '{print $1}' || true)
if [ -n "$DETECTED_ROS_VERSION" ]; then
    DEFAULT_ROS_VERSION="$DETECTED_ROS_VERSION"
fi

read -p "Enter RouterOS Version [Default: ${DEFAULT_ROS_VERSION}]: " ROS_VERSION || true
ROS_VERSION=${ROS_VERSION:-${DEFAULT_ROS_VERSION}}

# 2. Admin Password
get_admin_password() {
    while true; do
        read -sp "Enter RouterOS admin password: " admin_password || true
        echo
        while [ -z "$admin_password" ]; do
            read -sp "Password cannot be blank. Enter again: " admin_password || true
            echo
        done
        read -sp "Confirm RouterOS admin password: " admin_password_confirm || true
        echo
        if [ "$admin_password" = "$admin_password_confirm" ]; then
            break
        fi
        log_error "Passwords do not match. Please try again."
    done
}
get_admin_password

# 3. SSH Service choice
echo
read -p "Keep SSH service enabled (port 22)? [Y/n] (Default: Y): " enable_ssh_input || true
enable_ssh_input=$(echo "${enable_ssh_input:-Y}" | tr '[:lower:]' '[:upper:]')
if [ "$enable_ssh_input" = "Y" ]; then
    ENABLE_SSH=true
else
    ENABLE_SSH=false
fi

# 4. Network Configuration & Auto-Detection
log_info "Detecting network configuration..."

# Detect default outgoing interface
DEF_DEV=$( (ip -4 route show default 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 )
if [ -z "$DEF_DEV" ]; then
    DEF_DEV=$(ip -o -4 addr show 2>/dev/null | awk '$2 != "lo" {print $2}' | head -n1 || true)
fi

# Detect IP address and CIDR prefix length
IP_CIDR=""
if [ -n "$DEF_DEV" ]; then
    IP_CIDR=$(ip -4 addr show dev "$DEF_DEV" 2>/dev/null | awk '$1=="inet" {print $2}' | head -n1 || true)
fi

IP_ADDR=""
NETMASK_CIDR="32"
if [ -n "$IP_CIDR" ]; then
    IP_ADDR="${IP_CIDR%/*}"
    NETMASK_CIDR="${IP_CIDR#*/}"
fi

# Fallback for IP if not found from interface
if [ -z "$IP_ADDR" ]; then
    IP_ADDR=$( (ip -4 route get 1.1.1.1 2>/dev/null || ip -4 route get 10.0.0.1 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 || true)
fi

# Detect Gateway
GATEWAY=$( (ip -4 route show default 2>/dev/null || ip route 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1 || true)
if [ -z "$GATEWAY" ] && [ -n "$DEF_DEV" ]; then
    GATEWAY=$(ip -4 addr show dev "$DEF_DEV" 2>/dev/null | awk '$1=="inet" && $3=="peer" {sub(/\/.*/, "", $4); print $4}' | head -n1 || true)
fi

# Detect DNS servers from resolv.conf
DNS_SERVERS=$(awk '/^nameserver/ && $2 !~ /^127\./ {print $2}' /etc/resolv.conf 2>/dev/null | tr '\n' ',' | sed 's/,$//' || true)
if [ -z "$DNS_SERVERS" ]; then
    DNS_SERVERS="1.1.1.1,8.8.8.8"
fi

echo
echo -e "${GREEN}Detected Network Settings:${NC}"
echo "  Primary Interface: ${DEF_DEV:-unknown}"
echo "  IP Address / CIDR: ${IP_ADDR:-not detected}/${NETMASK_CIDR}"
echo "  Default Gateway:   ${GATEWAY:-not detected}"
echo "  DNS Servers:       ${DNS_SERVERS}"
echo
echo "Select network configuration mode for RouterOS:"
echo "  1) Static IP (Recommended for VPS / Cloud servers)"
echo "  2) DHCP Client (Automatic configuration via DHCP)"
read -p "Enter choice [1/2] (Default: 1): " net_mode_choice || true
net_mode_choice=${net_mode_choice:-1}

NET_MODE="STATIC"
if [ "$net_mode_choice" = "2" ]; then
    NET_MODE="DHCP"
else
    NET_MODE="STATIC"
    echo
    # IP & CIDR prompt
    read -p "Enter IP address with CIDR [${IP_ADDR}/${NETMASK_CIDR}]: " input_ip_cidr || true
    input_ip_cidr=${input_ip_cidr:-"${IP_ADDR}/${NETMASK_CIDR}"}
    while [ -z "$input_ip_cidr" ]; do
        read -p "IP address cannot be blank. Enter IP/CIDR: " input_ip_cidr || true
    done

    if [[ "$input_ip_cidr" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})/([0-9]{1,2})$ ]]; then
        IP_ADDR="${BASH_REMATCH[1]}"
        NETMASK_CIDR="${BASH_REMATCH[2]}"
    elif [[ "$input_ip_cidr" =~ ^([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})$ ]]; then
        IP_ADDR="${BASH_REMATCH[1]}"
        read -p "Enter subnet prefix CIDR (e.g. 24, 32) [${NETMASK_CIDR}]: " input_cidr || true
        NETMASK_CIDR=${input_cidr:-$NETMASK_CIDR}
    fi

    # Gateway prompt
    read -p "Enter Default Gateway [${GATEWAY}]: " input_gw || true
    GATEWAY=${input_gw:-$GATEWAY}
    while [ -z "$GATEWAY" ]; do
        read -p "Gateway cannot be blank for static IP. Enter Gateway: " GATEWAY || true
    done

    # DNS prompt
    read -p "Enter DNS servers (comma-separated) [${DNS_SERVERS}]: " input_dns || true
    DNS_SERVERS=${input_dns:-$DNS_SERVERS}
fi

# 5. Boot Mode Detection
if [ -d "/sys/firmware/efi" ]; then
    BOOT_MODE="UEFI"
else
    BOOT_MODE="BIOS Legacy"
fi

# 6. Target Disk Detection
detect_target_disk() {
    # 1. Parent disk of root mount /
    local root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
    if [ -n "$root_src" ]; then
        local pkname=$(lsblk -no PKNAME "$root_src" 2>/dev/null || true)
        if [ -n "$pkname" ]; then
            echo "/dev/$pkname"
            return 0
        fi
    fi
    # 2. lsblk disk excluding loop, zram, rom
    local disk1=$(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk" && $1!~/^(loop|zram|sr)/ {print $1}' | head -1 || true)
    if [ -n "$disk1" ]; then
        echo "/dev/$disk1"
        return 0
    fi
    # 3. fdisk fallback
    local disk2=$(fdisk -l 2>/dev/null | grep "^Disk /dev" | grep -v "^Disk /dev/loop" | cut -d' ' -f2 | tr -d ':' | head -1 || true)
    if [ -n "$disk2" ]; then
        echo "$disk2"
        return 0
    fi
    return 1
}

DETECTED_DISK=$(detect_target_disk || echo "")
echo
echo -e "${GREEN}Available Block Storage Devices:${NC}"
lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -Ev "loop|zram" || true
echo
read -p "Target disk for installation [${DETECTED_DISK}]: " input_disk || true
DISK_DEVICE=${input_disk:-$DETECTED_DISK}

while [ -z "$DISK_DEVICE" ] || [ ! -b "$DISK_DEVICE" ]; do
    log_error "Disk '$DISK_DEVICE' is not a valid block device!"
    read -p "Please enter a valid target disk device (e.g. /dev/vda, /dev/sda): " DISK_DEVICE || true
done

# =================================================================
# 7. PRE-INSTALLATION SUMMARY (Вывод предстоящих настроек)
# =================================================================
echo
echo -e "${YELLOW}=================================================================${NC}"
echo -e "${YELLOW}                 PRE-INSTALLATION CONFIGURATION SUMMARY          ${NC}"
echo -e "${YELLOW}=================================================================${NC}"
printf "  %-24s: %s\n" "RouterOS Version" "$ROS_VERSION"
printf "  %-24s: %s\n" "Boot Mode" "$BOOT_MODE"
printf "  %-24s: %s\n" "Target Disk" "$DISK_DEVICE (ALL DATA WILL BE DESTROYED!)"
echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
printf "  %-24s: %s\n" "Network Mode" "$NET_MODE"
if [ "$NET_MODE" = "STATIC" ]; then
    printf "  %-24s: %s\n" "IP Address" "${IP_ADDR}/${NETMASK_CIDR}"
    printf "  %-24s: %s\n" "Default Gateway" "$GATEWAY"
    if [ "$NETMASK_CIDR" = "32" ] || [ "$GATEWAY" = "10.0.0.1" ]; then
        printf "  %-24s: %s\n" "Routing Type" "Point-to-Point (/32 with network=$GATEWAY)"
    else
        printf "  %-24s: %s\n" "Routing Type" "Standard Subnet (/${NETMASK_CIDR})"
    fi
    printf "  %-24s: %s\n" "DNS Servers" "$DNS_SERVERS"
    printf "  %-24s: %s\n" "RouterOS Interface" "ether1"
else
    printf "  %-24s: %s\n" "DHCP Client" "Enabled on ether1 (add-default-route=yes)"
fi
echo -e "${YELLOW}-----------------------------------------------------------------${NC}"
printf "  %-24s: %s\n" "Admin Username" "admin"
printf "  %-24s: %s\n" "Admin Password" "[Configured]"
printf "  %-24s: %s\n" "WinBox (Port 8291)" "Enabled"
printf "  %-24s: %s\n" "SSH (Port 22)" "$([ "$ENABLE_SSH" = true ] && echo "Enabled" || echo "Disabled")"
printf "  %-24s: %s\n" "Insecure Services" "Disabled (telnet, ftp, www, api)"
printf "  %-24s: %s\n" "Container Support" "Enabled"
echo -e "${YELLOW}=================================================================${NC}"
echo
echo -e "${RED}WARNING: THIS WILL COMPLETELY DESTROY ALL DATA ON (${DISK_DEVICE})!${NC}"
read -p "Are you sure you want to proceed? Type 'Y' to continue: " confirmation || true
confirmation=$(echo "${confirmation:-N}" | tr '[:lower:]' '[:upper:]')
if [ "$confirmation" != "Y" ]; then
    log_info "Operation cancelled by user."
    exit 0
fi

# 8. Download CHR Image and Container Package
CHR_URL="https://download.mikrotik.com/routeros/${ROS_VERSION}/chr-${ROS_VERSION}.img.zip"
CONTAINER_URL="https://download.mikrotik.com/routeros/${ROS_VERSION}/container-${ROS_VERSION}.npk"

log_info "Downloading RouterOS CHR ${ROS_VERSION} Image..."
wget -N "$CHR_URL" 2>&1 || {
    log_error "Failed to download CHR Image from $CHR_URL"
    exit 1
}

CONTAINER_DOWNLOAD_FAILED=false
log_info "Downloading RouterOS CHR ${ROS_VERSION} Container Package..."
wget -N "$CONTAINER_URL" 2>&1 || {
    log_warn "Failed to download container package, continuing without it..."
    CONTAINER_DOWNLOAD_FAILED=true
}

# Unzip Image
log_info "Extracting RouterOS CHR Image..."
gunzip -c "chr-${ROS_VERSION}.img.zip" > "chr.img" || {
    log_error "Failed to extract CHR Image"
    exit 1
}

# 9. UEFI Image Conversion (if required)
if [ "$BOOT_MODE" = "UEFI" ]; then
    log_info "Performing UEFI conversion..."
    # Install required conversion tools
    if [ -f /etc/debian_version ]; then
        apt update && apt install -y rsync qemu-utils gdisk dosfstools
    elif [ -f /etc/redhat-release ]; then
        if command -v dnf >/dev/null; then
            dnf install -y rsync qemu-img gdisk dosfstools
        else
            yum install -y rsync qemu-img gdisk dosfstools
        fi
    elif [ -f /etc/arch-release ]; then
        pacman -S --noconfirm rsync qemu-img gptfdisk dosfstools
    else
        log_error "Unsupported Linux distribution for automated UEFI conversion"
        exit 1
    fi

    # Convert to qcow2
    qemu-img convert -f raw -O qcow2 chr.img chr.qcow2
    cp -af chr.qcow2 chr-efi.qcow2
    rm -rf chr.img

    # nbd module
    modprobe nbd max_part=8
    sleep 2
    qemu-nbd -c /dev/nbd0 chr.qcow2
    qemu-nbd -c /dev/nbd1 chr-efi.qcow2
    sleep 2

    # Format boot partition
    mkfs.fat -F16 /dev/nbd1p1

    # Mount & copy
    mkdir -p /tmp/chr-bios /tmp/chr-efi
    mount /dev/nbd0p1 /tmp/chr-bios/
    mount /dev/nbd1p1 /tmp/chr-efi/
    rsync -a /tmp/chr-bios/ /tmp/chr-efi/
    umount /dev/nbd0p1
    umount /dev/nbd1p1

    # Disconnect nbd
    qemu-nbd -d /dev/nbd0
    qemu-nbd -d /dev/nbd1
    sleep 2

    # Convert back to raw
    qemu-img convert -f qcow2 -O raw chr-efi.qcow2 chr.img
    rm -f chr.qcow2 chr-efi.qcow2
    rm -rf /tmp/chr-bios /tmp/chr-efi
fi

# 10. Mount CHR Image and Configure autorun.scr
log_info "Mounting CHR image..."
umount /mnt 2>/dev/null || true
mkdir -p /mnt

LOOP_DEVICE=$(losetup -Pf --show chr.img)
if [ -e "${LOOP_DEVICE}p2" ]; then
    mount "${LOOP_DEVICE}p2" /mnt || {
        log_error "Failed to mount partition 2 of image"
        exit 1
    }
else
    mount -o loop,offset=33571840 chr.img /mnt || {
        log_error "Failed to mount image at offset 33571840"
        exit 1
    }
fi

mkdir -p /mnt/rw

# Write autorun.scr
log_info "Writing autorun script (/mnt/rw/autorun.scr)..."
cat > /mnt/rw/autorun.scr <<EOF
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/ip service set winbox disabled=no
EOF

if [ "$ENABLE_SSH" = true ]; then
    echo "/ip service set ssh disabled=no" >> /mnt/rw/autorun.scr
else
    echo "/ip service set ssh disabled=yes" >> /mnt/rw/autorun.scr
fi

cat >> /mnt/rw/autorun.scr <<EOF
/user set admin password="${admin_password}"
/system package enable container
EOF

# Network configuration in autorun.scr
if [ "$NET_MODE" = "STATIC" ]; then
    log_info "Appending Static IP configuration to autorun.scr..."
    cat >> /mnt/rw/autorun.scr <<EOF
:do { /ip dhcp-client remove [find] } on-error={}
EOF
    if [ "$NETMASK_CIDR" = "32" ] || [ "$GATEWAY" = "10.0.0.1" ]; then
        cat >> /mnt/rw/autorun.scr <<EOF
/ip address add address=${IP_ADDR}/32 network=${GATEWAY} interface=ether1
/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY}
EOF
    else
        cat >> /mnt/rw/autorun.scr <<EOF
/ip address add address=${IP_ADDR}/${NETMASK_CIDR} interface=ether1
/ip route add dst-address=0.0.0.0/0 gateway=${GATEWAY}
EOF
    fi

    if [ -n "$DNS_SERVERS" ]; then
        cat >> /mnt/rw/autorun.scr <<EOF
/ip dns set servers=${DNS_SERVERS}
EOF
    fi
else
    log_info "Appending DHCP client configuration to autorun.scr..."
    cat >> /mnt/rw/autorun.scr <<EOF
/ip dhcp-client add interface=ether1 disabled=no add-default-route=yes use-peer-dns=yes
EOF
fi

# Write rosmode message to trigger script execution on first boot
log_info "Writing rosmode message..."
echo -e -n "\x4d\x32\x01\x00\x00\x29\x0b\x4d\x32\x1c\x00\x00\x01\x0a\x00\x00\x09\x00" > /mnt/rw/rosmode.msg

# Install container package if downloaded
if [ "${CONTAINER_DOWNLOAD_FAILED:-false}" = false ] && [ -f "container-${ROS_VERSION}.npk" ]; then
    log_info "Installing container package..."
    mkdir -p /mnt/var/pdb/container
    mv -f "container-${ROS_VERSION}.npk" /mnt/var/pdb/container/image
else
    log_warn "Skipping container package installation"
fi

# Unmount image
log_info "Unmounting CHR image..."
sync
umount /mnt || {
    sleep 2
    umount -l /mnt || true
}
if [ -n "${LOOP_DEVICE:-}" ]; then
    losetup -d "$LOOP_DEVICE" 2>/dev/null || true
    LOOP_DEVICE=""
fi

# 11. Write Image to Target Disk
log_info "Writing image to disk ($DISK_DEVICE). This may take several minutes..."
dd if=chr.img of="$DISK_DEVICE" bs=4M oflag=sync status=progress || {
    log_error "Failed to write image to disk"
    exit 1
}
sync

# 12. Completion & System Reboot
echo
echo -e "${GREEN}=================================================================${NC}"
echo -e "${GREEN}      RouterOS CHR ${ROS_VERSION} Installation Completed!       ${NC}"
echo -e "${GREEN}=================================================================${NC}"
printf "  %-20s: %s\n" "Login User" "admin"
printf "  %-20s: %s\n" "Login Password" "(the password you entered)"
if [ "$NET_MODE" = "STATIC" ]; then
    printf "  %-20s: %s\n" "IP Address" "${IP_ADDR}/${NETMASK_CIDR}"
    printf "  %-20s: %s\n" "Gateway" "$GATEWAY"
    printf "  %-20s: %s\n" "DNS Servers" "$DNS_SERVERS"
else
    printf "  %-20s: %s\n" "Network Mode" "DHCP Client on ether1"
fi
printf "  %-20s: %s\n" "WinBox Access" "Port 8291 (Default)"
printf "  %-20s: %s\n" "SSH Access" "$([ "$ENABLE_SSH" = true ] && echo "Port 22 (Default)" || echo "Disabled")"
echo -e "${GREEN}=================================================================${NC}"
echo
log_info "System will automatically reboot into RouterOS CHR in 5 seconds..."
sleep 5

echo 1 > /proc/sys/kernel/sysrq
echo b > /proc/sysrq-trigger
