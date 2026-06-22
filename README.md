<div align="center">

# ⚡ Eclipse WARP Manager

### Автоматическая установка Cloudflare WARP для Remnawave / Xray нод

<img src="https://img.shields.io/badge/Linux-Ubuntu%20%7C%20Debian-blue?style=for-the-badge&logo=linux" />
<img src="https://img.shields.io/badge/Cloudflare-WARP-orange?style=for-the-badge&logo=cloudflare" />
<img src="https://img.shields.io/badge/WireGuard-wgcf-green?style=for-the-badge&logo=wireguard" />
<img src="https://img.shields.io/badge/Remnawave-ready-purple?style=for-the-badge" />

<br><br>

**Безопасный WARP-интерфейс `warp` без перехвата default route.**  
Подходит для Remnawave/Xray outbound через `sockopt.interface`.

</div>

---

## 🚀 Быстрая установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blantxxv/warp/main/warp-auto-install.sh)
```

Автоматический режим без меню:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/blantxxv/warp/main/warp-auto-install.sh) --auto
```

> Замени `blantxxv/warp` на свой реальный репозиторий, если файл лежит в другом месте.

---

## 🧩 Что делает скрипт

`Eclipse WARP Manager` автоматически:

- устанавливает зависимости;
- скачивает актуальный `wgcf`;
- регистрирует Cloudflare WARP профиль;
- создаёт WireGuard-конфиг `/etc/wireguard/warp.conf`;
- поднимает интерфейс `warp`;
- добавляет `Table = off`, чтобы не ломать SSH и default route;
- удаляет `DNS = ...`, чтобы не менять системный DNS;
- сканирует WARP endpoints;
- выбирает endpoint, где `warp=on` и страна не находится в deny-list;
- ставит systemd watchdog, который проверяет WARP и пересканирует endpoint при проблеме.

---

## 🛡️ Почему это безопаснее официального `cloudflare-warp`

Официальный клиент Cloudflare WARP может забрать весь default route сервера.  
На VPS с Remnawave/Xray это может привести к потере SSH и падению ноды.

Этот скрипт использует схему:

```text
wgcf → WireGuard → интерфейс warp → Remnawave/Xray sockopt.interface
```

Ключевая настройка:

```ini
Table = off
```

Это значит:

```text
обычный трафик сервера → eth0
выбранный трафик Xray → warp
```

---

## 🌍 Автоматический подбор не-RU WARP

По умолчанию скрипт запрещает WARP-выход с `loc=RU`.

Проверка выполняется через:

```bash
curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace
```

Нормальный результат:

```text
warp=on
loc=BR
```

или:

```text
warp=on
loc=DE
```

Главное: `loc` не должен быть `RU`, если ты используешь стандартный deny-list.

---

## 🖥️ Меню

При запуске без аргументов открывается меню:

```text
███████╗ ██████╗██╗     ██╗██████╗ ███████╗███████╗
██╔════╝██╔════╝██║     ██║██╔══██╗██╔════╝██╔════╝
█████╗  ██║     ██║     ██║██████╔╝███████╗█████╗
██╔══╝  ██║     ██║     ██║██╔═══╝ ╚════██║██╔══╝
███████╗╚██████╗███████╗██║██║     ███████║███████╗
╚══════╝ ╚═════╝╚══════╝╚═╝╚═╝     ╚══════╝╚══════╝

             WARP Manager для Remnawave Node
```

Доступные действия:

```text
1) Автоматическая установка WARP
2) Пересканировать WARP endpoints
3) Статус WARP
4) Ручная инструкция
5) Удалить/отключить WARP Manager
0) Выход
```

---

## ⚙️ Режимы запуска

### Автоустановка

```bash
./warp-auto-install.sh --auto
```

### Проверить статус

```bash
./warp-auto-install.sh --status
```

### Пересканировать endpoints

```bash
./warp-auto-install.sh --rescan-only
```

### Удалить/отключить WARP Manager

```bash
./warp-auto-install.sh --uninstall
```

### Показать ручную инструкцию

```bash
./warp-auto-install.sh --manual
```

---

## 🌐 Настройка стран

### Запретить RU

По умолчанию уже используется:

```bash
./warp-auto-install.sh --deny=RU
```

### Запретить несколько стран

```bash
./warp-auto-install.sh --deny=RU,CN,IR
```

### Разрешить только конкретные страны

```bash
./warp-auto-install.sh --accept=BR,DE,PL,NL
```

### Без watchdog timer

```bash
./warp-auto-install.sh --no-timer
```

---

## 🔎 Проверка после установки

