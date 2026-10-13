#!/bin/bash

# https://www.77bx.com/497.html
# by StarYu
# Version: 1.3 (Updated with 10.0.0.1 gateway support)

# 全局默认RouterOS版本号配置
DEFAULT_ROS_VERSION=$(wget -qO- https://upgrade.mikrotik.com/routeros/NEWESTa7.long-term | awk '{print $1}')

set -euo pipefail

# color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

cleanup() {
    log_info "Cleaning up temporary files..."
    rm -f chr-*.*.*
    rm -f container-*.*.*
}

trap cleanup EXIT INT TERM

# check commands
required_commands=(wget gunzip fdisk lsblk ip)
for cmd in "${required_commands[@]}"; do
    check_command "$cmd"
done

# show welcome
clear
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}RouterOS CHR Installer 1.3 (with 10.0.0.1 GW support)${NC}"
echo -e "${GREEN}=========================================${NC}"
echo

# get version (使用全局默认值)
read -p "Please Input RouterOS Version (Default: ${DEFAULT_ROS_VERSION}): " ROS_VERSION
ROS_VERSION=${ROS_VERSION:-${DEFAULT_ROS_VERSION}}

# get admin password
get_admin_password() {
    read -sp "Enter RouterOS admin password: " admin_password
    echo
    while [ -z "$admin_password" ]; do
        read -sp "RouterOS Admin password cannot be blank. Please enter again: " admin_password
        echo
    done
}
get_admin_password

