
#!/bin/bash
# ==============================================================================
# Автоустановщик SSH Telegram 2FA (Debian / Ubuntu), версия 2
#   sudo bash install-2fa.sh              — установка
#   sudo bash install-2fa.sh --uninstall  — снять защиту (убрать хук из PAM)
# ==============================================================================
set -euo pipefail
 
# --- Версии пакетов (зафиксированы). Если pip не найдёт версию, установка
#     остановится ДО изменения PAM. Свежие версии: pip index versions <пакет>
PTB_VER="22.0"
REQ_VER="2.32.4"
DOTENV_VER="1.0.1"
 
INSTALL_DIR="/opt/ssh-tg-auth"
SHM_DIR="/dev/shm/ssh_tg_auth"
PAM_FILE="/etc/pam.d/sshd"
PAM_LINE="account required pam_exec.so quiet ${INSTALL_DIR}/pam_script.py"
TMPFILES="/etc/tmpfiles.d/ssh-tg-auth.conf"
 
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
 
die() { echo -e "${RED}ОШИБКА: $*${NC}" >&2; exit 1; }
 
if [ "$EUID" -ne 0 ]; then
  die "Запустите скрипт от имени root (sudo)."
fi
 
# ------------------------------------------------------------------------------
# Удаление защиты
# ------------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
  sed -i '/pam_script.py/d' "$PAM_FILE"
  systemctl disable --now ssh-tg-auth 2>/dev/null || true
  echo -e "${GREEN}Хук удалён из ${PAM_FILE}, служба остановлена.${NC}"
  echo "Файлы остались в ${INSTALL_DIR}. Полностью удалить: rm -rf ${INSTALL_DIR} /etc/systemd/system/ssh-tg-auth.service ${TMPFILES}"
  exit 0
fi
 
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}      УСТАНОВКА SSH TELEGRAM 2FA СИСТЕМЫ         ${NC}"
echo -e "${CYAN}=================================================${NC}\n"
 
# ------------------------------------------------------------------------------
# Предпроверки
# ------------------------------------------------------------------------------
command -v apt-get >/dev/null || die "Нужен Debian/Ubuntu (apt-get)."
command -v sshd >/dev/null    || die "sshd не найден."
SSHD_CFG=$(sshd -T 2>/dev/null) || die "Не удалось прочитать конфиг sshd (sshd -T)."
if ! grep -qi '^usepam yes' <<<"$SSHD_CFG"; then
  die "В sshd выключен UsePAM. Включите 'UsePAM yes' в sshd_config, иначе 2FA не будет работать."
fi
 
# ------------------------------------------------------------------------------
# Данные от пользователя
# ------------------------------------------------------------------------------
read -r -s -p "Введите токен бота (от @BotFather): " BOT_TOKEN
echo
read -r -p "Введите ваш Telegram ID (можно несколько через запятую): " ADMIN_ID
ADMIN_ID="${ADMIN_ID// /}"
 