```bash
ip route
wg show warp
curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace
curl -4 https://www.cloudflare.com/cdn-cgi/trace
```

Правильная картина:

```text
curl --interface warp:
warp=on
loc=BR

curl без interface:
warp=off
ip=<обычный IP сервера>
```

В `ip route` default route должен остаться через основной интерфейс:

```text
default via ... dev eth0
```

Не должно быть default route через `warp`.

---

## 🔗 Remnawave / Xray outbound

Добавь outbound:

```json
{
  "tag": "warp-out",
  "protocol": "freedom",
  "settings": {
    "domainStrategy": "UseIPv4"
  },
  "streamSettings": {
    "sockopt": {
      "interface": "warp",
      "tcpFastOpen": true
    }
  }
}
```

После этого нужные домены можно отправлять через:

```json
"outboundTag": "warp-out"
```

---

## 🧠 Пример routing для Gemini

```json
{
  "type": "field",
  "domain": [
    "domain:gemini.google.com",
    "domain:generativelanguage.googleapis.com",
    "domain:ai.google.dev",
    "domain:googleapis.com",
    "domain:googleusercontent.com",
    "domain:gstatic.com",
    "domain:google.com",
    "domain:accounts.google.com"
  ],
  "outboundTag": "warp-out"
}
```

Правило должно стоять выше общих `DIRECT`, `BRIDGE`, `PROXY` правил.

---

## 🧰 Что создаётся на сервере

```text
/etc/wireguard/warp.conf
/etc/wireguard/wgcf-account.toml
/etc/wireguard/wgcf-profile.conf
/usr/local/bin/wgcf
/usr/local/sbin/warp-auto-recheck.sh
/etc/systemd/system/warp-auto-recheck.service
/etc/systemd/system/warp-auto-recheck.timer
/var/log/warp-auto-install.log
```

---

## 🕒 Watchdog

Скрипт создаёт таймер:

```bash
systemctl status warp-auto-recheck.timer
```

Он проверяет WARP каждые 15 минут.  
Если WARP отвалился или снова стал запрещённой локацией, запускается пересканирование endpoints.

Ручной запуск:

```bash
systemctl start warp-auto-recheck.service
```

Логи:

```bash
journalctl -u warp-auto-recheck.service -n 100 --no-pager
cat /var/log/warp-auto-install.log
```

---

## 🧯 Если SSH пропал

Скрипт не должен ломать SSH, потому что использует `Table = off`.

Но если ты ранее запускал официальный клиент Cloudflare WARP, отключи его через VNC/Serial Console:

```bash
warp-cli disconnect || true
systemctl stop warp-svc || true
systemctl disable warp-svc || true
```

Проверить default route:

```bash
ip route
```

---

## ❌ Удаление

Через меню:

```bash
./warp-auto-install.sh --uninstall
```

Полная ручная очистка:

```bash
systemctl disable --now warp-auto-recheck.timer
systemctl disable --now wg-quick@warp

rm -f /etc/systemd/system/warp-auto-recheck.timer
rm -f /etc/systemd/system/warp-auto-recheck.service
rm -f /usr/local/sbin/warp-auto-recheck.sh
rm -f /etc/wireguard/warp.conf
rm -f /etc/wireguard/wgcf-account.toml
rm -f /etc/wireguard/wgcf-profile.conf

systemctl daemon-reload
```

---

## 📋 Требования

- Ubuntu / Debian;
- root-доступ;
- `systemd`;
- IPv4-доступ;
- открытый UDP до Cloudflare WARP endpoints.

Проверено на:

```text
Ubuntu 24.04
Debian 12
```

---

## ⚠️ Важно

Cloudflare WARP в обычном режиме не даёт официальной настройки выбора страны.  
Скрипт не “покупает” геолокацию и не гарантирует вечный `loc=DE/BR/PL`.

Он делает практическую вещь:

```text
перебирает WARP endpoints → проверяет loc → оставляет подходящий
```

Если Cloudflare изменит маршрутизацию, watchdog пересканирует endpoint.

---

## 🛰️ Быстрые команды

```bash
# статус
./warp-auto-install.sh --status

# пересканировать
./warp-auto-install.sh --rescan-only

# проверить WARP
curl -4 --interface warp https://www.cloudflare.com/cdn-cgi/trace

# проверить обычный IP сервера
curl -4 https://www.cloudflare.com/cdn-cgi/trace

# логи
cat /var/log/warp-auto-install.log

# таймер
systemctl status warp-auto-recheck.timer
```

---

<div align="center">

### Eclipse WARP Manager

**Cloudflare WARP для Remnawave-ноды без падения SSH.**

`@light_eclipse`

</div>
