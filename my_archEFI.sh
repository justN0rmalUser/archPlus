#!/bin/bash

# =============================================================================
# Arch Linux Fast Install
# Быстрая установка Arch Linux + LUKS шифрование
# =============================================================================

## ╔═════════════════════════════════════════════════════════════════════════════╗
## ║ Часть 01 - установка ф-ий логгирования; корректное время и настройка локали ║
## ╚═════════════════════════════════════════════════════════════════════════════╝

set -e  # Прервать выполнение при ошибке

# Некоторые глобальные переменные
DISK=/dev/sda
SWAP_SPACE=17

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

LOG_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

LOG_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

LOG_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

LOG_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# приветствие
echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║     Arch Linux Fast Install v3.2.0 (UEFI) - 2025-2026              ║"
echo "║     Базовая установка системы с опциональным LUKS шифрованием      ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# время и клава
echo "📋 Настройка клавиатуры и шрифта..."
loadkeys ru && setfont cyr-sun16

echo "⏰ Синхронизация системных часов..."
timedatectl set-ntp true && hwclock --systohc

## ╔═══════════════════════════╗
## ║ Часть 02 - разметка диска ║
## ╚═══════════════════════════╝

# предупреждалка
echo ""
echo "╔═════════════════════════════════════════════╗"
echo "║ ⚠️ ВНИМАНИЕ! СКРИПТ ЗАТРЕТ ДИСК /dev/sda    ║"
echo "║    Если у вас ценные данные - СОХРАНИТЕ ИХ! ║"
echo "╚═════════════════════════════════════════════╝"
echo ""
read -p "Продолжить установку? (yes/no): " confirm
if [[ $confirm != "yes" ]]; then
    LOG_warn "Установка отменена."
    exit 1
fi

# разметка и затирка
sgdisk --zap-all $DISK

# efi
sgdisk  -n1:0:+1G \
        -t1:ef00 \
        $DISK

# swap раздел
sgdisk  -n2:0:+${SWAP_SPACE}G \
        -t2:8200 \
        $DISK

# основное дисковое пространство
sgdisk  -n3:0:0 \
        -t3:8300 \
        $DISK

# установка файловых систем
mkfs.fat -F32 ${DISK}1

mkswap ${DISK}2 && swapon ${DISK}2

# Создание LUKS-контейнера
LOG_info "Создание LUKS2 контейнера..."

cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    "${DISK}3"

cryptsetup open "${DISK}3" cryptroot

# Форматирование Btrfs
mkfs.btrfs /dev/mapper/cryptroot

# Создание подтомов
mount /dev/mapper/cryptroot /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@snapshots

umount /mnt

OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"

mount -o subvol=@,$OPTS /dev/mapper/cryptroot /mnt

mkdir -p /mnt/{boot,.snapshots}

mount -o subvol=@snapshots,$OPTS \
    /dev/mapper/cryptroot \
    /mnt/.snapshots

mount "${DISK}1" /mnt/boot

LOG_info "Разметка прошла успешно"

## ╔══════════════════════════════════════════╗
## ║ Часть 03 - установка системы и настройка ║
## ╚══════════════════════════════════════════╝

echo ""
echo "╔══════════════════════════════════╗"
echo "║ Установка системы и её настройка ║"
echo "╚══════════════════════════════════╝"
echo ""

# Зеркала (опционально)
# reflector --country Russia,Germany --age 12 --protocol https --latest 15 --sort rate --save /etc/pacman.d/mirrorlist

echo "⬇️  Загрузка и установка пакетов..." # Базовые пакеты (для Intel, для AMD замените intel-ucode на amd-ucode)
pacstrap -K /mnt \
    base base-devel linux-zen linux-zen-headers linux-firmware \
    grub efibootmgr cryptsetup lvm2 \
    btrfs-progs \
    snapper grub-btrfs inotify-tools \
    networkmanager iwd \
    intel-ucode sudo pipewire pipewire-pulse pipewire-alsa pavucontrol wireplumber \
    nvidia-open nvidia-utils nvidia-settings \
    nano wget --noconfirm

LOG_info "✅ Базовая система установлена"

# Генерация fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Для шифрования добавляем crypttab
echo "🔐 Настройка crypttab..."

CRYPT_UUID=$(blkid -s UUID -o value ${DISK}3) # Получаем UUID зашифрованного раздела
echo "cryptlvm UUID=$CRYPT_UUID none luks" >> /mnt/etc/crypttab
LOG_success "crypttab настроен"

# Вход в систему
arch-chroot /mnt
