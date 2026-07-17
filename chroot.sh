# Для шифрования используем encrypt и lvm2 hooks
MKINITCPIO_HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt lvm2 filesystems fsck"
CRYPT_UUID=$(blkid -s UUID -o value /dev/sda2)
GRUB_CMDLINE="cryptdevice=UUID=$CRYPT_UUID:cryptlvm root=/dev/vg0/root"

# Время
ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
timedatectl set-ntp true && hwclock --systohc

# Имя хоста
echo "gnu-not-unix" > /etc/hostname
cat >> /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   gnu-not-unix.localdomain gnu-not-unix
EOF

# Локаль
echo "🌐 Настройка локализации..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
echo "ru_RU.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo 'LANG=ru_RU.UTF-8' > /etc/locale.conf
echo 'KEYMAP=ru' > /etc/vconsole.conf
echo 'FONT=cyr-sun16' >> /etc/vconsole.conf

# Устанавливаем lvm2
pacman -Syy lvm2 --noconfirm --needed

# Модифицируем mkinitcpio.conf
sed -i 's/^HOOKS=.*/HOOKS=($MKINITCPIO_HOOKS)/' /etc/mkinitcpio.conf
echo "mkinitcpio hooks настроены: $MKINITCPIO_HOOKS"

mkinitcpio -P

# Включаем поддержку шифрования в GRUB
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
sed -i 's/^GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

# Добавляем параметры ядра для расшифровки
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_CMDLINE quiet\"|" /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"$GRUB_CMDLINE\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

# Пароли
passwd

useradd -m -g users -G wheel,power,storage,audio,video,input -s /bin/bash d8n
passwd d8n

# --- Sudo ---
echo "🔓 Настройка sudo..."
echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers

# --- Multilib ---
echo "📦 Включение репозитория multilib..."
echo '[multilib]' >> /etc/pacman.conf
echo 'Include = /etc/pacman.d/mirrorlist' >> /etc/pacman.conf
pacman -Syy

# --- Сеть ---
echo "🌐 Включение NetworkManager..."
systemctl enable NetworkManager

# --- Шрифты ---
echo "🔤 Установка шрифтов..."
pacman -S ttf-liberation ttf-dejavu noto-fonts noto-fonts-cjk --noconfirm

# --- Завершение ---
echo ""
echo "╔═════════════════════════════════╗"
echo "║ ✅ Базовая установка завершена! ║"
echo "╚═════════════════════════════════╝"
echo ""

rm -f ./chroot.sh

exit