[ -n "$BOT_TOKEN" ] && [ -n "$ADMIN_ID" ] || die "Токен и ID обязательны."
[[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || die "Токен выглядит неверно."
[[ "$ADMIN_ID" =~ ^-?[0-9]+(,-?[0-9]+)*$ ]] || die "Telegram ID должен состоять из цифр (несколько через запятую)."
 
echo -e "\n${YELLOW}Откройте вашего бота в Telegram и нажмите /start (иначе бот не сможет вам писать).${NC}"
read -r -p "Когда сделаете, нажмите Enter... " _
 
# ------------------------------------------------------------------------------
echo -e "\n${GREEN}[1/8] Установка системных зависимостей...${NC}"
apt-get update -q
apt-get install -y -q python3 python3-venv curl
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
  || die "Нужен Python 3.9 или новее."
 
echo -e "${GREEN}[2/8] Создание структуры директорий...${NC}"
systemctl stop ssh-tg-auth 2>/dev/null || true
mkdir -p "$INSTALL_DIR" "$SHM_DIR"
chmod 700 "$INSTALL_DIR" "$SHM_DIR"
cat > "$TMPFILES" <<EOF_TMP
d ${SHM_DIR} 0700 root root -
EOF_TMP
systemd-tmpfiles --create "$TMPFILES"
 
echo -e "${GREEN}[3/8] Настройка виртуального окружения Python...${NC}"
python3 -m venv "$INSTALL_DIR/venv"
"$INSTALL_DIR/venv/bin/pip" install -q --no-cache-dir \
  "python-telegram-bot==${PTB_VER}" "requests==${REQ_VER}" "python-dotenv==${DOTENV_VER}"
 
echo -e "${GREEN}[4/8] Создание конфигурации и скриптов...${NC}"
 
# IP сервера определяем один раз (а не при каждом входе)
SERVER_IP=$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}' || true)
[[ "$SERVER_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || SERVER_IP="unknown"
 
SECRET_KEY=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
 
(
  umask 077
  cat > "$INSTALL_DIR/.env" <<EOF_ENV
BOT_TOKEN=${BOT_TOKEN}
ADMIN_ID=${ADMIN_ID}
SECRET_KEY=${SECRET_KEY}
SERVER_IP=${SERVER_IP}
FAIL_SAFE=false
TIMEOUT=120
CACHE_SEC=60
MAX_FAILS=3
BLOCK_SEC=600
DISABLE_TTL_MIN=15
EOF_ENV
)
chmod 600 "$INSTALL_DIR/.env"
 
# --- pam_script.py (кавычки у EOF_PAM обязательны) ---
cat << 'EOF_PAM' > "$INSTALL_DIR/pam_script.py"
#!/opt/ssh-tg-auth/venv/bin/python
import os, sys, time, html, socket, secrets, hmac, hashlib, syslog, datetime
import requests
from dotenv import load_dotenv
 
BASE = "/opt/ssh-tg-auth"
DIR_SHM = "/dev/shm/ssh_tg_auth"
DISABLE_FLAG = f"{BASE}/2fa_disabled"
 
load_dotenv(f"{BASE}/.env")
BOT_TOKEN = os.getenv("BOT_TOKEN", "")
ADMIN_IDS = [x.strip() for x in os.getenv("ADMIN_ID", "").split(",") if x.strip()]
SECRET_KEY = os.getenv("SECRET_KEY", "")
FAIL_SAFE = os.getenv("FAIL_SAFE", "false").lower() == "true"
SERVER_IP = os.getenv("SERVER_IP", "unknown")
TIMEOUT = int(os.getenv("TIMEOUT", "120"))
CACHE_SEC = int(os.getenv("CACHE_SEC", "60"))
MAX_FAILS = int(os.getenv("MAX_FAILS", "3"))
BLOCK_SEC = int(os.getenv("BLOCK_SEC", "600"))
 
 
def log(level, msg):
    syslog.syslog(level, msg)
 
 
def hkey(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]
 
 
def generate_hmac(action, session_id):
    msg = f"{action}:{session_id}".encode("utf-8")
    return hmac.new(SECRET_KEY.encode("utf-8"), msg, hashlib.sha256).hexdigest()[:10]
 
 
def cleanup(session_id):
    for ext in ("pending", "accept", "reject"):
        try:
            os.remove(f"{DIR_SHM}/{session_id}.{ext}")
        except OSError:
            pass
 
 
def disable_left():
    """Сколько секунд ещё действует временное отключение 2FA (0 — не отключена)."""
    try:
        with open(DISABLE_FLAG) as f:
            expiry = int(f.read().strip())
    except (OSError, ValueError):
        return 0
    return max(0, expiry - int(time.time()))
 
 
def recent_fails(path):
    now = time.time()
    res = []
    try:
        with open(path) as f:
            for line in f:
                try:
                    t = float(line)
                except ValueError:
                    continue
                if now - t < BLOCK_SEC:
                    res.append(t)
    except OSError:
        pass
    return res
 
 
def record_fail(path):
    fails = recent_fails(path) + [time.time()]
    with open(path, "w") as f:
        f.write("\n".join(str(t) for t in fails) + "\n")
 
 
def send_to_admin(admin_id, payload):
    # В тексты ошибок requests попадает URL с токеном, поэтому пишем только тип ошибки.
    for _ in range(2):
        try:
            r = requests.post(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
                json={**payload, "chat_id": admin_id},
                timeout=10,
            )
            if r.status_code == 200:
                return True
            log(syslog.LOG_ERR, f"Telegram вернул HTTP {r.status_code} для {admin_id}")
        except requests.RequestException as e:
            log(syslog.LOG_ERR, f"Ошибка отправки Telegram для {admin_id}: {type(e).__name__}")
        time.sleep(1)
    return False
 
 
def main():
    syslog.openlog(ident="ssh-tg-auth", facility=syslog.LOG_AUTH)
    deny = 0 if FAIL_SAFE else 1  # код выхода при сбое
 
    if not (BOT_TOKEN and ADMIN_IDS and SECRET_KEY):
        log(syslog.LOG_ERR, "Неполная конфигурация .env")
        sys.exit(deny)
 
    left = disable_left()
    if left > 0:
        log(syslog.LOG_WARNING, f"2FA временно отключена через Telegram (ещё {left} с). Пропуск.")
        sys.exit(0)
    if os.path.exists(DISABLE_FLAG):
        try:
            os.remove(DISABLE_FLAG)  # срок истёк
        except OSError:
            pass
 
    pam_user = os.getenv("PAM_USER", "Unknown")
    pam_rhost = os.getenv("PAM_RHOST", "")
    if not pam_rhost or pam_rhost == "127.0.0.1":
        sys.exit(0)
 
    os.makedirs(DIR_SHM, mode=0o700, exist_ok=True)
    os.chmod(DIR_SHM, 0o700)
 
    cache_file = f"{DIR_SHM}/success_{hkey(pam_user + '@' + pam_rhost)}.cache"
    try:
        if time.time() - os.path.getmtime(cache_file) < CACHE_SEC:
            sys.exit(0)
    except OSError:
        pass
 
    fail_file = f"{DIR_SHM}/fails_{hkey(pam_rhost)}"
    if len(recent_fails(fail_file)) >= MAX_FAILS:
        log(syslog.LOG_WARNING, f"Слишком много отклонённых/просроченных запросов с {pam_rhost}. Блокировка.")
        sys.exit(1)
 
    session_id = secrets.token_hex(8)
    esc = html.escape
    current_time = datetime.datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
    text = (f"🚨 <b>Попытка SSH подключения</b>\n\n"
            f"<b>Сервер:</b> <code>{esc(socket.gethostname())}</code> ({esc(SERVER_IP)})\n"
            f"<b>Клиент:</b> <code>{esc(pam_rhost)}</code>\n"
            f"<b>Пользователь:</b> <code>{esc(pam_user)}</code>\n"
            f"<b>Время:</b> {esc(current_time)}\n\n"
            f"Примите или отклоните запрос (действует {TIMEOUT} с).")
 
    payload = {
        "text": text,
        "parse_mode": "HTML",
        "reply_markup": {
            "inline_keyboard": [[
                {"text": "✅ Принять", "callback_data": f"a:{session_id}:{generate_hmac('a', session_id)}"},
                {"text": "❌ Отклонить", "callback_data": f"r:{session_id}:{generate_hmac('r', session_id)}"},
            ]]
        },
    }
 
    open(f"{DIR_SHM}/{session_id}.pending", "w").close()
    log(syslog.LOG_INFO, f"Запрос авторизации для {pam_user} с {pam_rhost}. Session: {session_id}")
 
    sent = sum(1 for admin_id in ADMIN_IDS if send_to_admin(admin_id, payload))
    if sent == 0:
        cleanup(session_id)
        sys.exit(deny)
 
    start_time = time.time()
    while time.time() - start_time < TIMEOUT:
        if os.path.exists(f"{DIR_SHM}/{session_id}.accept"):
            log(syslog.LOG_INFO, f"Вход РАЗРЕШЕН для {pam_user} с {pam_rhost}")
            open(cache_file, "w").close()
            try:
                os.remove(fail_file)
            except OSError:
                pass
            cleanup(session_id)
            sys.exit(0)
        if os.path.exists(f"{DIR_SHM}/{session_id}.reject"):
            log(syslog.LOG_WARNING, f"Вход ОТКЛОНЕН для {pam_user} с {pam_rhost}")
            record_fail(fail_file)
            cleanup(session_id)
            sys.exit(1)
        time.sleep(1)
 
    log(syslog.LOG_WARNING, f"Таймаут ({TIMEOUT}с) для {pam_user} с {pam_rhost}")
    record_fail(fail_file)
    cleanup(session_id)
    sys.exit(1)
 
 
if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        syslog.openlog(ident="ssh-tg-auth", facility=syslog.LOG_AUTH)
        syslog.syslog(syslog.LOG_ERR, f"Непредвиденная ошибка: {type(e).__name__}")
        sys.exit(0 if FAIL_SAFE else 1)
EOF_PAM
 
# --- tg_bot.py ---
cat << 'EOF_BOT' > "$INSTALL_DIR/tg_bot.py"
#!/opt/ssh-tg-auth/venv/bin/python
import os, re, hmac, hashlib, time, glob, html, syslog, logging
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes
 
logging.basicConfig(level=logging.WARNING)
logging.getLogger("httpx").setLevel(logging.WARNING)  # httpx пишет URL с токеном на уровне INFO
 
BASE = "/opt/ssh-tg-auth"
DIR_SHM = "/dev/shm/ssh_tg_auth"
DISABLE_FLAG = f"{BASE}/2fa_disabled"
MAX_DISABLE_MIN = 60
 
load_dotenv(f"{BASE}/.env")
BOT_TOKEN = os.getenv("BOT_TOKEN", "")
ADMIN_IDS = [x.strip() for x in os.getenv("ADMIN_ID", "").split(",") if x.strip()]
SECRET_KEY = os.getenv("SECRET_KEY", "")
DISABLE_TTL_MIN = int(os.getenv("DISABLE_TTL_MIN", "15"))
 
HELP = "\n\nКоманды: /status, /disable [минуты], /enable, /unblock"
 
 
def generate_hmac(action, session_id):
    msg = f"{action}:{session_id}".encode("utf-8")
    return hmac.new(SECRET_KEY.encode("utf-8"), msg, hashlib.sha256).hexdigest()[:10]
 
 
def is_admin(user):
    return user is not None and str(user.id) in ADMIN_IDS
 
 
def log_event(user, text):
    syslog.syslog(syslog.LOG_WARNING, f"{text} (Telegram ID {user.id})")
 
 
def disable_left():
    try:
        with open(DISABLE_FLAG) as f:
            expiry = int(f.read().strip())
    except (OSError, ValueError):
        return 0
    return max(0, expiry - int(time.time()))
 
 
def write_flag(expiry):
    tmp = DISABLE_FLAG + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(expiry))
    os.chmod(tmp, 0o600)
    os.replace(tmp, DISABLE_FLAG)
 
 
async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        return
    left = disable_left()
    if left > 0:
        await update.message.reply_text(
            f"⚠️ <b>Статус:</b> 2FA временно отключена, осталось ~{(left + 59) // 60} мин.\n"
            f"Потом защита включится сама." + HELP, parse_mode="HTML")
    else:
        await update.message.reply_text(
            "🛡 <b>Статус:</b> 2FA включена\nСервер под защитой." + HELP, parse_mode="HTML")
 
 
async def cmd_disable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        return
    minutes = DISABLE_TTL_MIN
    if context.args:
        try:
            minutes = int(context.args[0])
        except ValueError:
            await update.message.reply_text(f"Использование: /disable [минуты, 1-{MAX_DISABLE_MIN}]")
            return
    minutes = max(1, min(MAX_DISABLE_MIN, minutes))
    write_flag(int(time.time()) + minutes * 60)
    log_event(update.effective_user, f"2FA отключена на {minutes} мин")
    await update.message.reply_text(
        f"⚠️ <b>2FA ОТКЛЮЧЕНА на {minutes} мин.</b>\n"
        f"Вход без подтверждения возможен до истечения срока, затем защита включится сама.",
        parse_mode="HTML")
 
 
async def cmd_enable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        return
    try:
        os.remove(DISABLE_FLAG)
    except OSError:
        pass
    log_event(update.effective_user, "2FA включена вручную")
    await update.message.reply_text("🛡 <b>2FA ВКЛЮЧЕНА</b>\nЗащита снова активна.", parse_mode="HTML")
 
 
async def cmd_unblock(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_admin(update.effective_user):
        return
    n = 0
    for p in glob.glob(f"{DIR_SHM}/fails_*"):
        try:
            os.remove(p)
            n += 1
        except OSError:
            pass
    log_event(update.effective_user, f"Сброс блокировок ({n})")
    await update.message.reply_text(f"Блокировок снято: {n}")
 
 
async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if not is_admin(query.from_user):
        await query.answer("У вас нет прав!", show_alert=True)
        return
 
    parts = (query.data or "").split(":")
    if len(parts) != 3:
        await query.answer("Неверный формат данных.")
        return
 
    action, session_id, req_mac = parts
    if action not in ("a", "r") or not re.fullmatch(r"[0-9a-f]{16}", session_id):
        await query.answer("Неверный формат данных.")
        return
    if not hmac.compare_digest(req_mac, generate_hmac(action, session_id)):
        await query.answer("Ошибка подписи HMAC.", show_alert=True)
        return
 
    pending_file = f"{DIR_SHM}/{session_id}.pending"
    if not os.path.exists(pending_file):
        await query.answer("Сессия истекла или обработана.", show_alert=True)
        return
 
    if action == "a":
        open(f"{DIR_SHM}/{session_id}.accept", "w").close()
        status_msg = f"✅ ДОСТУП РАЗРЕШЕН (ответил {query.from_user.first_name})"
    else:
        open(f"{DIR_SHM}/{session_id}.reject", "w").close()
        status_msg = f"❌ ДОСТУП ОТКЛОНЕН (ответил {query.from_user.first_name})"
 
    try:
        os.remove(pending_file)
    except OSError:
        pass
 
    base_text = getattr(query.message, "text_html", None) or ""
    new_text = f"{base_text}\n\n<b>Статус:</b> {html.escape(status_msg)}"
    await query.edit_message_text(text=new_text, parse_mode="HTML")
    await query.answer("Решение применено.")
 
 
def main():
    syslog.openlog(ident="ssh-tg-auth-bot", facility=syslog.LOG_AUTH)
    if not (BOT_TOKEN and ADMIN_IDS and SECRET_KEY):
        raise SystemExit("Неполная конфигурация .env")
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_status))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("disable", cmd_disable))
    app.add_handler(CommandHandler("enable", cmd_enable))
    app.add_handler(CommandHandler("unblock", cmd_unblock))
    app.add_handler(CallbackQueryHandler(button_handler))
    # drop_pending_updates: старые команды, накопившиеся пока бот был выключен, не выполняются
    app.run_polling(drop_pending_updates=True, allowed_updates=["message", "callback_query"])
 
 
