# MikroTik RouterOS CHR Installer

Скрипт для быстрой установки **MikroTik RouterOS Cloud Hosted Router (CHR)** на Linux VDS/VPS (Debian, Ubuntu, CentOS, AlmaLinux, Rocky Linux, Arch Linux).

### Особенности
- **Поддержка шлюза `10.0.0.1`** (Hetzner Cloud и аналогичные VDS с point-to-point /32 маршрутизацией): автоматическое определение IP и шлюза с записью статической конфигурации в `autorun.scr`.
- **Поддержка UEFI и BIOS**: автоматическое определение режима загрузки и конвертация образа для UEFI при необходимости.
- **Выбор версии RouterOS**: по умолчанию устанавливается актуальная стабильная версия.
- **Безопасность**: запрос пароля `admin` при установке и отключение неиспользуемых сервисов (telnet, ftp, www, ssh, api). Доступ по умолчанию через **WinBox** (порт 8291).
- **Поддержка контейнеров**: автоматическая загрузка и включение пакета `container`.

---

## Быстрый запуск

Запустите команду на вашем сервере под пользователем `root`:

```bash
wget -qO chr.sh https://raw.githubusercontent.com/neosloter/MikrotikScripts/main/chr-install/chr.sh && bash chr.sh
```

или через `curl`:

```bash
curl -sSL https://raw.githubusercontent.com/neosloter/MikrotikScripts/main/chr-install/chr.sh -o chr.sh && bash chr.sh
```

---

## Процесс установки

1. Скрипт проверит необходимые утилиты (`wget`, `gunzip`, `fdisk`, `lsblk`, `ip`).
2. Предложит выбрать версию RouterOS (нажмите Enter для версии по умолчанию).
3. Запросит пароль администратора `admin`.
4. Проверит шлюз:
   - Если шлюз **`10.0.0.1`**, определит ваш публичный IP и предложит подтвердить его (или ввести вручную). В `autorun.scr` будут добавлены:
     ```routeros
     /ip address add address=<IP>/32 network=10.0.0.1 interface=ether1
     /ip route add dst-address=0.0.0.0/0 gateway=10.0.0.1
     ```
   - Если шлюз стандартный, применится стандартное поведение (DHCP).
5. Определит целевой диск и запросит подтверждение (`Y`).
6. Скачает образ, сконфигурирует автозапуск, запишет образ на диск через `dd` и перезагрузит систему.

---

> [!WARNING]
> Установка **полностью уничтожит все существующие данные** на целевом диске сервера! Обязательно сохраните нужные файлы перед запуском.