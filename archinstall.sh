#!/usr/bin/env bash

# Wifi
network() {
  while ! ping -c 1 example.com &>/dev/null; do
    echo -e "No network connection detected.\n"

    while true; do
      echo "Would you like to connect using Wi-Fi? [Y/N]: "
      read -r choice

      case "$choice" in
        [yY] | [yY][eE][sS])
          while true; do
            iwctl station list
            echo "Please enter station name: "
            read -r station

            echo -e "\nPlease enter network name (SSID): "
            read -r netssid

            echo -e "\nEnter password: "
            read -r netpwd

            echo -e "\nAttempting to connect to $netssid..."

            # Connect to the Wi-Fi network
            # iwctl --passphrase "$netpwd" station "$station" connect "$netssid"
            if iwctl --passphrase "$netpwd" station "$station" connect "$netssid"; then
              echo -e "\nConnected to $netssid."
              break  # Exit the inner loop if connection is successful
            else
              echo -e "\nFailed to connect to $netssid. Please try again."
              sleep 5
              echo -e "\033c"
            fi
          done
          break
          ;;
        [nN] | [nN][oO])
          echo -e "\nRechecking network..."
          break
          ;;
        *)
          echo -e "\nInvalid option. Please enter [Yes/No]."
          ;;
      esac
    done
    # Wait a few seconds before checking the connection again
    sleep 2
  done

  echo -e "Network connection established.\n"
}


timezone() {
  # Get the current timezone
  time_zone=$(curl --fail -s https://ipapi.co/timezone)
  echo "System detected your timezone as '$time_zone'"
  echo "Is this correct? [Yes/No]: "
  read -r answer

  case "$answer" in
    [yY] | [yY][eE][sS])
      TIMEZONE="$time_zone"
      echo "Timezone set to '${TIMEZONE}'"
      ;;
    [nN] | [nN][oO])
      echo "Please enter your desired timezone (e.g., Europe/London): "
      read -r new_timezone
      TIMEZONE="$new_timezone"
      echo "Timezone set to '${TIMEZONE}'"
      ;;
    *)
      echo "Invalid option. Please enter [Yes/No]."
      timezone
      ;;
  esac
}

# Format and mount partitions
format_and_mount() {
  echo -e "\033c"
  echo -ne "
-------------------------------------------------------------------------
                    Formating Disk
-------------------------------------------------------------------------
"

  # Ensure everything is unmounted
  umount -A --recursive /mnt

  while true; do
    lsblk
    echo -e "\nEnter the drive name (e.g., vda / sda / nvme0n1): "
    read -r drive
    DISK="/dev/$drive"

    # Check if the disk exists
    if [[ -b "$DISK" ]]; then
      break
    else
      echo "Error: Disk $DISK does not exist. Please enter a valid disk."
      echo -e "\033c"
    fi
    sleep 1
  done

  cfdisk $DISK
  # I usually create 2 gpt partitions
  # partition1 - boot /mnt/boot
  # partition2 - root /mnt
  echo -e "\033c"

  echo -ne "
-------------------------------------------------------------------------
                    Creating Filesystems
-------------------------------------------------------------------------
"
  sleep 2

  if [[ "${DISK}" =~ "nvme" ]]; then
    partition1=${DISK}p1
    partition2=${DISK}p2
  else
    partition1=${DISK}1
    partition2=${DISK}2
  fi

  # Create filesystems
  mkfs.fat -F32 "$partition1"
  mkfs.ext4 "$partition2"

  # Mount the filesystems
  mount "$partition2" /mnt
  mkdir -p /mnt/boot
  mount "$partition1" /mnt/boot
}