if __name__ == "__main__":
    main()
EOF_BOT
 
chmod 700 "$INSTALL_DIR/pam_script.py" "$INSTALL_DIR/tg_bot.py"
 
cat << 'EOF_MD' > "$INSTALL_DIR/README.md"
# SSH Telegram 2FA
Команды в Telegram:
/status           - проверить состояние
/disable [минуты] - временно отключить 2FA (по умолчанию 15, максимум 60), потом включится сама
/enable           - включить 2FA сразу
/unblock          - снять блокировку IP после серии отклонённых/просроченных запросов
 
Настройки: /opt/ssh-tg-auth/.env (TIMEOUT, MAX_FAILS, BLOCK_SEC, CACHE_SEC, FAIL_SAFE, DISABLE_TTL_MIN)
Логи: journalctl -t ssh-tg-auth
 
Экстренно снять защиту (с консоли хостера или из рабочей сессии):
  sudo bash install-2fa.sh --uninstall
или
  sed -i '/pam_script.py/d' /etc/pam.d/sshd
EOF_MD
 
echo -e "${GREEN}[5/8] Проверка скриптов...${NC}"
"$INSTALL_DIR/venv/bin/python" -m py_compile "$INSTALL_DIR/pam_script.py" "$INSTALL_DIR/tg_bot.py"
"$INSTALL_DIR/venv/bin/python" -c "import telegram, requests, dotenv"
# Холостой запуск: localhost пропускается, но .env, импорты и shebang проверяются как при вызове из PAM
PAM_USER=root PAM_RHOST=127.0.0.1 "$INSTALL_DIR/pam_script.py" \
  || die "pam_script.py не запускается. PAM не тронут, смотрите: journalctl -t ssh-tg-auth"
 
