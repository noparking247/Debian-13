#!/bin/bash
# Debian 13 (Trixie) ZFS root installer (native ZFS, optional encryption)
#
# - Run from a Debian 13 LIVE SYSTEM, as root.
# - Root on ZFS (bpool + rpool)
# - Optional native ZFS encryption on rpool (no LUKS)
# - Locale: en_CA.UTF-8
# - Timezone: America/Toronto
# - Keyboard: us
# - Prompts for hostname + domain
# - Root SSH enabled
# - Installs "standard system utilities" + "SSH server" (like netinst)
# - Layout selectable:
#     1) Debian-style:
#          rpool/ROOT/debian  -> /
#          bpool/BOOT/debian  -> /boot
#     2) Proxmox-style:
#          rpool/ROOT/pve-1   -> /
#          bpool/BOOT/pve-1   -> /boot
#          rpool/data         -> /var/lib/vz
#
# WARNING: This is DESTRUCTIVE on the selected disks.

set -euo pipefail

################################################################################
# 0. Sanity checks
################################################################################

if [[ "$(id -u)" -ne 0 ]]; then
  echo "This script must be run as root. Use:  sudo -i  then  ./zfs-install.sh"
  exit 1
fi

if ! command -v apt >/dev/null 2>&1; then
  echo "apt not found. This script must be run from a full Debian live system."
  exit 1
fi

KERNEL_REL="$(uname -r)"

echo
echo "Running on Debian live system, kernel: ${KERNEL_REL}"

################################################################################
# 1. Ensure contrib is enabled so ZFS packages exist
################################################################################

echo
echo "--- Ensuring APT has contrib enabled for ZFS ---"

if ! apt-cache show zfsutils-linux >/dev/null 2>&1; then
  cat >/etc/apt/sources.list.d/zfs-contrib.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF
  echo "Added /etc/apt/sources.list.d/zfs-contrib.list with contrib enabled."
fi

echo "Updating APT package index..."
apt update

################################################################################
# 2. Check required packages in LIVE environment
################################################################################

echo
echo "--- Checking for required live-environment packages ---"

REQUIRED_PKGS=(
  zfsutils-linux
  zfs-dkms
  "linux-headers-${KERNEL_REL}"
  debootstrap
  gdisk
  dosfstools
  parted
)

MISSING_PKGS=()

for pkg in "${REQUIRED_PKGS[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PKGS+=("$pkg")
  fi
done

