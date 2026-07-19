#!/usr/bin/env bash
# shellcheck disable=SC2034

# Central installation settings. This file is sourced by the live ISO and
# chroot stages; it must not contain passwords or LUKS keys.

INSTALL_DISK="/dev/sda"
EFI_PART="${INSTALL_DISK}1"
SWAP_PART="${INSTALL_DISK}2"
ROOT_PART="${INSTALL_DISK}3"

EFI_SIZE_GIB=1
SWAP_SIZE_GIB=4
MIN_DISK_SIZE_GIB=16

TARGET_MOUNT="/mnt"
ROOT_MAPPER_NAME="cryptroot"
SWAP_MAPPER_NAME="cryptswap"
ROOT_MAPPER="/dev/mapper/${ROOT_MAPPER_NAME}"
SWAP_MAPPER="/dev/mapper/${SWAP_MAPPER_NAME}"

HOSTNAME="gnu-not-unix"
USERNAME="d8n"
TIMEZONE="Europe/Moscow"
LOCALE="ru_RU.UTF-8"
KEYMAP="ru"
CONSOLE_FONT="cyr-sun16"

BTRFS_MOUNT_OPTIONS="noatime,compress=zstd:1,space_cache=v2,discard=async"

BASE_PACKAGES=(
    base
    base-devel
    linux-zen
    linux-zen-headers
    linux-firmware
    intel-ucode
    dkms
    nvidia-open-dkms
    nvidia-utils
    nvidia-settings
    grub
    efibootmgr
    cryptsetup
    btrfs-progs
    snapper
    snap-pac
    grub-btrfs
    inotify-tools
    networkmanager
    iwd
    sudo
    pipewire
    pipewire-alsa
    pipewire-pulse
    pipewire-jack
    wireplumber
    pavucontrol
    nano
    wget
    dosfstools
    gptfdisk
    ttf-liberation
    ttf-dejavu
    noto-fonts
    noto-fonts-cjk
)