echo -e "${GREEN}[6/8] Проверка связи с Telegram (тестовое сообщение)...${NC}"
"$INSTALL_DIR/venv/bin/python" - <<'EOF_TEST'
import os, sys, requests
from dotenv import load_dotenv
load_dotenv("/opt/ssh-tg-auth/.env")
token = os.getenv("BOT_TOKEN")
ok = True
for admin in [x.strip() for x in os.getenv("ADMIN_ID", "").split(",") if x.strip()]:
    try:
        r = requests.post(f"https://api.telegram.org/bot{token}/sendMessage",
                          json={"chat_id": admin, "text": "✅ SSH 2FA: тестовое сообщение. Установка продолжается."},
                          timeout=15)
        if r.status_code != 200:
            print(f"ID {admin}: HTTP {r.status_code} (проверьте токен и что вы нажали /start у бота)")
            ok = False
    except requests.RequestException as e:
        print(f"ID {admin}: ошибка {type(e).__name__}")
        ok = False
sys.exit(0 if ok else 1)
EOF_TEST
read -r -p "Тестовое сообщение пришло в Telegram? [y/N] " ANSWER
[[ "$ANSWER" =~ ^[Yy]$ ]] || die "Остановлено. PAM не тронут."
 
echo -e "${GREEN}[7/8] Настройка systemd службы...${NC}"
cat << 'EOF_SYS' > /etc/systemd/system/ssh-tg-auth.service
[Unit]
Description=SSH Telegram 2FA Bot
After=network.target
 