# Install base system
install_base_system() {
  vendor=$(lscpu | grep 'Vendor ID:' | awk '{print $3}')
  audio_card=$(lspci -k | grep -i -E 'audio|sound' | head -n 1 | awk '{print $5}')
  gpu=$(lspci | grep -i 'vga\|3d\|display')

  # Microcode
  if [ "$vendor" = "GenuineIntel" ]; then
    ucode="intel-ucode"
  elif [ "$vendor" = "AuthenticAMD" ]; then
    ucode="amd-ucode"
  else
    ucode=""
  fi

  # Graphics Drivers find and install
  # Check for Intel
  if [[ "$gpu" == *"Integrated Graphics Controller"* || "$gpu" == *"UHD Graphics"* ]]; then
    drv="mesa lib32-mesa vulkan-intel intel-media-driver libvdpau-va-gl libva-utils vdpauinfo"
    # Hardware video acceleration
    echo "LIBVA_DRIVER_NAME=iHD" >> /mnt/etc/environment
    echo "VDPAU_DRIVER=va_gl" >> /mnt/etc/environment

  # untested!
  # Check for NVIDIA
  # elif [[ "$gpu" == *"NVIDIA"* || "$gpu" == *"GeForce"* ]]; then
  #   drv="nvidia"
  # Check for AMD
  # elif [[ "$gpu" == *"Radeon"* || "$gpu" == *"AMD"* ]]; then
  #   drv="xf86-video-amdgpu"
  else
    drv=""
  fi

  pacstrap /mnt base base-devel linux-zen linux-zen-headers linux-firmware $ucode $drv zram-generator networkmanager nano

  genfstab -U -p /mnt >> /mnt/etc/fstab
  sed -i "/\/boot/ s/fmask=0022,dmask=0022/umask=0077/" /mnt/etc/fstab

  # Re-mount boot partition (Attempt)
  mount -o remount,rw /mnt/boot

  # [SWAP] ######################
  # Zram
  echo "[zram0]
compression-algorithm = zstd
zram-size = ram / 2
swap-priority = 100
fs-type = swap" > /mnt/usr/lib/systemd/zram-generator.conf

  # Swapfile
  # TOTAL_MEM=$(cat /proc/meminfo | grep -i 'memtotal' | grep -o '[[:digit:]]*')
  # if [[  $TOTAL_MEM -le 8000000 ]]; then
  #   mkswap -U clear --size 4G --file /mnt/swapfile
  #   swapon /mnt/swapfile
  #   echo "# /swapfile" >> /mnt/etc/fstab
  #   echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab # Add swap to fstab, so it KEEPS working after installation.
  # fi
  ###############################

  # Create the chroot script
  printf '%s\n' '#!/usr/bin/env bash

# Get Timezone
TIMEZONE="$1"
# Root
partition2="$2"
# CPU vendor
vendor="$3"
# Audio
audio_card="$4"

configure_system() {
  # Localization
  sed -i "s/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
  locale-gen
  echo "LANG=en_US.UTF-8" > /etc/locale.conf

  ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
  hwclock --systohc

  # I/O performance
  echo "# HDD
ACTION==\"add|change\", KERNEL==\"sd[a-z]*\", ATTR{queue/rotational}==\"1\", ATTR{queue/scheduler}=\"bfq\"

# SSD
ACTION==\"add|change\", KERNEL==\"sd[a-z]*|mmcblk[0-9]*\", ATTR{queue/rotational}==\"0\", ATTR{queue/scheduler}=\"mq-deadline\"

# NVMe SSD
ACTION==\"add|change\", KERNEL==\"nvme[0-9]*\", ATTR{queue/rotational}==\"0\", ATTR{queue/scheduler}=\"none\"" > /etc/udev/rules.d/60-ioschedulers.rules

  # Adjustments for system performance and behavior
  echo "# The sysctl swappiness parameter determines the kernel'\''s preference for pushing anonymous pages or page cache to disk in memory-starved situations.
# A low value causes the kernel to prefer freeing up open files (page cache), a high value causes the kernel to try to use swap space,
# and a value of 100 means IO cost is assumed to be equal.
vm.swappiness = 100

# The value controls the tendency of the kernel to reclaim the memory which is used for caching of directory and inode objects (VFS cache).
# Lowering it from the default value of 100 makes the kernel less inclined to reclaim VFS cache (do not set it to 0, this may produce out-of-memory conditions)
#vm.vfs_cache_pressure=50

# Contains, as a bytes of total available memory that contains free pages and reclaimable
# pages, the number of pages at which a process which is generating disk writes will itself start
# writing out dirty data.
vm.dirty_bytes = 268435456

# page-cluster controls the number of pages up to which consecutive pages are read in from swap in a single attempt.
# This is the swap counterpart to page cache readahead. The mentioned consecutivity is not in terms of virtual/physical addresses,
# but consecutive on swap space - that means they were swapped out together. (Default is 3)
# increase this value to 1 or 2 if you are using physical swap (1 if ssd, 2 if hdd)
vm.page-cluster = 0

# Contains, as a bytes of total available memory that contains free pages and reclaimable
# pages, the number of pages at which the background kernel flusher threads will start writing out
# dirty data.
vm.dirty_background_bytes = 134217728

# This tunable is used to define when dirty data is old enough to be eligible for writeout by the
# kernel flusher threads.  It is expressed in 100'\''ths of a second.  Data which has been dirty
# in-memory for longer than this interval will be written out next time a flusher thread wakes up
# (Default is 3000).
#vm.dirty_expire_centisecs = 3000

# The kernel flusher threads will periodically wake up and write old data out to disk.  This
# tunable expresses the interval between those wakeups, in 100'\''ths of a second (Default is 500).
vm.dirty_writeback_centisecs = 1500

# This action will speed up your boot and shutdown, because one less module is loaded. Additionally disabling watchdog timers increases performance and lowers power consumption
# Disable NMI watchdog
kernel.nmi_watchdog = 0

# Enable the sysctl setting kernel.unprivileged_userns_clone to allow normal users to run unprivileged containers.
kernel.unprivileged_userns_clone = 1

# To hide any kernel messages from the console
kernel.printk = 3 3 3 3

# Restricting access to kernel pointers in the proc filesystem
kernel.kptr_restrict = 2

# Disable Kexec, which allows replacing the current running kernel.
kernel.kexec_load_disabled = 1

# Increase the maximum connections
# The upper limit on how many connections the kernel will accept (default 4096 since kernel version 5.6):
net.core.somaxconn = 8192

# Enable TCP Fast Open
# TCP Fast Open is an extension to the transmission control protocol (TCP) that helps reduce network latency
# by enabling data to be exchanged during the sender'\''s initial TCP SYN [3].
# Using the value 3 instead of the default 1 allows TCP Fast Open for both incoming and outgoing connections:
net.ipv4.tcp_fastopen = 3

# Enable BBR3
# The BBR3 congestion control algorithm can help achieve higher bandwidths and lower latencies for internet traffic
net.ipv4.tcp_congestion_control = bbr

# TCP SYN cookie protection
# Helps protect against SYN flood attacks. Only kicks in when net.ipv4.tcp_max_syn_backlog is reached:
net.ipv4.tcp_syncookies = 1

# TCP Enable ECN Negotiation by default
net.ipv4.tcp_ecn = 1

# TCP Reduce performance spikes
# Refer https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux_for_real_time/7/html/tuning_guide/reduce_tcp_performance_spikes
net.ipv4.tcp_timestamps = 0

# Increase netdev receive queue
# May help prevent losing packets
net.core.netdev_max_backlog = 16384

# Disable TCP slow start after idle
# Helps kill persistent single connection performance
net.ipv4.tcp_slow_start_after_idle = 0

# Protect against tcp time-wait assassination hazards, drop RST packets for sockets in the time-wait state. Not widely supported outside of Linux, but conforms to RFC:
net.ipv4.tcp_rfc1337 = 1

# Set the maximum watches on files
fs.inotify.max_user_watches = 524288

# Set size of file handles and inode cache
fs.file-max = 2097152

# Increase writeback interval for xfs
fs.xfs.xfssyncd_centisecs = 10000

# Disable core dumps
kernel.core_pattern = /dev/null" > /usr/lib/sysctl.d/99-arch-settings.conf

  # Blacklist configuration
  echo -e "blacklist iTCO_wdt\n\nblacklist sp5100_tco" > /etc/modprobe.d/blacklist.conf

  # Audio power save
  case "$audio_card" in
    *Intel*)
      echo "options snd_hda_intel power_save=1" > /etc/modprobe.d/audio-powersave.conf
      ;;
    *)
      echo "options snd_ac97_codec power_save=1" > /etc/modprobe.d/audio-powersave.conf
      ;;
  esac

  # Make adjustments in pacman.conf:
  # - add ILoveCandy
  # - enable Color and ParallelDownloads
  # - enable multilib
  sed -i \
      -e "/^#Color/a ILoveCandy" \
      -e "s|^#Color|Color|" \
      -e "/^#VerbosePkgLists/a DisableDownloadTimeout" \
      -e "s|^#ParallelDownloads = 5|ParallelDownloads = 3|" \
      -e "s|^#\(\[multilib\]\)|\1|" \
      -e "/\[multilib\]/,/^\[/ s/^# \?Include/Include/" /etc/pacman.conf

  # Add sudo rights
  sed -i "/^# Defaults\!PKGMAN \!intercept, \!log_subcmds/a ##tmp" /etc/sudoers
  sed -i "/^##tmp/a Defaults rootpw" /etc/sudoers
  sed -i "/^Defaults rootpw/a Defaults pwfeedback" /etc/sudoers
  sed -i "/^Defaults pwfeedback/a Defaults insults" /etc/sudoers
  sed -i "s|^##tmp|##|" /etc/sudoers
  sed -i "s|^# %wheel ALL=(ALL:ALL) ALL|%wheel ALL=(ALL:ALL) ALL|" /etc/sudoers

  # Hide fsck messages during boot
  sed -i "s/^HOOKS=.*$/HOOKS=(base systemd autodetect microcode kms modconf keyboard keymap sd-vconsole block filesystems)/" /etc/mkinitcpio.conf

  # Fix vconsole error messages
  if [ ! -f /etc/vconsole.conf ]; then
    echo -e "## This is the fallback vconsole configuration provided by systemd.\n\n#KEYMAP=us" > /etc/vconsole.conf
  fi

  # Fix watchdog error messages
  sed -i "s/^#RebootWatchdogSec=10min$/RebootWatchdogSec=0/" /etc/systemd/system.conf

  # Makepkg Options
  sed -i "s/^OPTIONS=.*$/OPTIONS=(strip docs !libtool !staticlibs emptydirs zipman purge !debug lto !autodeps)/" /etc/makepkg.conf

  echo -e "\033c"
  echo -e "Applied System Configurations\n"

  echo "Please enter hostname: "
  read -r hostname
  echo "$hostname" > /etc/hostname

  # Hosts configuration
  echo -e "##
