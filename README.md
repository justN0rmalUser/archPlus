# ArchPlus installer

Набор Bash-скриптов для автоматической установки Arch Linux на UEFI-компьютер с фиксированной конфигурацией:

- диск `/dev/sda`;
- `linux-zen` и Intel microcode;
- NVIDIA open kernel modules через DKMS;
- LUKS2, Btrfs, GRUB;
- Snapper, автоматические снимки pacman и снимки в меню GRUB;
- Wayland compositor niri с готовым рабочим окружением.

Скрипт предназначен для пользователя, знакомого с ручной установкой Arch Linux. Dual boot, BIOS/Legacy и Secure Boot не поддерживаются. Выбор `nvidia-open-dkms` предполагает NVIDIA поколения Turing или новее, как следует из исходной конфигурации; для более старой видеокарты список драйверов нужно изменить до запуска.

## Внимание

Обычный запуск **полностью и без возможности автоматического восстановления стирает `/dev/sda`**. Перед разметкой выводятся модель, размер и текущие разделы диска, после чего требуется вручную ввести `ERASE /dev/sda`.

Dry-run ничего не проверяет и не меняет в системе:

```bash
bash my_archEFI.sh --dry-run
```

## Разметка

| Раздел | Размер | Содержимое |
|---|---:|---|
| `/dev/sda1` | 1 ГиБ | FAT32 ESP, смонтирован в `/efi` |
| `/dev/sda2` | 4 ГиБ | отдельный LUKS2-контейнер `cryptswap` |
| `/dev/sda3` | остаток | LUKS2 `cryptroot` с Btrfs |

Btrfs содержит подтом `@` для `/` и `@snapshots` для `/.snapshots`. `/home` и `/boot` находятся внутри `@`, поэтому входят в системные снимки. ESP не шифруется; всё остальное, включая swap, защищено LUKS2.

Опция `discard=async` пробрасывается через root-LUKS. Это подходит для SSD и позволяет TRIM, но раскрывает наблюдателю за диском приблизительную карту занятых блоков.

Swap не используется для гибернации. Его случайный ключ хранится в `/etc/cryptsetup-keys.d/cryptswap.key` внутри зашифрованного root, поэтому отдельный пароль при загрузке не запрашивается.

`/boot` также находится внутри root-LUKS. GRUB запрашивает пароль и получает доступ к kernel/initramfs из выбранного снимка. В initramfs встроен дополнительный LUKS-ключ, поэтому при штатной загрузке пароль вводится только один раз — в GRUB. Для совместимости encrypted `/boot` корневой LUKS2 использует PBKDF2.

Initramfs использует BusyBox hooks `udev`/`encrypt`, а не `systemd`/`sd-encrypt`: hook `grub-btrfs-overlayfs`, необходимый для writable recovery-сессии из read-only снимка, несовместим с systemd-based initramfs.

При последующей смене пароля root-LUKS необходимо сохранить хотя бы один PBKDF2 keyslot, доступный GRUB; новый пароль следует добавлять через `cryptsetup luksAddKey --pbkdf pbkdf2 /dev/sda3` и проверять до удаления старого keyslot.

## Установка

1. Загрузить актуальный Arch Linux ISO в UEFI-режиме.
2. Подключить сеть; для Wi-Fi можно использовать `iwctl`.
3. Скопировать весь каталог проекта, включая `attach/bg.jpg`, в live-среду.
4. Проверить план и запустить установку:

   ```bash
   bash my_archEFI.sh --dry-run
   sudo bash my_archEFI.sh
   ```

5. Ввести точную фразу очистки диска, пароль LUKS и затем пароли root и `d8n`. Для LUKS следует использовать ASCII: во время установки и в GRUB применяется US-раскладка.
6. После успешного завершения извлечь ISO и перезагрузиться вручную.