# detect network configuration (check gateway 10.0.0.1)
log_info "Checking network configuration..."
GATEWAY=$( (ip -4 route show default 2>/dev/null || ip route 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | head -n1 )

IP_ADDR=""
if [ "$GATEWAY" = "10.0.0.1" ]; then
    log_warn "Detected gateway 10.0.0.1 (point-to-point /32 route required)."
    
    # Try auto-detecting current IPv4
    IP_ADDR=$( (ip -4 route get 1.1.1.1 2>/dev/null || ip -4 route get 10.0.0.1 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -n1 )
    
    # Fallback to interface IP
    if [ -z "$IP_ADDR" ]; then
        DEF_DEV=$( (ip -4 route show default 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1 )
        if [ -n "$DEF_DEV" ]; then
            IP_ADDR=$( (ip -4 addr show dev "$DEF_DEV" 2>/dev/null || true) | awk '$1=="inet" {sub(/\/.*/, "", $2); print $2}' | head -n1 )
        fi
    fi

    # Confirm or input IP address
    input_ip=""
    if [ -n "$IP_ADDR" ]; then
        read -p "Detected IP address: [${IP_ADDR}]. Press Enter to use it, or enter custom IP: " input_ip || true
        IP_ADDR=${input_ip:-$IP_ADDR}
    else
        read -p "Could not auto-detect IP address. Please enter RouterOS IP address: " IP_ADDR || true
    fi

    while [ -z "$IP_ADDR" ]; do
        read -p "IP address cannot be blank. Please enter RouterOS IP address: " IP_ADDR || true
    done

    log_info "RouterOS will be configured with: IP=${IP_ADDR}/32, Gateway=10.0.0.1"
else
    log_info "Gateway: ${GATEWAY:-auto/dhcp} (standard DHCP configuration will be used)."
fi

# bootmode
if [ -d "/sys/firmware/efi" ]; then
    log_info "Detected UEFI boot mode."
    BOOT_MODE="UEFI"
else
    log_info "Detected BIOS legacy boot mode."
    BOOT_MODE="BIOS"
fi

# url
CHR_URL="https://download.mikrotik.com/routeros/${ROS_VERSION}/chr-${ROS_VERSION}.img.zip"
CONTAINER_URL="https://download.mikrotik.com/routeros/${ROS_VERSION}/container-${ROS_VERSION}.npk"

# download chr.img
log_info "Downloading RouterOS CHR ${ROS_VERSION} Image..."
wget -N "$CHR_URL" 2>&1 || {
    log_error "Failed to download CHR Image"
    exit 1
}

# download Container
CONTAINER_DOWNLOAD_FAILED=false
log_info "Downloading RouterOS CHR ${ROS_VERSION} Container Package..."
wget -N "$CONTAINER_URL" 2>&1 || {
    log_warn "Failed to download container package"
    CONTAINER_DOWNLOAD_FAILED=true
}

# unzip img
log_info "Extracting RouterOS CHR Image..."
gunzip -c "chr-${ROS_VERSION}.img.zip" > "chr.img" || {
    log_error "Failed to extract CHR Image"
    exit 1
}

# UEFI Images Convert
if [ -d "/sys/firmware/efi" ]; then
    # install tools
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
        log_error "Unsupported Linux distribution"
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
    mkdir /tmp/chr-bios/
    mkdir /tmp/chr-efi/
    mount /dev/nbd0p1 /tmp/chr-bios/
    mount /dev/nbd1p1 /tmp/chr-efi/
    rsync -a /tmp/chr-bios/ /tmp/chr-efi/
    umount /dev/nbd0p1
    umount /dev/nbd1p1

    # Disconnect ndb
    qemu-nbd -d /dev/nbd0
    qemu-nbd -d /dev/nbd1
    sleep 2

    # Convert images
    qemu-img convert -f qcow2 -O raw chr-efi.qcow2 chr.img
fi

# detect disk
detect_disk() {
    # lsblk
    local disk1=$(lsblk -d -n -o NAME | grep -v "loop" | head -1)
    if [ -n "$disk1" ]; then
        echo "/dev/$disk1"
        return 0
    fi
    # fdisk
    local disk2=$(fdisk -l | grep "^Disk /dev" | grep -v "^Disk /dev/loop" | cut -d' ' -f2 | tr -d ':' | head -1)
    if [ -n "$disk2" ]; then
        echo "$disk2"
        return 0
    fi
    # find
    local disk3=$(find /dev/sd* -type b 2>/dev/null | grep -v "loop" | head -1)
    if [ -n "$disk3" ]; then
        echo "$disk3"
        return 0
    fi
    return 1
}
DISK_DEVICE=$(detect_disk)

# Operation continue
echo
echo -e "${RED}THIS WILL COMPLETELY DESTROY ALL DATA ON ($DISK_DEVICE)!!!${NC}"
read -p "Are you sure? Type 'Y' to continue: " confirmation
confirmation=$(echo "$confirmation" | tr '[:lower:]' '[:upper:]')
if [ "$confirmation" != "Y" ]; then
    log_info "Operation cancelled by user."
    exit 0
fi

# Mount image
log_info "Mounting image..."
umount /mnt 2>/dev/null || true
mkdir -p /mnt
LOOP_DEVICE=$(losetup -f --show chr.img)
mount -o loop,offset=33571840 $LOOP_DEVICE /mnt || {
    log_error "Failed to mount image"
    exit 1
}

# autorun
log_info "Writing autorun script..."
cat > /mnt/rw/autorun.scr <<EOF
/ip service set telnet disabled=yes
/ip service set ftp disabled=yes
/ip service set www disabled=yes
/ip service set ssh disabled=yes
/ip service set api disabled=yes
/ip service set api-ssl disabled=yes
/user set admin password=$admin_password
/system package enable container
EOF

# Add static IP configuration if gateway is 10.0.0.1
if [ "$GATEWAY" = "10.0.0.1" ]; then
    log_info "Appending 10.0.0.1 gateway configuration to autorun.scr..."
    cat >> /mnt/rw/autorun.scr <<EOF
/ip address add address=${IP_ADDR}/32 network=10.0.0.1 interface=ether1
/ip route add dst-address=0.0.0.0/0 gateway=10.0.0.1
EOF
fi

# rosmode
log_info "Writing rosmode message..."
echo -e -n "\x4d\x32\x01\x00\x00\x29\x0b\x4d\x32\x1c\x00\x00\x01\x0a\x00\x00\x09\x00" > /mnt/rw/rosmode.msg

# install container
if [ "${CONTAINER_DOWNLOAD_FAILED:-false}" = false ]; then
    log_info "Installing container package..."
    mkdir -p /mnt/var/pdb/container
    mv -f container-${ROS_VERSION}.npk /mnt/var/pdb/container/image
else
    log_warn "Skipping container package installation"
fi

# Unmount image
log_info "Unmounting image..."
umount /mnt

# write
log_info "Writing image to disk ($DISK_DEVICE). This may take several minutes..."
dd if=chr.img of=$DISK_DEVICE bs=4M oflag=sync status=progress || {
    log_error "Failed to write image to disk"
    exit 1
}

log_info "System will reboot in 5 seconds..."
echo "=================================================="
echo "RouterOS CHR ${ROS_VERSION} Installation completed successfully!"
echo "user: admin"
echo "password: (your set password)"
if [ "$GATEWAY" = "10.0.0.1" ]; then
    echo "ip: ${IP_ADDR}/32 (gateway: 10.0.0.1)"
fi
echo "=================================================="

sleep 1

echo 1 > /proc/sys/kernel/sysrq
echo b > /proc/sysrq-trigger
