#!/bin/bash
# ==============================================================================
# Автоустановщик SSH Telegram 2FA (Debian / Ubuntu)
# ==============================================================================

# Цвета для вывода
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Пожалуйста, запустите скрипт от имени root (sudo).${NC}"
  exit 1
fi

apt-get install -y -q python3 python3-venv python3-pip curl
pip install -q python-telegram-bot requests python-dotenv


echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}      УСТАНОВКА SSH TELEGRAM 2FA СИСТЕМЫ         ${NC}"
echo -e "${CYAN}=================================================${NC}\n"

# 1. Запрашиваем данные у пользователя
read -p "Введите токен бота (от @BotFather): " BOT_TOKEN
read -p "Введите ваш Telegram ID (можно несколько через запятую): " ADMIN_ID

if [ -z "$BOT_TOKEN" ] || [ -z "$ADMIN_ID" ]; then
    echo -e "${RED}Ошибка: Токен и ID обязательны!${NC}"
    exit 1
fi

# Генерируем случайный секретный ключ
SECRET_KEY=$(head -c 32 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 20)

echo -e "\n${GREEN}[1/6] Установка системных зависимостей...${NC}"
apt-get update -q
apt-get install -y -q python3 python3-venv python3-pip curl

echo -e "${GREEN}[2/6] Создание структуры директорий...${NC}"
mkdir -p /opt/ssh-tg-auth
mkdir -p /dev/shm/ssh_tg_auth
chmod 700 /opt/ssh-tg-auth /dev/shm/ssh_tg_auth

echo -e "${GREEN}[3/6] Настройка виртуального окружения Python...${NC}"
python3 -m venv /opt/ssh-tg-auth/venv
/opt/ssh-tg-auth/venv/bin/pip install -q python-telegram-bot requests python-dotenv

echo -e "${GREEN}[4/6] Создание конфигурации и скриптов...${NC}"

# Создаем .env (здесь кавычки у EOF не ставим, чтобы переменные развернулись)
cat << EOF_ENV > /opt/ssh-tg-auth/.env
BOT_TOKEN=$BOT_TOKEN
ADMIN_ID=$ADMIN_ID
SECRET_KEY=$SECRET_KEY
FAIL_SAFE=false
EOF_ENV
chmod 600 /opt/ssh-tg-auth/.env

# Создаем pam_script.py (кавычки у EOF_PAM обязательны, чтобы не поломать Python код)
cat << 'EOF_PAM' > /opt/ssh-tg-auth/pam_script.py
#!/opt/ssh-tg-auth/venv/bin/python
import os, sys, time, requests, secrets, hmac, hashlib, syslog, datetime, subprocess
from dotenv import load_dotenv

DIR_SHM = "/dev/shm/ssh_tg_auth"
DISABLE_FLAG = "/opt/ssh-tg-auth/2fa_disabled"
os.makedirs(DIR_SHM, exist_ok=True)

load_dotenv("/opt/ssh-tg-auth/.env")
BOT_TOKEN = os.getenv("BOT_TOKEN")
ADMIN_IDS =[x.strip() for x in os.getenv("ADMIN_ID", "").split(",") if x.strip()]
SECRET_KEY = os.getenv("SECRET_KEY", "default_secret")
FAIL_SAFE = os.getenv("FAIL_SAFE", "false").lower() == "true"

def generate_hmac(action, session_id):
    msg = f"{action}:{session_id}".encode('utf-8')
    return hmac.new(SECRET_KEY.encode('utf-8'), msg, hashlib.sha256).hexdigest()[:10]

def cleanup(session_id):
    for ext in['pending', 'accept', 'reject']:
        try: os.remove(f"{DIR_SHM}/{session_id}.{ext}")
        except OSError: pass

