
#!/bin/bash
# ==============================================================================
# Деинсталлятор SSH Telegram 2FA
#   sudo bash uninstall-2fa.sh              — полное удаление (с вопросом перед удалением файлов)
#   sudo bash uninstall-2fa.sh --keep-files — снять защиту, но оставить /opt/ssh-tg-auth
#   sudo bash uninstall-2fa.sh --yes        — без вопросов (для автоматизации)
# ==============================================================================
set -euo pipefail
 
INSTALL_DIR="/opt/ssh-tg-auth"
SHM_DIR="/dev/shm/ssh_tg_auth"
PAM_FILE="/etc/pam.d/sshd"
SERVICE="ssh-tg-auth"
UNIT_FILE="/etc/systemd/system/${SERVICE}.service"
TMPFILES="/etc/tmpfiles.d/ssh-tg-auth.conf"
 
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
 
die() { echo -e "${RED}ОШИБКА: $*${NC}" >&2; exit 1; }
 
KEEP_FILES=false
ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --keep-files) KEEP_FILES=true ;;
    --yes|-y)     ASSUME_YES=true ;;
    -h|--help)    sed -n '2,8p' "$0"; exit 0 ;;
    *)            die "Неизвестный параметр: $arg (см. --help)" ;;
  esac
done
 
[ "$EUID" -eq 0 ] || die "Запустите скрипт от имени root (sudo)."
 
echo -e "${CYAN}=================================================${NC}"
echo -e "${CYAN}      УДАЛЕНИЕ SSH TELEGRAM 2FA                  ${NC}"
echo -e "${CYAN}=================================================${NC}\n"
 
if [ "$ASSUME_YES" = false ]; then
  echo -e "${YELLOW}После удаления вход по SSH будет без подтверждения в Telegram.${NC}"
  read -r -p "Продолжить? [y/N] " ANSWER
  [[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "Отменено."; exit 0; }
fi
 
# ------------------------------------------------------------------------------
# 1. Сначала снимаем хук из PAM, чтобы SSH не зависел от остального
# ------------------------------------------------------------------------------
echo -e "${GREEN}[1/5] Удаление хука из ${PAM_FILE}...${NC}"
if [ -f "$PAM_FILE" ] && grep -q "pam_script.py" "$PAM_FILE"; then
  cp -a "$PAM_FILE" "${PAM_FILE}.bak-before-uninstall-$(date +%Y%m%d%H%M%S)"
  sed -i '/pam_script.py/d' "$PAM_FILE"
  if grep -q "pam_script.py" "$PAM_FILE"; then
    die "Не удалось убрать хук из ${PAM_FILE}. Удалите строку с pam_script.py вручную."
  fi
  echo "Хук удалён (резервная копия рядом)."
else
  echo "Хук в PAM не найден, пропускаем."
fi
 
# ------------------------------------------------------------------------------
# 2. Служба бота
# ------------------------------------------------------------------------------
echo -e "${GREEN}[2/5] Остановка и удаление службы ${SERVICE}...${NC}"
systemctl disable --now "$SERVICE" 2>/dev/null || true
rm -f "$UNIT_FILE"
systemctl daemon-reload
systemctl reset-failed "$SERVICE" 2>/dev/null || true
 
# ------------------------------------------------------------------------------
# 3. tmpfiles и временные данные
# ------------------------------------------------------------------------------
echo -e "${GREEN}[3/5] Удаление tmpfiles-конфига и временных файлов...${NC}"
rm -f "$TMPFILES"
[ -n "$SHM_DIR" ] && rm -rf "$SHM_DIR"
 
# ------------------------------------------------------------------------------
# 4. Файлы установки
# ------------------------------------------------------------------------------
echo -e "${GREEN}[4/5] Файлы в ${INSTALL_DIR}...${NC}"
if [ "$KEEP_FILES" = true ]; then
  echo "Оставлены по параметру --keep-files (там .env с токеном бота!)."
elif [ -d "$INSTALL_DIR" ]; then
  REMOVE=true
  if [ "$ASSUME_YES" = false ]; then
    read -r -p "Удалить ${INSTALL_DIR} (включая .env с токеном бота)? [y/N] " ANSWER
    [[ "$ANSWER" =~ ^[Yy]$ ]] || REMOVE=false
  fi
  if [ "$REMOVE" = true ]; then
    [ -n "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
    echo "Удалено."
  else
    echo "Оставлено. Удалить позже: rm -rf ${INSTALL_DIR}"
  fi
else
  echo "Каталог не найден, пропускаем."
fi
 
# ------------------------------------------------------------------------------
# 5. Проверка
# ------------------------------------------------------------------------------
echo -e "${GREEN}[5/5] Проверка...${NC}"
grep -q "pam_script.py" "$PAM_FILE" && die "Хук всё ещё в ${PAM_FILE}!"
systemctl is-active --quiet "$SERVICE" 2>/dev/null && die "Служба ${SERVICE} всё ещё активна!"
 
echo -e "\n${CYAN}=================================================${NC}"
echo -e "${GREEN}✅ 2FA УДАЛЕНА${NC}"
echo -e "${CYAN}=================================================${NC}"
echo "Уже открытые SSH-сессии не затронуты."
echo -e "${YELLOW}Что осталось сделать вручную:${NC}"
echo " - в @BotFather отозвать токен (/revoke) или удалить бота (/deletebot), если он больше не нужен;"
echo " - резервные копии PAM лежат рядом с ${PAM_FILE} (${PAM_FILE}.bak-*), удалите их, когда убедитесь, что всё работает."
 