Скрипт не принимает пароли через аргументы или переменные окружения и не записывает их в журнал. Журнал успешной установки сохраняется в `/var/log/archplus-install.log`.

## Структура

- `my_archEFI.sh` — проверки live ISO, подтверждение, GPT/LUKS/Btrfs, pacstrap и запуск chroot;
- `chroot.sh` — локаль, пользователи, mkinitcpio, GRUB, Snapper и systemd services;
- `niri.sh` — отдельный редактируемый список desktop-пакетов и конфигурация niri/Waybar/greetd;
- `config.sh` — фиксированные параметры компьютера, диска и базовые пакеты;
- `lib/common.sh` — вывод, обработка ошибок и общие проверки;
- `tests/static.sh` — синтаксис, инварианты конфигурации и безопасность dry-run.

`chroot.sh` и `niri.sh` вызываются основным установщиком и не предназначены для запуска из live ISO напрямую.

Старые `archuefi.sh` и `archuefi3.sh` сохранены только как legacy-материалы и не участвуют в новой установке.

Копия этапов сохраняется в установленной системе под `/root/archplus-installer`. После изменения массива `NIRI_PACKAGES` или KDL-шаблона desktop-этап можно применить повторно:

```bash
sudo /root/archplus-installer/niri.sh d8n
```

## Niri

После загрузки `greetd` показывает `tuigreet`. После парольного входа запускается `niri-session`, без autologin. Устанавливаются Waybar, Fuzzel, Mako, Alacritty, swaylock/swayidle, XWayland Satellite, порталы, udiskie и PolicyKit agent.

Основные сочетания:

- `Super+T` — терминал;
- `Super+D` — launcher;
- `Super+Q` — закрыть окно;
- `Super+стрелки` — навигация;
- `Super+Shift+стрелки` — перемещение;
- `Super+Alt+L` — блокировка;
- `Alt+Shift` — переключение `us/ru`;
- `Print`, `Ctrl+Print`, `Alt+Print` — варианты скриншота;
- `Super+Shift+E` — выход из niri.

Выходы мониторов и render node GPU намеренно не фиксируются. После первого входа их можно посмотреть командой:

```bash
niri msg outputs
```

## Снимки и восстановление

`snap-pac` создаёт pre/post-снимки при транзакциях pacman. Дополнительно включены timeline-снимки: 5 hourly, 7 daily, 4 weekly и 3 monthly. `grub-btrfsd` обновляет меню загрузчика после появления или удаления снимков.

Пункт GRUB со снимком загружается через временный writable overlay. Изменения такой аварийной сессии исчезают после перезагрузки. Для постоянного отката нужно загрузиться с Arch ISO и создать новый writable `@` из `@snapshots/НОМЕР/snapshot`, следуя разделу восстановления в [ArchWiki Snapper](https://wiki.archlinux.org/title/Snapper#Restoring_/_to_its_previous_snapshot).

Поскольку `/home` находится внутри `@`, постоянный откат возвращает к состоянию снимка не только системные файлы, но и данные пользователя. Перед permanent rollback нужно скопировать новые документы отдельно. Сам `@snapshots` является отдельным подтомом и при откате `@` не теряется.

Полезные команды:

```bash
sudo snapper -c root list
sudo snapper -c root create --description "before experiment"
systemctl status grub-btrfsd.service
sudo grub-mkconfig -o /boot/grub/grub.cfg
```

## Проверки разработки

```bash
bash tests/static.sh
```

Тест всегда выполняет `bash -n`, проверяет ключевые настройки и запускает dry-run с подменёнными разрушающими командами. Если установлен ShellCheck, он также запускается автоматически.

Полный end-to-end тест следует проводить только в UEFI VM с отдельным виртуальным диском `/dev/sda`. NVIDIA/DRM необходимо окончательно проверять на целевом компьютере:

```bash
cat /sys/module/nvidia_drm/parameters/modeset
nvidia-smi
systemctl --user status pipewire wireplumber
```