def main():
    syslog.openlog(ident="ssh-tg-auth", facility=syslog.LOG_AUTH)
    
    if os.path.exists(DISABLE_FLAG):
        syslog.syslog(syslog.LOG_INFO, "2FA временно отключена через Telegram. Пропуск.")
        sys.exit(0)

    if subprocess.call(['systemctl', 'is-active', '--quiet', 'ssh-tg-auth']) != 0:
        syslog.syslog(syslog.LOG_INFO, "Бот остановлен (systemctl stop). Пропуск 2FA.")
        sys.exit(0)

    pam_user = os.getenv("PAM_USER", "Unknown")
    pam_rhost = os.getenv("PAM_RHOST", "127.0.0.1")
    
    if not pam_rhost or pam_rhost == "127.0.0.1":
        sys.exit(0)

    cache_file = f"{DIR_SHM}/success_{pam_user}_{pam_rhost}.cache"
    if os.path.exists(cache_file):
        if time.time() - os.path.getmtime(cache_file) < 60:
            sys.exit(0)

    session_id = secrets.token_hex(8)
    geoip = "Неизвестно"
    try:
        res = requests.get(f"http://ip-api.com/json/{pam_rhost}?lang=ru", timeout=2).json()
        if res.get("status") == "success":
            geoip = f"{res.get('country')}, {res.get('city')}"
    except: pass

    server_ip = "Неизвестно"
    try: server_ip = requests.get("https://api.ipify.org", timeout=2).text.strip()
    except: pass

    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    text = (f"🚨 <b>Попытка SSH подключения</b>\n\n"
            f"<b>Сервер:</b> <code>{server_ip}</code>\n"
            f"<b>Клиент:</b> <code>{pam_rhost}</code>\n"
            f"<b>Пользователь:</b> <code>{pam_user}</code>\n"
            f"<b>Локация:</b> {geoip}\n"
            f"<b>Время:</b> {current_time}\n\n"
            f"Примите или отклоните запрос.")

    mac_acc = generate_hmac("a", session_id)
    mac_rej = generate_hmac("r", session_id)

    payload = {
        "text": text,
        "parse_mode": "HTML",
        "reply_markup": {
            "inline_keyboard": [[
                {"text": "✅ Принять", "callback_data": f"a:{session_id}:{mac_acc}"},
                {"text": "❌ Отклонить", "callback_data": f"r:{session_id}:{mac_rej}"}
            ]]
        }
    }

    open(f"{DIR_SHM}/{session_id}.pending", "w").close()
    syslog.syslog(syslog.LOG_INFO, f"Запрос авторизации для {pam_user} с {pam_rhost}. Session: {session_id}")

    success_sends = 0
    for admin_id in ADMIN_IDS:
        payload["chat_id"] = admin_id
        try:
            resp = requests.post(f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage", json=payload, timeout=5)
            resp.raise_for_status()
            success_sends += 1
        except Exception as e:
            syslog.syslog(syslog.LOG_ERR, f"Ошибка отправки Telegram админу {admin_id}: {e}")
    
    if success_sends == 0:
        cleanup(session_id)
        sys.exit(0 if FAIL_SAFE else 1)

    timeout = 120
    start_time = time.time()
    while time.time() - start_time < timeout:
        if os.path.exists(f"{DIR_SHM}/{session_id}.accept"):
            syslog.syslog(syslog.LOG_INFO, f"Вход РАЗРЕШЕН для {pam_user} с {pam_rhost}")
            open(cache_file, "w").close()
            cleanup(session_id)
            sys.exit(0)
        if os.path.exists(f"{DIR_SHM}/{session_id}.reject"):
            syslog.syslog(syslog.LOG_WARNING, f"Вход ОТКЛОНЕН для {pam_user} с {pam_rhost}")
            cleanup(session_id)
            sys.exit(1)
        time.sleep(1)

    syslog.syslog(syslog.LOG_WARNING, f"Таймаут (120с) для {pam_user} с {pam_rhost}")
    cleanup(session_id)
    sys.exit(1)

if __name__ == "__main__":
    main()
EOF_PAM

# Создаем tg_bot.py
cat << 'EOF_BOT' > /opt/ssh-tg-auth/tg_bot.py
#!/opt/ssh-tg-auth/venv/bin/python
import os, hmac, hashlib
from dotenv import load_dotenv
from telegram import Update
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes

DIR_SHM = "/dev/shm/ssh_tg_auth"
DISABLE_FLAG = "/opt/ssh-tg-auth/2fa_disabled"
load_dotenv("/opt/ssh-tg-auth/.env")
BOT_TOKEN = os.getenv("BOT_TOKEN")
ADMIN_IDS =[x.strip() for x in os.getenv("ADMIN_ID", "").split(",") if x.strip()]
SECRET_KEY = os.getenv("SECRET_KEY", "default_secret")

def generate_hmac(action, session_id):
    msg = f"{action}:{session_id}".encode('utf-8')
    return hmac.new(SECRET_KEY.encode('utf-8'), msg, hashlib.sha256).hexdigest()[:10]

async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.message.from_user.id) not in ADMIN_IDS: return
    if os.path.exists(DISABLE_FLAG):
        await update.message.reply_text("⚠️ <b>Статус:</b> 2FA Отключена\nВход по SSH свободный.", parse_mode="HTML")
    else:
        await update.message.reply_text("🛡 <b>Статус:</b> 2FA Включена\nСервер под защитой.", parse_mode="HTML")

