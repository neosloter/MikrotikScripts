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

### 2. [MikroTik Configuration Tool (RouterOS v7)](./Mikrotik%20conf%20tool)
Интерактивный веб-конфигуратор и генератор боевых скриптов `.rsc` для оборудования MikroTik под управлением **RouterOS v7**.

**🌐 Запустить онлайн:** [Открыть веб-конфигуратор на GitHub Pages](https://neosloter.github.io/MikrotikScripts/)

**Включает 5 модулей:**
* **🛡️ Firewall:** Default-Drop архитектура, кастомные цепочки `ISP-Input`, `ISP-Input-Allow`, `Local-Input`, RAW, FastTrack, NAT.
* **⚡ WireGuard:** Hub-and-Spoke, RoadWarrior, MSS Clamping, автогенерация ключей Curve25519 в браузере и экспорт `.conf` файлов.
* **🤖 Telegram:** Движок `TgSend` через `/tool fetch` с оповещениями о перезагрузках, входах, брутфорсе, падении аплинков (Netwatch) и DHCP-клиентах.
* **🛑 Defense:** Каскадный бан перебора паролей (обратный порядок стадий), Port Scan Detection (PSD), Honeypots и Whitelist bypass.
* **🔒 System & DoH:** Сокрытие MNDP от провайдера, изоляция L2 MAC-Server, харденинг `/ip service`, NTP и DNS over HTTPS.

Подробная документация и инструкция доступны в папке [**Mikrotik conf tool**](./Mikrotik%20conf%20tool).

