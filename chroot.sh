#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/install.env"

trap 'log_error "Ошибка chroot-этапа в строке ${LINENO}: ${BASH_COMMAND}"' ERR

set_assignment() {
    local file=$1 key=$2 value=$3
    if grep -Eq "^#?${key}=" "${file}"; then
        sed -Ei "s|^#?${key}=.*|${key}=${value}|" "${file}"
    else
        printf '%s=%s\n' "${key}" "${value}" >>"${file}"
    fi
}

set_snapper_value() {
    local key=$1 value=$2
    sed -Ei "s|^${key}=.*|${key}=\"${value}\"|" /etc/snapper/configs/root
}

validate_context() {
    require_root
    [[ -f /etc/arch-release ]] || die "chroot.sh должен выполняться внутри установленного Arch Linux."
    [[ -n "${ROOT_LUKS_UUID:-}" && -n "${SWAP_LUKS_UUID:-}" ]] \
        || die "install.env не содержит UUID LUKS."
    findmnt -rn -M / >/dev/null || die "Корневая файловая система не смонтирована."
    findmnt -rn -M /efi >/dev/null || die "EFI-раздел не смонтирован в /efi."
}

configure_identity_and_locale() {
    log_info "Настройка времени, hostname и локали..."
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    hwclock --systohc

    printf '%s\n' "${HOSTNAME}" >/etc/hostname
    cat >/etc/hosts <<HOSTS
127.0.0.1 localhost
::1       localhost
127.0.1.1 ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

    sed -Ei 's/^#(en_US\.UTF-8 UTF-8)/\1/' /etc/locale.gen
    sed -Ei 's/^#(ru_RU\.UTF-8 UTF-8)/\1/' /etc/locale.gen
    locale-gen
    printf 'LANG=%s\n' "${LOCALE}" >/etc/locale.conf
    printf 'KEYMAP=%s\nFONT=%s\n' "${KEYMAP}" "${CONSOLE_FONT}" >/etc/vconsole.conf
}

enable_multilib() {
    log_info "Включение multilib..."
    sed -Ei '/^#\[multilib\]$/,/^#Include = \/etc\/pacman\.d\/mirrorlist$/ s/^#//' /etc/pacman.conf
    if ! grep -q '^\[multilib\]$' /etc/pacman.conf; then
        cat >>/etc/pacman.conf <<'MULTILIB'

[multilib]
Include = /etc/pacman.d/mirrorlist
MULTILIB
    fi
    pacman -Syu --noconfirm
}

configure_accounts() {
    log_info "Настройка root и пользователя ${USERNAME}..."
    if ! id "${USERNAME}" >/dev/null 2>&1; then
        useradd -m -g users -G wheel,power,storage,audio,video,input -s /bin/bash "${USERNAME}"
    fi

    printf '\nУстановите пароль root:\n'
    passwd root
    printf '\nУстановите пароль пользователя %s:\n' "${USERNAME}"
    passwd "${USERNAME}"

    install -d -m 0750 /etc/sudoers.d
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
    chmod 0440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers
}

configure_network() {
    install -d -m 0755 /etc/NetworkManager/conf.d
    cat >/etc/NetworkManager/conf.d/wifi_backend.conf <<'NETWORK'
[device]
wifi.backend=iwd
NETWORK
}

configure_snapper() {
    log_info "Настройка Snapper..."
    umount /.snapshots
    rmdir /.snapshots
    snapper --no-dbus -c root create-config /
    btrfs subvolume delete /.snapshots
    install -d -m 0750 /.snapshots
    mount /.snapshots
    chmod 0750 /.snapshots

    set_snapper_value ALLOW_USERS "${USERNAME}"
    set_snapper_value SYNC_ACL yes
    set_snapper_value TIMELINE_CREATE yes
    set_snapper_value TIMELINE_CLEANUP yes
    set_snapper_value TIMELINE_MIN_AGE 1800
    set_snapper_value TIMELINE_LIMIT_HOURLY 5
    set_snapper_value TIMELINE_LIMIT_DAILY 7
    set_snapper_value TIMELINE_LIMIT_WEEKLY 4
    set_snapper_value TIMELINE_LIMIT_MONTHLY 3
    set_snapper_value TIMELINE_LIMIT_YEARLY 0
    set_snapper_value NUMBER_CLEANUP yes
    set_snapper_value NUMBER_MIN_AGE 1800
    set_snapper_value NUMBER_LIMIT 10
    set_snapper_value NUMBER_LIMIT_IMPORTANT 10
}