async def cmd_disable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.message.from_user.id) not in ADMIN_IDS: return
    open(DISABLE_FLAG, "w").close()
    await update.message.reply_text("⚠️ <b>2FA ОТКЛЮЧЕНА</b>\nТеперь на сервер можно зайти без подтверждения.", parse_mode="HTML")

async def cmd_enable(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if str(update.message.from_user.id) not in ADMIN_IDS: return
    try: os.remove(DISABLE_FLAG)
    except OSError: pass
    await update.message.reply_text("🛡 <b>2FA ВКЛЮЧЕНА</b>\nЗащита снова активирована.", parse_mode="HTML")

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    if str(query.from_user.id) not in ADMIN_IDS:
        await query.answer("У вас нет прав!", show_alert=True)
        return

    parts = query.data.split(':')
    if len(parts) != 3:
        await query.answer("Неверный формат данных.")
        return

    action, session_id, req_mac = parts
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

    try: os.remove(pending_file)
    except OSError: pass

    new_text = f"{query.message.text}\n\n<b>Статус:</b> {status_msg}"
    await query.edit_message_text(text=new_text, parse_mode="HTML")
    await query.answer("Решение применено.")

def main():
    app = Application.builder().token(BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", cmd_status))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("disable", cmd_disable))
    app.add_handler(CommandHandler("enable", cmd_enable))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.run_polling()

if __name__ == "__main__":
    main()
EOF_BOT

chmod +x /opt/ssh-tg-auth/pam_script.py
chmod +x /opt/ssh-tg-auth/tg_bot.py

# Создаем README.md
cat << 'EOF_MD' > /opt/ssh-tg-auth/README.md
# 🛡️ SSH Telegram 2FA (Двухфакторная аутентификация)
Команды в ТГ:
/status - Проверить работу
/disable - Выключить 2FA
/enable - Включить 2FA

Если нужно удалить защиту экстренно:
sed -i '/pam_script.py/d' /etc/pam.d/sshd
EOF_MD

echo -e "${GREEN}[5/6] Настройка systemd службы...${NC}"
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

[Install]
WantedBy=multi-user.target
EOF_SYS

systemctl daemon-reload
systemctl enable --now ssh-tg-auth

echo -e "${GREEN}[6/6] Интеграция в PAM (SSH)...${NC}"
if ! grep -q "pam_script.py" /etc/pam.d/sshd; then
    echo "account required pam_exec.so quiet /opt/ssh-tg-auth/pam_script.py" >> /etc/pam.d/sshd
    echo -e "${YELLOW}Хук успешно добавлен в /etc/pam.d/sshd${NC}"
else
    echo -e "${CYAN}Хук уже присутствует в настройках PAM, пропускаем.${NC}"
fi

echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}✅ УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo -e "${CYAN}=================================================${NC}"
echo -e "Теперь зайдите в вашего Telegram-бота и напишите команду ${YELLOW}/start${NC}"
echo -e "⚠️ ВАЖНО: Не закрывайте эту сессию SSH! Откройте новое окно и проверьте вход."