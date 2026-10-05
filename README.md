# BUDDY для Raspberry Pi

Інсталятор налаштовує вебпанель BUDDY на Waitress WSGI, Wi-Fi failover і MAVLink-маршрутизатор для польотного контролера через USB/UART та QGroundControl через UDP.

## Встановлення однією командою

На Raspberry Pi OS / Debian запустіть:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/drek1357/rassberi/main/install.sh -o "$tmp" && sudo bash "$tmp"; rc=$?; rm -f "$tmp"; exit "$rc"
```

Інсталятор за замовчуванням використовує UART `/dev/serial0`, швидкість `115200` і UDP порт `14550`. Для USB-підключення або інших параметрів задайте їх перед `bash`:

```bash
tmp="$(mktemp)" && curl -fsSL https://raw.githubusercontent.com/drek1357/rassberi/main/install.sh -o "$tmp" && sudo env BUDDY_FCU_DEVICE=/dev/ttyACM0 BUDDY_FCU_BAUD=115200 bash "$tmp"; rc=$?; rm -f "$tmp"; exit "$rc"
```

Для іншого UDP порту передайте `BUDDY_QGC_UDP_PORT=<порт>`. Для UART GPIO використовуйте `/dev/serial0`; для USB шлях зазвичай має вигляд `/dev/ttyACM0` або `/dev/ttyUSB0`. Переконайтеся, що автопілот передає MAVLink на вибраному порту та швидкості.

Під час першого встановлення пароль вебпанелі генерується випадково й показується один раз у консолі. Збережіть його. Існуючий файл `/opt/buddy/config.json` під час повторного встановлення зберігається.

Повторний запуск оновлює інсталятор і служби, зберігаючи пароль та інші налаштування. Перед перезапуском служб перевіряється синтаксис вбудованого Python застосунку.

## Підключення QGroundControl

1. Підключіть Raspberry Pi і пристрій з QGroundControl до однієї LAN/Wi-Fi мережі. Інсталятор вмикає UDP broadcast для авто-виявлення QGC на порту `14550`.
2. Якщо авто-виявлення недоступне, або QGC підключається через ZeroTier, відкрийте **Settings → Comm Links → Add New Link** і виберіть **UDP**.
3. Вкажіть локальний UDP порт `14550` і додайте Raspberry Pi як віддалений хост на порт `14550`. IP-адреси Pi інсталятор показує після встановлення.
4. Збережіть і під’єднайте канал. Якщо зв’язку немає, перевірте UART-пристрій і baud rate, а також дозвіл UDP `14550` у мережевому фаєрволі.

QGroundControl керує польотним контролером через цей канал. Обмежте доступ до UDP порту довіреною LAN або ZeroTier мережею; не налаштовуйте його переадресацію з публічного інтернету.

Документація: [QGroundControl Comm Links](https://docs.qgroundcontrol.com/master/en/qgc-user-guide/settings_view/comm_links.html), [MAVLink Router](https://github.com/mavlink-router/mavlink-router).

## Вебпанель

Після інсталяції панель доступна за адресою `http://<IP Raspberry Pi>:8081`. При першому запуску використайте логін `admin` і пароль, показаний інсталятором. Змініть його через налаштування панелі.

## Перевірки

GitHub Actions запускає перевірку синтаксису Bash і Python, тести API та сценарії Wi-Fi/маршрутів із підміною системних команд, а також тести DOM-таблиці Wi-Fi (включно з небезпечними SSID, Unicode та `%`). Перевірки не вимагають підключення до польотного контролера й не змінюють маршрути на реальному пристрої.