[Service]
Type=simple
User=root
WorkingDirectory=/opt/ssh-tg-auth
ExecStart=/opt/ssh-tg-auth/venv/bin/python /opt/ssh-tg-auth/tg_bot.py
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ReadWritePaths=/opt/ssh-tg-auth /dev/shm/ssh_tg_auth
 
[Install]
WantedBy=multi-user.target
EOF_SYS
 
systemctl daemon-reload
systemctl enable ssh-tg-auth
systemctl restart ssh-tg-auth
sleep 3
systemctl is-active --quiet ssh-tg-auth \
  || die "Служба не запустилась. PAM не тронут. Смотрите: journalctl -u ssh-tg-auth -n 50"
 
echo -e "${GREEN}[8/8] Интеграция в PAM (SSH)...${NC}"
cp -a "$PAM_FILE" "${PAM_FILE}.bak-ssh-tg-auth-$(date +%Y%m%d%H%M%S)"
if ! grep -q "pam_script.py" "$PAM_FILE"; then
  printf '\n%s\n' "$PAM_LINE" >> "$PAM_FILE"
  echo -e "${YELLOW}Хук добавлен в ${PAM_FILE} (резервная копия рядом)${NC}"
else
  echo -e "${CYAN}Хук уже присутствует в настройках PAM, пропускаем.${NC}"
fi
grep -q "pam_script.py" "$PAM_FILE" || die "Не удалось записать хук в ${PAM_FILE}."
 
echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}✅ УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e "${CYAN}=================================================${NC}"
echo -e "${YELLOW}ВАЖНО:${NC} не закрывайте эту SSH-сессию. Откройте НОВОЕ окно, подключитесь"
echo -e "и подтвердите вход в Telegram. Убедитесь, что у вас есть консоль/rescue у хостера."
echo -e "Команды бота: /status, /disable [мин], /enable, /unblock"
echo -e "Снять защиту: sudo bash $0 --uninstall"
 
