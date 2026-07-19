#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_FILES=(
    "${PROJECT_DIR}/my_archEFI.sh"
    "${PROJECT_DIR}/chroot.sh"
    "${PROJECT_DIR}/niri.sh"
    "${PROJECT_DIR}/config.sh"
    "${PROJECT_DIR}/lib/common.sh"
    "${PROJECT_DIR}/tests/static.sh"
)

fail() {
    printf '[FAIL] %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local file=$1 expected=$2
    grep -Fq -- "${expected}" "${file}" \
        || fail "${file} не содержит ожидаемую строку: ${expected}"
}

printf '[TEST] bash -n\n'
bash -n "${SHELL_FILES[@]}"

if command -v shellcheck >/dev/null 2>&1; then
    printf '[TEST] shellcheck\n'
    shellcheck -x "${SHELL_FILES[@]}"
else
    printf '[SKIP] shellcheck не установлен\n'
fi

printf '[TEST] ключевые инварианты\n'
assert_contains "${PROJECT_DIR}/config.sh" 'INSTALL_DISK="/dev/sda"'
assert_contains "${PROJECT_DIR}/config.sh" 'SWAP_SIZE_GIB=4'
assert_contains "${PROJECT_DIR}/config.sh" 'nvidia-open-dkms'
assert_contains "${PROJECT_DIR}/chroot.sh" 'cryptdevice=UUID='
assert_contains "${PROJECT_DIR}/chroot.sh" 'cryptkey=rootfs:'
assert_contains "${PROJECT_DIR}/chroot.sh" 'HOOKS=(base udev autodetect microcode'
assert_contains "${PROJECT_DIR}/chroot.sh" 'grub-btrfs-overlayfs'
assert_contains "${PROJECT_DIR}/chroot.sh" 'GRUB_ENABLE_CRYPTODISK'
assert_contains "${PROJECT_DIR}/niri.sh" 'layout "us,ru"'
assert_contains "${PROJECT_DIR}/niri.sh" 'tuigreet --time'

if grep -Eq 'cryptlvm|vg0|lvm2|(^|[^[:alnum:]_])resume([^[:alnum:]_]|$)' \
    "${PROJECT_DIR}/my_archEFI.sh" "${PROJECT_DIR}/chroot.sh" "${PROJECT_DIR}/config.sh"; then
    fail "В установочных скриптах осталась LVM/hibernate-конфигурация."
fi

niri_stage_line="$(grep -nF '"${SCRIPT_DIR}/niri.sh" "${USERNAME}"' "${PROJECT_DIR}/chroot.sh" | cut -d: -f1)"
initramfs_stage_line="$(grep -nF '    configure_initramfs_and_grub' "${PROJECT_DIR}/chroot.sh" | tail -n1 | cut -d: -f1)"
snapper_stage_line="$(grep -nF '    configure_snapper' "${PROJECT_DIR}/chroot.sh" | tail -n1 | cut -d: -f1)"
((niri_stage_line < initramfs_stage_line && initramfs_stage_line < snapper_stage_line)) \
    || fail "Snapper должен включаться только после desktop и готового initramfs."

printf '[TEST] dry-run не вызывает системные команды\n'
test_dir="$(mktemp -d /tmp/archplus-static.XXXXXX)"
marker_file="${test_dir}/called"
output_file="${test_dir}/dry-run.out"
trap 'rm -rf -- "${test_dir}"' EXIT

destructive_commands=(
    arch-chroot
    cryptsetup
    genfstab
    mkfs.btrfs
    mkfs.fat
    mkswap
    mount
    pacstrap
    sgdisk
    umount
    wipefs
)

for command_name in "${destructive_commands[@]}"; do
    # The generated stub must expand these variables when it is executed.
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$0" >>"${ARCHPLUS_TEST_MARKER}"\nexit 99\n' \
        >"${test_dir}/${command_name}"
    chmod +x "${test_dir}/${command_name}"
done

ARCHPLUS_TEST_MARKER="${marker_file}" \
    PATH="${test_dir}:${PATH}" \
    bash "${PROJECT_DIR}/my_archEFI.sh" --dry-run >"${output_file}"

[[ ! -e "${marker_file}" ]] || fail "dry-run вызвал системную команду: $(tr '\n' ' ' <"${marker_file}")"
assert_contains "${output_file}" 'DRY RUN: никакие системные команды не выполняются.'
assert_contains "${output_file}" '/dev/sda2  LUKS2 swap, 4 GiB'

if bash "${PROJECT_DIR}/my_archEFI.sh" --definitely-invalid >/dev/null 2>&1; then
    fail "Неизвестный аргумент должен завершать скрипт с ошибкой."
fi

if ((EUID != 0)); then
    if bash "${PROJECT_DIR}/my_archEFI.sh" </dev/null >/dev/null 2>&1; then
        fail "Обычный запуск не от root должен завершаться с ошибкой."
    fi
fi

printf '[ OK ] Все статические тесты пройдены.\n'