if ((${#MISSING_PKGS[@]} > 0)); then
  echo "The following required packages are missing in the live environment:"
  printf ' - %s\n' "${MISSING_PKGS[@]}"
  echo
  read -rp "Install them automatically? (y/N): " INSTALL_CONFIRM
  INSTALL_CONFIRM=${INSTALL_CONFIRM,,}

  if [[ "$INSTALL_CONFIRM" == "y" ]]; then
    echo "--- Installing missing required packages ---"
    apt install -y "${MISSING_PKGS[@]}"
  else
    echo "ERROR: Cannot proceed without required packages."
    exit 1
  fi
else
  echo "All required packages are present."
fi

echo
echo "--- Ensuring ZFS kernel module is loaded ---"
if ! modprobe zfs 2>/dev/null; then
  echo "ZFS kernel module could not be loaded."
  echo "Check that zfs-dkms built successfully and that linux-headers-${KERNEL_REL} is installed."
  exit 1
fi
echo "ZFS module loaded successfully."

################################################################################
# 3. Hostname / domain
################################################################################

echo
echo "--- Hostname / Domain configuration ---"
read -rp "Enter hostname (short, e.g. 'debian-zfs'): " HOSTNAME
read -rp "Enter domain name (e.g. 'example.com'; leave blank for none): " DOMAIN || true
FQDN="$HOSTNAME"
if [[ -n "${DOMAIN:-}" ]]; then
  FQDN="${HOSTNAME}.${DOMAIN}"
fi

################################################################################
# 4. Dataset layout choice
################################################################################

echo
echo "--- Dataset Layout ---"
echo "1) Debian-style:"
echo "     rpool/ROOT/debian  -> /"
echo "     bpool/BOOT/debian  -> /boot"
echo "2) Proxmox-style:"
echo "     rpool/ROOT/pve-1   -> /"
echo "     bpool/BOOT/pve-1   -> /boot"
echo "     rpool/data         -> /var/lib/vz"
read -rp "Choose layout (1 = Debian, 2 = Proxmox) [1]: " LAYOUT_CHOICE
LAYOUT_CHOICE=${LAYOUT_CHOICE:-1}

LAYOUT="debian"
ROOT_FS=""
BOOT_FS=""
EXTRA_DATASET=""

case "$LAYOUT_CHOICE" in
  2)
    LAYOUT="proxmox"
    ROOT_FS="rpool/ROOT/pve-1"
    BOOT_FS="bpool/BOOT/pve-1"
    EXTRA_DATASET="rpool/data"
    ;;
  *)
    LAYOUT="debian"
    ROOT_FS="rpool/ROOT/debian"
    BOOT_FS="bpool/BOOT/debian"
    EXTRA_DATASET=""
    ;;
esac

echo
echo "Using layout: $LAYOUT"
echo "Root dataset: $ROOT_FS"
echo "Boot dataset: $BOOT_FS"
if [[ -n "$EXTRA_DATASET" ]]; then
  echo "Extra dataset: $EXTRA_DATASET (will be mounted at /var/lib/vz)"
fi

################################################################################
# 5. Disk selection
################################################################################

DISKS=$(lsblk -ndo NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{print $1}')

if [[ -z "$DISKS" ]]; then
  echo "No physical disks found."
  exit 1
fi

echo
echo "--- Available disks ---"

COUNTER=1
declare -A DISK_MAP
for DISK in $DISKS; do
  if [[ -b "/dev/$DISK" ]]; then
    DISK_INFO=$(lsblk -ndo NAME,SIZE,MODEL "/dev/$DISK")
    echo "$COUNTER) $DISK_INFO"
    DISK_MAP[$COUNTER]="/dev/$DISK"
    ((COUNTER++))
  fi
done

if ((${#DISK_MAP[@]} == 0)); then
  echo "No valid disks found."
  exit 1
fi

echo
echo "Enter the numbers of the disks you want to select, separated by spaces (e.g., 1 3):"
read -r USER_SELECTION

SELECTED_DISKS=()
for NUM in $USER_SELECTION; do
  if [[ -v DISK_MAP[$NUM] ]]; then
    SELECTED_DISKS+=("${DISK_MAP[$NUM]}")
  else
    echo "Warning: Number '$NUM' is not valid and will be ignored." >&2
  fi
done

echo
if ((${#SELECTED_DISKS[@]} == 0)); then
  echo "No disks selected."
  exit 1
else
  echo "You have selected the following disks:"
  for DISK in "${SELECTED_DISKS[@]}"; do
    echo " - $DISK"
  done
fi

echo
echo "**WARNING**: Subsequent operations on the selected disks are **DESTRUCTIVE** and will erase ALL data."
read -rp "Are you sure you want to proceed? (y/N): " CONFIRMATION
CONFIRMATION=${CONFIRMATION,,}
if [[ "$CONFIRMATION" != "y" ]]; then
  echo "Operation cancelled."
  exit 0
fi

################################################################################
# 6. Boot type & encryption & RAID
################################################################################

echo
echo "Choose booting type:"
echo "1) BIOS (Legacy)"
echo "2) UEFI"
read -rp "Enter your choice (1 or 2): " BOOT_CHOICE

echo
echo "Do you want to use ZFS native encryption for the main pool (rpool)?"
read -rp "Enter 'y' for yes, 'n' for no (y/N): " ENCRYPT_CHOICE
ENCRYPT_CHOICE=${ENCRYPT_CHOICE,,}

RAID_TYPE=""

if ((${#SELECTED_DISKS[@]} > 1)); then
  echo
  echo "You have selected multiple disks. How do you want to configure the ZFS pool?"
  echo "1) Simple Mirror (raid1)"
  echo "2) RAID10 (striped mirrors)"
  echo "3) RAIDZ1"
  echo "4) RAIDZ2"
  echo "5) RAIDZ3"
  read -rp "Enter your choice (1-5): " RAID_CHOICE
  case "$RAID_CHOICE" in
    1) RAID_TYPE="mirror" ;;
    2) RAID_TYPE="raid10" ;;
    3) RAID_TYPE="raidz1" ;;
    4) RAID_TYPE="raidz2" ;;
    5) RAID_TYPE="raidz3" ;;
    *) echo "Invalid RAID choice. Defaulting to mirror." >&2
       RAID_TYPE="mirror"
       ;;
  esac
fi

################################################################################
# 7. Partitioning
################################################################################

for disk_path in "${SELECTED_DISKS[@]}"; do
  echo
  echo "Processing disk: $disk_path"

  wipefs -a "$disk_path" || true
  blkdiscard -f "$disk_path" || true
  sgdisk --zap-all "$disk_path" || true
  dd if=/dev/zero of="$disk_path" count=100 bs=512 status=none || true
  sgdisk -Z "$disk_path"

  case "$BOOT_CHOICE" in
    1)
      echo "Configuring for BIOS (Legacy) booting on $disk_path..."
      sgdisk -a1 -n1:24K:+1000K -t1:EF02 "$disk_path"   # BIOS boot
      ;;
    2)
      echo "Configuring for UEFI booting on $disk_path..."
      sgdisk -n2:1M:+512M -t2:EF00 "$disk_path"         # EFI
      ;;
    *)
      echo "Invalid booting choice. Aborting."
      exit 1
      ;;
  esac

  echo "Creating data partition (Linux ZFS for bpool) on $disk_path..."
  sgdisk -n3:0:+1G -t3:BF01 "$disk_path"               # bpool

  echo "Creating data partition (Linux ZFS for rpool) on $disk_path..."
  sgdisk -n4:0:0 -t4:BF00 "$disk_path"                 # rpool
done

################################################################################
# 8. Build device lists for pools
################################################################################

BPOOL_DEVICES=""
RPOOL_DEVICES=""

BPOOL_PARTITION_NUMBER=3
RPOOL_PARTITION_NUMBER=4
EFI_PARTITION_NUMBER=2

if ((${#SELECTED_DISKS[@]} == 1)); then
  BPOOL_DEVICES="${SELECTED_DISKS[0]}${BPOOL_PARTITION_NUMBER}"
  RPOOL_DEVICES="${SELECTED_DISKS[0]}${RPOOL_PARTITION_NUMBER}"
else
  case "$RAID_TYPE" in
    mirror)
      BPOOL_DEVICES="mirror"
      RPOOL_DEVICES="mirror"
      for disk_path in "${SELECTED_DISKS[@]}"; do
        BPOOL_DEVICES+=" ${disk_path}${BPOOL_PARTITION_NUMBER}"
        RPOOL_DEVICES+=" ${disk_path}${RPOOL_PARTITION_NUMBER}"
      done
      ;;
    raid10)
      if (( ${#SELECTED_DISKS[@]} % 2 != 0 )); then
        echo "Warning: RAID10 with an odd number of disks is not ideal." >&2
      fi
      local_bpool=""
      local_rpool=""
      for ((i = 0; i < ${#SELECTED_DISKS[@]}; i += 2)); do
        d1="${SELECTED_DISKS[$i]}"
        d2="${SELECTED_DISKS[$((i+1))]:-}"
        if [[ -n "$d2" ]]; then
          local_bpool+=" mirror ${d1}${BPOOL_PARTITION_NUMBER} ${d2}${BPOOL_PARTITION_NUMBER}"
          local_rpool+=" mirror ${d1}${RPOOL_PARTITION_NUMBER} ${d2}${RPOOL_PARTITION_NUMBER}"
        else
          local_bpool+=" ${d1}${BPOOL_PARTITION_NUMBER}"
          local_rpool+=" ${d1}${RPOOL_PARTITION_NUMBER}"
        fi
      done
      BPOOL_DEVICES=$(echo "$local_bpool" | xargs)
      RPOOL_DEVICES=$(echo "$local_rpool" | xargs)
      ;;
    raidz1|raidz2|raidz3)
      BPOOL_DEVICES="$RAID_TYPE"
      RPOOL_DEVICES="$RAID_TYPE"
      for disk_path in "${SELECTED_DISKS[@]}"; do
        BPOOL_DEVICES+=" ${disk_path}${BPOOL_PARTITION_NUMBER}"
        RPOOL_DEVICES+=" ${disk_path}${RPOOL_PARTITION_NUMBER}"
      done
      ;;
    *)
      echo "Unknown RAID type '$RAID_TYPE'."
      exit 1
      ;;
  esac
fi

################################################################################
# 9. Create ZFS pools
################################################################################

echo
echo "Creating bpool..."
zpool create -f \
  -o ashift=12 \
  -o autotrim=on \
  -o compatibility=grub2 \
  -o cachefile=/etc/zfs/zpool.cache \
  -O devices=off \
  -O acltype=posixacl \
  -O xattr=sa \
  -O compression=lz4 \
  -O normalization=formD \
  -O relatime=on \
  -O canmount=off \
  -O mountpoint=/boot \
  -R /mnt \
  bpool ${BPOOL_DEVICES}

echo

if [[ "$ENCRYPT_CHOICE" == "y" ]]; then
  echo "Creating encrypted rpool..."
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O encryption=on \
    -O keylocation=prompt \
    -O keyformat=passphrase \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=/ \
    -R /mnt \
    rpool ${RPOOL_DEVICES}
else
  echo "Creating unencrypted rpool..."
  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O compression=lz4 \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=/ \
    -R /mnt \
    rpool ${RPOOL_DEVICES}
fi

################################################################################
# 10. Create datasets & debootstrap
################################################################################

echo
echo "Creating ZFS datasets..."

zfs create -o canmount=off -o mountpoint=none rpool/ROOT
zfs create -o canmount=off -o mountpoint=none bpool/BOOT

zfs create -o canmount=noauto -o mountpoint=/ "$ROOT_FS"
zfs mount "$ROOT_FS"

zfs create -o mountpoint=/boot "$BOOT_FS"

if [[ "$LAYOUT" == "proxmox" && -n "$EXTRA_DATASET" ]]; then
  zfs create -o mountpoint=/var/lib/vz "$EXTRA_DATASET"
fi

mkdir -p /mnt/run
mount -t tmpfs tmpfs /mnt/run
mkdir -p /mnt/run/lock

echo
echo "Running debootstrap for Debian 13 (trixie)..."
debootstrap trixie /mnt

mkdir -p /mnt/etc/zfs
cp /etc/zfs/zpool.cache /mnt/etc/zfs/zpool.cache

echo "$HOSTNAME" > /mnt/etc/hostname

cat > /mnt/etc/hosts <<EOF
127.0.0.1   localhost
127.0.1.1   $FQDN $HOSTNAME
::1         localhost ip6-localhost ip6-loopback
ff02::1     ip6-allnodes
ff02::2     ip6-allrouters
EOF

################################################################################
# 11. Configure target system outside chroot
################################################################################

echo
echo "Configuring APT sources for target system..."

cat > /mnt/etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free-firmware

deb http://security.debian.org/debian-security trixie-security main contrib non-free-firmware
deb-src http://security.debian.org/debian-security trixie-security main contrib non-free-firmware

deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF

cp /etc/network/interfaces /mnt/etc/network/interfaces 2>/dev/null || \
  echo "Note: /etc/network/interfaces not found in live system; configure networking later."

mount --make-private --rbind /dev  /mnt/dev
mount --make-private --rbind /proc /mnt/proc
mount --make-private --rbind /sys  /mnt/sys

################################################################################
# 12. Chroot configuration script
################################################################################

CHROOT_SCRIPT="/tmp/chroot_install_script.sh"

cat > "/mnt${CHROOT_SCRIPT}" <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail

BOOT_CHOICE="${BOOT_CHOICE:-}"
LAYOUT="${LAYOUT:-}"
ROOT_FS="${ROOT_FS:-}"
BOOT_FS="${BOOT_FS:-}"
EXTRA_DATASET="${EXTRA_DATASET:-}"
IFS=' ' read -r -a SELECTED_DISKS_ARRAY <<< "${SELECTED_DISKS_STR:-}"
EFI_PARTITION_NUMBER="${EFI_PARTITION_NUMBER:-2}"

echo "Inside chroot: updating APT..."
apt update

echo "Installing standard Debian base system and SSH server..."
apt install -y tasksel
tasksel install standard ssh-server

echo "Installing locale/timezone/keyboard packages..."
apt install -y console-setup locales tzdata keyboard-configuration

echo "en_CA.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
cat > /etc/default/locale <<'EOF_LOCALE'
LANG=en_CA.UTF-8
LC_ALL=en_CA.UTF-8
EOF_LOCALE
update-locale LANG=en_CA.UTF-8

ln -sf /usr/share/zoneinfo/America/Toronto /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

cat > /etc/default/keyboard <<'EOF_KBD'
XKBMODEL="pc105"
XKBLAYOUT="us"
XKBVARIANT=""
XKBOPTIONS=""
BACKSPACE="guess"
EOF_KBD
dpkg-reconfigure --frontend noninteractive keyboard-configuration
dpkg-reconfigure --frontend noninteractive console-setup

echo "Installing kernel and headers..."
apt install -y linux-headers-amd64 linux-image-amd64

echo "Installing zfs-initramfs in target..."
apt install -y zfs-initramfs
echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

echo "Installing GRUB (BIOS or UEFI)..."
if [[ "$BOOT_CHOICE" == "1" ]]; then
  apt install -y grub-pc
else
  apt install -y dosfstools grub-efi-amd64 shim-signed
fi

echo "Ensuring OpenSSH server is present..."
apt install -y openssh-server

echo "Set root password:"
passwd

echo "Creating zfs-import-bpool.service..."
mkdir -p /etc/systemd/system/zfs-import.target.wants/
cat > /etc/systemd/system/zfs-import-bpool.service <<'EOF_BPOOL'
[Unit]
DefaultDependencies=no
Before=zfs-import-scan.service
Before=zfs-import-cache.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/zpool import -N -o cachefile=none bpool
ExecStartPre=-/bin/mv /etc/zfs/zpool.cache /etc/zfs/preboot_zpool.cache
ExecStartPost=-/bin/mv /etc/zfs/preboot_zpool.cache /etc/zfs/zpool.cache

[Install]
WantedBy=zfs-import.target
EOF_BPOOL
systemctl enable zfs-import-bpool.service

echo "Enabling SSH login for root..."
sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
systemctl restart ssh || true

echo "Setting root dataset canmount flags..."
zfs set canmount=noauto "$ROOT_FS"
zfs set canmount=on "$ROOT_FS"
zfs mount "$ROOT_FS"
zfs set canmount=on "$BOOT_FS"
zfs mount "$BOOT_FS"
zfs mount -a

echo "Setting GRUB_CMDLINE_LINUX for ZFS root..."
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"root=ZFS=$ROOT_FS\"|" /etc/default/grub

echo "update-initramfs..."
update-initramfs -c -k all

echo "update-grub..."
update-grub

echo "Installing GRUB to disks..."
if [[ "$BOOT_CHOICE" == "1" ]]; then
  for d in "${SELECTED_DISKS_ARRAY[@]}"; do
    grub-install "$d"
  done
else
  mkdir -p /boot/efi
  for d in "${SELECTED_DISKS_ARRAY[@]}"; do
    efip="${d}${EFI_PARTITION_NUMBER}"
    if [[ -b "$efip" ]]; then
      mkdosfs -F32 -n EFI "$efip"
      mount "$efip" /boot/efi
      if ! grep -q "/boot/efi" /etc/fstab; then
        uuid=$(blkid -s UUID -o value "$efip")
        echo "UUID=${uuid} /boot/efi vfat defaults 0 0" >> /etc/fstab
      fi
      grub-install --target=x86_64-efi --efi-directory=/boot/efi \
                   --bootloader-id=debian --recheck "$d"
      umount /boot/efi
    fi
  done
fi

echo "Configuring ZFS cachefile..."
mkdir -p /etc/zfs/zfs-list.cache
zfs set cachefile=/etc/zfs/zpool.cache bpool
zfs set cachefile=/etc/zfs/zpool.cache rpool
zpool set cachefile=/etc/zfs/zpool.cache bpool
zpool set cachefile=/etc/zfs/zpool.cache rpool

zfs list -t filesystem -o name,mountpoint,canmount >/dev/null

if ls /etc/zfs/zfs-list.cache/* >/dev/null 2>&1; then
  sed -Ei 's|/mnt/?|/|' /etc/zfs/zfs-list.cache/*
fi

zfs set canmount=noauto "$ROOT_FS"
zfs set canmount=noauto bpool/BOOT || true

rm -f "$0"
CHROOT_EOF

chmod +x "/mnt${CHROOT_SCRIPT}"

echo
echo "Entering chroot to configure target system..."
chroot /mnt /usr/bin/env \
  BOOT_CHOICE="$BOOT_CHOICE" \
  LAYOUT="$LAYOUT" \
  ROOT_FS="$ROOT_FS" \
  BOOT_FS="$BOOT_FS" \
  EXTRA_DATASET="$EXTRA_DATASET" \
  SELECTED_DISKS_STR="${SELECTED_DISKS[*]}" \
  EFI_PARTITION_NUMBER="$EFI_PARTITION_NUMBER" \
  bash "${CHROOT_SCRIPT}"

################################################################################
# 13. Cleanup
################################################################################

echo
echo "Cleaning up mounts and exporting pools..."

mount | awk '$3 ~ "^/mnt" {print $3}' | sort -r | xargs -r umount || true
zfs umount -a || true

# Try to kill any processes keeping pools busy (defensive only)
grep '[p]ool' /proc/*/mounts 2>/dev/null | cut -d/ -f3 | sort -u | xargs -r kill || true
zpool export -a || true

echo
echo "Installation complete. You can now reboot."
echo "Remove the live medium and boot from the installed system."