configure_initramfs_and_grub() {
    log_info "Настройка mkinitcpio и GRUB..."
    sed -Ei 's|^FILES=.*|FILES=(/etc/cryptsetup-keys.d/cryptroot.key)|' /etc/mkinitcpio.conf
    # grub-btrfs-overlayfs is a BusyBox runtime hook and is incompatible with
    # a systemd-based initramfs, so use udev/encrypt rather than sd-encrypt.
    sed -Ei 's|^HOOKS=.*|HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck grub-btrfs-overlayfs)|' /etc/mkinitcpio.conf

    set_assignment /etc/default/grub GRUB_ENABLE_CRYPTODISK y
    set_assignment /etc/default/grub GRUB_TIMEOUT_STYLE menu
    set_assignment /etc/default/grub GRUB_TIMEOUT 5
    set_assignment /etc/default/grub GRUB_PRELOAD_MODULES '"part_gpt cryptodisk luks2 gcry_rijndael gcry_sha512 btrfs"'
    set_assignment /etc/default/grub GRUB_CMDLINE_LINUX \
        "\"cryptdevice=UUID=${ROOT_LUKS_UUID}:${ROOT_MAPPER_NAME}:allow-discards cryptkey=rootfs:/etc/cryptsetup-keys.d/${ROOT_MAPPER_NAME}.key root=${ROOT_MAPPER} rootflags=subvol=@\""
    set_assignment /etc/default/grub GRUB_CMDLINE_LINUX_DEFAULT '"quiet loglevel=3 nvidia_drm.modeset=1"'

    mkinitcpio -P
    grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck
}

enable_services() {
    systemctl set-default graphical.target
    systemctl enable NetworkManager.service
    systemctl enable systemd-timesyncd.service
    systemctl enable greetd.service
    systemctl enable snapper-timeline.timer
    systemctl enable snapper-cleanup.timer
    systemctl enable grub-btrfsd.service
}

create_initial_snapshot_and_grub_menu() {
    log_info "Создание начального снимка и меню GRUB..."
    snapper --no-dbus -c root create \
        --description "Initial ArchPlus installation" \
        --cleanup-algorithm number
    grub-mkconfig -o /boot/grub/grub.cfg
    grub-script-check /boot/grub/grub.cfg

    if [[ ! -s /boot/grub/grub-btrfs.cfg ]] \
        || ! grep -Eqs '(@snapshots|/\.snapshots)' /boot/grub/grub-btrfs.cfg; then
        die "grub-btrfs не добавил начальный снимок в конфигурацию GRUB."
    fi
}

validate_installation() {
    local findmnt_status=0

    log_info "Финальная проверка конфигурации..."
    cryptsetup isLuks "${ROOT_PART}"
    cryptsetup isLuks "${SWAP_PART}"
    grep -q "UUID=${SWAP_LUKS_UUID}" /etc/crypttab
    grep -Eq 'HOOKS=.*udev.*encrypt.*grub-btrfs-overlayfs' /etc/mkinitcpio.conf

    cryptsetup open --key-file "/etc/cryptsetup-keys.d/${SWAP_MAPPER_NAME}.key" \
        "${SWAP_PART}" "${SWAP_MAPPER_NAME}"
    findmnt --verify --tab-file /etc/fstab || findmnt_status=$?
    cryptsetup close "${SWAP_MAPPER_NAME}"
    ((findmnt_status == 0)) || die "Проверка /etc/fstab завершилась с ошибкой."

    systemctl is-enabled NetworkManager.service systemd-timesyncd.service greetd.service \
        snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service >/dev/null
    runuser -u "${USERNAME}" -- env HOME="/home/${USERNAME}" \
        XDG_CONFIG_HOME="/home/${USERNAME}/.config" niri validate
}

main() {
    validate_context
    configure_identity_and_locale
    enable_multilib
    configure_accounts
    configure_network
    "${SCRIPT_DIR}/niri.sh" "${USERNAME}"
    configure_initramfs_and_grub
    configure_snapper
    enable_services
    create_initial_snapshot_and_grub_menu
    validate_installation
    log_success "Настройка chroot завершена."
}

main "$@"
