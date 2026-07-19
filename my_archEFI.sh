#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=false
ROOT_OPENED=false
SWAP_OWNED=false
TARGET_MOUNTED=false
INSTALL_FINISHED=false
LOG_FILE="/tmp/archplus-install-$(date +%Y%m%d-%H%M%S).log"

usage() {
    cat <<USAGE
Использование: sudo bash my_archEFI.sh [--dry-run] [--help]

Автоматически устанавливает Arch Linux на ${INSTALL_DISK}.

  --dry-run  показать итоговую схему и команды без проверки/изменения системы
  --help     показать эту справку

Обычный запуск БЕЗВОЗВРАТНО удаляет все данные с ${INSTALL_DISK}.
USAGE
}

parse_arguments() {
    while (($#)); do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                die "Неизвестный аргумент: $1"
                ;;
        esac
        shift
    done
}

print_dry_run() {
    cat <<PLAN
DRY RUN: никакие системные команды не выполняются.

Целевой диск: ${INSTALL_DISK}
  ${EFI_PART}   EFI System Partition, ${EFI_SIZE_GIB} GiB, FAT32, /efi
  ${SWAP_PART}  LUKS2 swap, ${SWAP_SIZE_GIB} GiB, без гибернации
  ${ROOT_PART}  LUKS2 (PBKDF2) + Btrfs, оставшееся пространство

Btrfs:
  @            /
  @snapshots   /.snapshots
  options      ${BTRFS_MOUNT_OPTIONS}

Система: linux-zen, NVIDIA open DKMS, GRUB, Snapper/grub-btrfs, niri
Пользователь: ${USERNAME}; hostname: ${HOSTNAME}; timezone: ${TIMEZONE}

Разрушающие команды, которые были бы выполнены только после подтверждения:
PLAN
    quote_command wipefs --all --force "${INSTALL_DISK}"
    quote_command sgdisk --zap-all "${INSTALL_DISK}"
    quote_command cryptsetup luksFormat "${ROOT_PART}"
    quote_command mkfs.btrfs "${ROOT_MAPPER}"
    quote_command pacstrap -K "${TARGET_MOUNT}" "${BASE_PACKAGES[@]}"
}

cleanup() {
    local exit_code=$?
    local cleanup_failed=false
    set +e

    if [[ "${TARGET_MOUNTED}" == true ]] && mountpoint -q "${TARGET_MOUNT}"; then
        log_info "Размонтирование ${TARGET_MOUNT}..."
        umount -R "${TARGET_MOUNT}" || cleanup_failed=true
    fi
    if [[ "${SWAP_OWNED}" == true ]] && cryptsetup status "${SWAP_MAPPER_NAME}" >/dev/null 2>&1; then
        cryptsetup close "${SWAP_MAPPER_NAME}" || cleanup_failed=true
    fi
    if [[ "${ROOT_OPENED}" == true ]] && cryptsetup status "${ROOT_MAPPER_NAME}" >/dev/null 2>&1; then
        cryptsetup close "${ROOT_MAPPER_NAME}" || cleanup_failed=true
    fi

    if [[ "${cleanup_failed}" == true ]]; then
        log_error "Не удалось полностью отключить mount/mapper-устройства; проверьте их вручную."
        if ((exit_code == 0)); then
            trap - EXIT
            exit 1
        fi
    elif ((exit_code != 0)); then
        log_error "Установка прервана (код ${exit_code}). Журнал: ${LOG_FILE}"
    elif [[ "${INSTALL_FINISHED}" == true ]]; then
        log_success "Установка завершена; файловые системы безопасно отключены."
    fi
}

preflight() {
    require_root
    require_commands \
        arch-chroot blkid blockdev btrfs cryptsetup curl findmnt genfstab \
        dd install loadkeys lsblk mkfs.btrfs mkfs.fat mkswap mount mountpoint \
        pacstrap sgdisk setfont timedatectl udevadm umount wipefs

    local required_file
    for required_file in \
        "${SCRIPT_DIR}/chroot.sh" \
        "${SCRIPT_DIR}/niri.sh" \
        "${SCRIPT_DIR}/config.sh" \
        "${SCRIPT_DIR}/lib/common.sh" \
        "${SCRIPT_DIR}/attach/bg.jpg"; do
        [[ -r "${required_file}" ]] || die "Не найден обязательный файл: ${required_file}"
    done

    [[ -d /sys/firmware/efi/efivars ]] || die "Live ISO загружен не в UEFI-режиме."
    [[ -b "${INSTALL_DISK}" ]] || die "Диск ${INSTALL_DISK} не найден."
    [[ "$(lsblk -dn -o RO "${INSTALL_DISK}" | tr -d ' ')" == "0" ]] || die "Диск доступен только для чтения."
    [[ ! -e "${ROOT_MAPPER}" ]] || die "Mapper ${ROOT_MAPPER} уже существует."
    [[ ! -e "${SWAP_MAPPER}" ]] || die "Mapper ${SWAP_MAPPER} уже существует."
    mountpoint -q "${TARGET_MOUNT}" && die "${TARGET_MOUNT} уже является точкой монтирования."

    if lsblk -nrpo MOUNTPOINT "${INSTALL_DISK}" | grep -q '[^[:space:]]'; then
        die "Один из разделов ${INSTALL_DISK} смонтирован. Сначала размонтируйте его."
    fi

    local disk_bytes min_bytes
    disk_bytes="$(blockdev --getsize64 "${INSTALL_DISK}")"
    min_bytes=$((MIN_DISK_SIZE_GIB * 1024 * 1024 * 1024))
    ((disk_bytes >= min_bytes)) || die "Диск должен быть не меньше ${MIN_DISK_SIZE_GIB} GiB."

    curl -fsSI --connect-timeout 10 https://archlinux.org/ >/dev/null \
        || die "Нет доступа к archlinux.org; проверьте сеть и DNS."
}

confirm_disk_erasure() {
    printf '\nЦелевой диск:\n'
    lsblk -d -o NAME,PATH,SIZE,MODEL,TRAN,RO "${INSTALL_DISK}"
    printf '\nТекущая разметка:\n'
    lsblk -o NAME,PATH,SIZE,FSTYPE,MOUNTPOINTS "${INSTALL_DISK}"
    printf '\nВНИМАНИЕ: все данные на %s будут уничтожены.\n' "${INSTALL_DISK}"
    printf 'Для продолжения введите точно: ERASE %s\n> ' "${INSTALL_DISK}"

    local confirmation
    IFS= read -r confirmation
    [[ "${confirmation}" == "ERASE ${INSTALL_DISK}" ]] || die "Подтверждение не совпало; установка отменена."
}

prepare_live_environment() {
    # GRUB reads the LUKS passphrase with a US keymap. Creating it with the
    # same layout prevents an unbootable passphrase/key-position mismatch.
    loadkeys us
    setfont "${CONSOLE_FONT}"
    timedatectl set-ntp true
}

partition_disk() {
    log_info "Очистка сигнатур и создание GPT..."
    wipefs --all --force "${INSTALL_DISK}"
    sgdisk --zap-all "${INSTALL_DISK}"
    sgdisk \
        --new=1:0:+${EFI_SIZE_GIB}G --typecode=1:ef00 --change-name=1:EFI \
        --new=2:0:+${SWAP_SIZE_GIB}G --typecode=2:8309 --change-name=2:cryptswap \
        --new=3:0:0 --typecode=3:8309 --change-name=3:cryptroot \
        "${INSTALL_DISK}"
    blockdev --rereadpt "${INSTALL_DISK}"
    udevadm settle
    [[ -b "${EFI_PART}" && -b "${SWAP_PART}" && -b "${ROOT_PART}" ]] \
        || die "Ядро не обнаружило созданные разделы."
}

prepare_encrypted_root() {
    log_info "Форматирование EFI и создание LUKS2 root..."
    mkfs.fat -F 32 -n EFI "${EFI_PART}"
    log_warn "Введите и подтвердите ASCII-пароль LUKS (раскладка US, как в GRUB)."
    cryptsetup luksFormat \
        --type luks2 --pbkdf pbkdf2 --cipher aes-xts-plain64 \
        --key-size 512 --hash sha512 --verify-passphrase --batch-mode \
        "${ROOT_PART}"
    cryptsetup open --allow-discards "${ROOT_PART}" "${ROOT_MAPPER_NAME}"
    ROOT_OPENED=true

    mkfs.btrfs -f -L archroot "${ROOT_MAPPER}"
    mount "${ROOT_MAPPER}" "${TARGET_MOUNT}"
    TARGET_MOUNTED=true
    btrfs subvolume create "${TARGET_MOUNT}/@"
    btrfs subvolume create "${TARGET_MOUNT}/@snapshots"
    umount "${TARGET_MOUNT}"

    mount -o "subvol=@,${BTRFS_MOUNT_OPTIONS}" "${ROOT_MAPPER}" "${TARGET_MOUNT}"
    install -d -m 0755 "${TARGET_MOUNT}/efi" "${TARGET_MOUNT}/boot"
    install -d -m 0750 "${TARGET_MOUNT}/.snapshots"
    mount -o "subvol=@snapshots,${BTRFS_MOUNT_OPTIONS}" "${ROOT_MAPPER}" "${TARGET_MOUNT}/.snapshots"
    mount "${EFI_PART}" "${TARGET_MOUNT}/efi"
}

install_base_system() {
    log_info "Установка базовой системы и пакетов..."
    pacstrap -K "${TARGET_MOUNT}" "${BASE_PACKAGES[@]}"
}

create_keyfiles_and_swap() {
    local key_dir="${TARGET_MOUNT}/etc/cryptsetup-keys.d"
    local root_key="${key_dir}/${ROOT_MAPPER_NAME}.key"
    local swap_key="${key_dir}/${SWAP_MAPPER_NAME}.key"

    install -d -m 0700 "${key_dir}"
    install -m 0600 /dev/null "${root_key}"
    install -m 0600 /dev/null "${swap_key}"
    dd if=/dev/urandom of="${root_key}" bs=64 count=1 conv=notrunc status=none
    dd if=/dev/urandom of="${swap_key}" bs=64 count=1 conv=notrunc status=none

    log_warn "Повторно введите пароль root-LUKS для добавления ключа initramfs."
    cryptsetup luksAddKey "${ROOT_PART}" "${root_key}"

    log_info "Создание отдельного LUKS2 swap-контейнера..."
    cryptsetup luksFormat --type luks2 --pbkdf argon2id --batch-mode \
        --key-file "${swap_key}" "${SWAP_PART}"
    SWAP_OWNED=true
    cryptsetup open --key-file "${swap_key}" "${SWAP_PART}" "${SWAP_MAPPER_NAME}"
    mkswap -L swap "${SWAP_MAPPER}"
    cryptsetup close "${SWAP_MAPPER_NAME}"
}

write_mount_configuration() {
    local root_uuid swap_uuid
    root_uuid="$(blkid -s UUID -o value "${ROOT_PART}")"
    swap_uuid="$(blkid -s UUID -o value "${SWAP_PART}")"
    [[ -n "${root_uuid}" && -n "${swap_uuid}" ]] || die "Не удалось получить LUKS UUID."

    genfstab -U "${TARGET_MOUNT}" >"${TARGET_MOUNT}/etc/fstab"
    printf '/dev/mapper/%s none swap defaults 0 0\n' "${SWAP_MAPPER_NAME}" \
        >>"${TARGET_MOUNT}/etc/fstab"
    printf '%s UUID=%s /etc/cryptsetup-keys.d/%s.key luks\n' \
        "${SWAP_MAPPER_NAME}" "${swap_uuid}" "${SWAP_MAPPER_NAME}" \
        >"${TARGET_MOUNT}/etc/crypttab"
    chmod 0600 "${TARGET_MOUNT}/etc/crypttab"

    install -d -m 0700 "${TARGET_MOUNT}/root/archplus-installer/lib" \
        "${TARGET_MOUNT}/root/archplus-installer/assets"
    install -m 0755 "${SCRIPT_DIR}/chroot.sh" "${SCRIPT_DIR}/niri.sh" \
        "${TARGET_MOUNT}/root/archplus-installer/"
    install -m 0644 "${SCRIPT_DIR}/config.sh" \
        "${TARGET_MOUNT}/root/archplus-installer/config.sh"
    install -m 0644 "${SCRIPT_DIR}/lib/common.sh" \
        "${TARGET_MOUNT}/root/archplus-installer/lib/common.sh"
    install -m 0644 "${SCRIPT_DIR}/attach/bg.jpg" \
        "${TARGET_MOUNT}/root/archplus-installer/assets/bg.jpg"
    printf 'ROOT_LUKS_UUID=%q\nSWAP_LUKS_UUID=%q\n' "${root_uuid}" "${swap_uuid}" \
        >"${TARGET_MOUNT}/root/archplus-installer/install.env"
    chmod 0600 "${TARGET_MOUNT}/root/archplus-installer/install.env"
}

run_chroot_stage() {
    log_info "Запуск настройки внутри chroot..."
    arch-chroot "${TARGET_MOUNT}" /root/archplus-installer/chroot.sh
}

main() {
    parse_arguments "$@"
    if [[ "${DRY_RUN}" == true ]]; then
        print_dry_run
        exit 0
    fi

    exec > >(tee -a "${LOG_FILE}") 2>&1
    trap cleanup EXIT
    trap 'log_error "Ошибка в строке ${LINENO}: ${BASH_COMMAND}"' ERR

    printf 'ArchPlus: автоматическая установка Arch Linux UEFI\n'
    preflight
    confirm_disk_erasure
    prepare_live_environment
    partition_disk
    prepare_encrypted_root
    install_base_system
    create_keyfiles_and_swap
    write_mount_configuration
    run_chroot_stage

    install -m 0600 "${LOG_FILE}" "${TARGET_MOUNT}/var/log/archplus-install.log"
    INSTALL_FINISHED=true
    printf '\nУстановка завершена. Извлеките установочный носитель и перезагрузитесь вручную.\n'
}

main "$@"
