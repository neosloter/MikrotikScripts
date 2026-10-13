# MikroTik Scripts

Коллекция скриптов и утилит для работы с **MikroTik RouterOS**.

---

## Доступные скрипты

### 1. [RouterOS CHR Installer](./chr-install)
Автоматизированный скрипт установки **MikroTik RouterOS Cloud Hosted Router (CHR)** на любые Linux VDS/VPS (Debian, Ubuntu, CentOS, AlmaLinux, Rocky Linux, Arch Linux).

**Особенности:**
* Поддержка VDS со шлюзом `10.0.0.1` (Hetzner Cloud и аналогичные point-to-point /32 сети).
* Поддержка BIOS Legacy и UEFI boot mode.
* Выбор версии RouterOS и установка пакета `container`.
* Первичная настройка безопасности и пароля администратора.

**Быстрый запуск:**
```bash
wget -qO chr.sh https://raw.githubusercontent.com/neosloter/MikrotikScripts/main/chr-install/chr.sh && bash chr.sh
```

Подробная документация и описание работы доступны в папке [**chr-install**](./chr-install).