# Host Database
#
# localhost is used to configure the loopback interface
# when the system is booting.  Do not change this entry.
##
127.0.0.1       localhost
::1             localhost ip6-localhost ip6-loopback
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
127.0.1.1       $hostname.localdomain $hostname" > /etc/hosts

  # Users22B2-45B4
  echo -e "\nRoot Password"
  passwd

  echo -e "\nPlease enter username: "
  read -r username
  useradd -mG wheel -s /bin/bash "$username"
  passwd "$username"

  # Services
  # TRIM for SSD
  systemctl enable fstrim.timer NetworkManager
  # zram
  systemctl daemon-reload
  systemctl start /dev/zram0
  swapon
  sleep 5

  echo -e "\033c"

  echo "Boot Loader (Systemd Boot)"
  bootctl install
  echo "title Arch Linux" >> /boot/loader/entries/arch.conf
  echo "linux /vmlinuz-linux-zen" >> /boot/loader/entries/arch.conf
  if [ "$vendor" = "GenuineIntel" ]; then
    echo "initrd /intel-ucode.img" >> /boot/loader/entries/arch.conf
  elif [ "$vendor" = "AuthenticAMD" ]; then
    echo "initrd /amd-ucode.img" >> /boot/loader/entries/arch.conf
  fi
  echo "initrd /initramfs-linux-zen.img" >> /boot/loader/entries/arch.conf
  echo "options root=PARTUUID=$(blkid -s PARTUUID -o value $partition2) rw zswap.enabled=0 nowatchdog loglevel=3 quiet" >> /boot/loader/entries/arch.conf

  mkinitcpio -P
  pacman -Syu --noconfirm

  echo -ne "
  -------------------------------------------------------------------------
                  Done - Please Eject Install Media and Reboot
  -------------------------------------------------------------------------
  "
}
configure_system' > /mnt/setup.sh

  chmod +x /mnt/setup.sh
  arch-chroot /mnt ./setup.sh "$TIMEZONE" "$partition2" "$vendor" "$audio_card"
  exit
}

main() {
  echo -e "\033c"
  cat << EOF
-------------------------------------------------------------------------
                    Automated Arch Linux Installer
-------------------------------------------------------------------------

EOF

  timedatectl set-ntp true
  network
  timezone
  format_and_mount
  install_base_system
  exit
}

main
