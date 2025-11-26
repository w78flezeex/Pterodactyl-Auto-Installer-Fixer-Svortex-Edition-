#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'pterodactyl-installer' (Svortex Edition - FIXED)                          #
#                                                                                    #
# Этот скрипт автоматически применяет фиксы портов, NAT и CORS.                      #
# Добавлена возможность исправления уже установленной системы.                       #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="v1.2.0"
export SCRIPT_RELEASE="v1.2.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"

LOG_PATH="/var/log/pterodactyl-installer.log"

# --- БЛОК ЗАПРОСА ПОРТОВ ---
echo -e "\n################################################################################"
echo -e "# НАСТРОЙКА ПОРТОВ (SVORTEX FIXER)                                             #"
echo -e "################################################################################\n"

read -p "Введите порт для ПАНЕЛИ (по умолчанию 80, мы ставили 2963): " INPUT_PANEL_PORT
PANEL_PORT=${INPUT_PANEL_PORT:-80}

read -p "Введите порт для WINGS API (по умолчанию 8080, мы ставили 25896): " INPUT_WINGS_PORT
WINGS_PORT=${INPUT_WINGS_PORT:-8080}

read -p "Введите порт для WINGS SFTP (по умолчанию 2022, мы ставили 2772): " INPUT_SFTP_PORT
SFTP_PORT=${INPUT_SFTP_PORT:-2022}

echo -e "\nБудут использованы порты: Панель: $PANEL_PORT | Wings: $WINGS_PORT | SFTP: $SFTP_PORT"
echo -e "Установка/Исправление начнется через 3 секунды...\n"
sleep 3
# ---------------------------

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  exit 1
fi

# Always remove lib.sh, before downloading it
[ -f /tmp/lib.sh ] && rm -rf /tmp/lib.sh
curl -sSL -o /tmp/lib.sh "$GITHUB_BASE_URL"/master/lib/lib.sh

# shellcheck source=lib/lib.sh
source /tmp/lib.sh

# --- ФУНКЦИЯ АВТО-ФИКСОВ ---
apply_custom_fixes() {
  local COMPONENT=$1
  local EXT_IP=$(curl -s https://ipinfo.io/ip || curl -s ifconfig.me)

  echo -e "\n[AUTO-FIX] Применяю исправления для $COMPONENT..."

  # === 1. Фиксы для ПАНЕЛИ ===
  if [[ "$COMPONENT" == "panel" ]]; then
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        echo "[AUTO-FIX] Настройка Nginx порта на $PANEL_PORT..."
        
        # Меняем порты в Nginx
        sed -i "s/listen .*; # ssl/listen $PANEL_PORT; # ssl/g" /etc/nginx/sites-available/pterodactyl.conf || true
        sed -i "s/listen 80;/listen $PANEL_PORT;/g" /etc/nginx/sites-available/pterodactyl.conf
        sed -i "s/listen \[::\]:80;/listen \[::\]:$PANEL_PORT;/g" /etc/nginx/sites-available/pterodactyl.conf
        
        # Исправляем ошибку проксирования
        sed -i 's/system|servers|remote/system|servers/g' /etc/nginx/sites-available/pterodactyl.conf
        
        # Обновляем APP_URL в .env (КРИТИЧНО ВАЖНО С ПОРТОМ)
        if [ -f /var/www/pterodactyl/.env ]; then
             echo "[AUTO-FIX] Обновление APP_URL в .env..."
             # Сначала убираем порт если он был, потом ставим новый, чтобы не дублировать
             sed -i "s|APP_URL=http://.*|APP_URL=http://$EXT_IP:$PANEL_PORT|g" /var/www/pterodactyl/.env
             
             cd /var/www/pterodactyl
             php artisan config:clear || true
             php artisan cache:clear || true
             php artisan route:clear || true
             php artisan queue:restart || true
        fi

        systemctl reload nginx
    fi
    
    # Открываем порт панели
    ufw allow $PANEL_PORT/tcp > /dev/null 2>&1
    iptables -A INPUT -p tcp --dport $PANEL_PORT -j ACCEPT
  fi

  # === 2. Фиксы для WINGS ===
  if [[ "$COMPONENT" == "wings" ]]; then
    echo "[AUTO-FIX] Настройка конфигурации Wings..."
    
    CONFIG_FILE="/etc/pterodactyl/config.yml"
    
    # Открываем порты
    ufw allow $WINGS_PORT/tcp > /dev/null 2>&1
    ufw allow $SFTP_PORT/tcp > /dev/null 2>&1
    iptables -A INPUT -p tcp --dport $WINGS_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SFTP_PORT -j ACCEPT

    if [ -f "$CONFIG_FILE" ]; then
        # 1. Меняем порты
        sed -i "s/port: .*/port: $WINGS_PORT/g" "$CONFIG_FILE"
        sed -i "s/bind_port: .*/bind_port: $SFTP_PORT/g" "$CONFIG_FILE"
        
        # 2. Разрешаем слушать всё
        sed -i "s/host: 127.0.0.1/host: 0.0.0.0/g" "$CONFIG_FILE"
        
        # 3. КРИТИЧЕСКИЙ ФИКС: Локальное соединение с панелью
        # Это решает проблему "Deadline Exceeded" лучше, чем iptables
        echo "[AUTO-FIX] Переключение Remote на локальный адрес..."
        sed -i "s|remote: .*|remote: http://127.0.0.1:$PANEL_PORT|g" "$CONFIG_FILE"
        
        # 4. КРИТИЧЕСКИЙ ФИКС: CORS (Разрешенные источники)
        # Нужно, чтобы браузер мог общаться с нодой, даже если remote=127.0.0.1
        echo "[AUTO-FIX] Добавление allowed_origins..."
        # Удаляем старую строку если есть
        grep -v "allowed_origins:" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        # Добавляем новую
        echo "allowed_origins:" >> "$CONFIG_FILE"
        echo "  - \"http://$EXT_IP:$PANEL_PORT\"" >> "$CONFIG_FILE"
        
        systemctl restart wings
    else
        echo "[WARNING] Файл $CONFIG_FILE не найден! Сначала установите Wings."
    fi
  fi

  echo -e "[AUTO-FIX] Исправления для $COMPONENT завершены.\n"
}
# ---------------------------

execute() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >>$LOG_PATH

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="master" && export SCRIPT_RELEASE="canary"

  # Если выбран режим ТОЛЬКО ФИКС (без установки)
  if [[ "$1" == "fix_only" ]]; then
      echo "Запуск режима исправления существующей установки..."
      apply_custom_fixes "panel"
      apply_custom_fixes "wings"
      echo "Все исправления применены. Проверьте панель через минуту."
      return
  fi

  update_lib_source

  # Запускаем оригинальный установщик
  run_ui "${1//_canary/}" |& tee -a $LOG_PATH

  # --- ЗАПУСК ФИКСОВ ПОСЛЕ УСТАНОВКИ ---
  if [[ "$1" == *"panel"* ]]; then
      apply_custom_fixes "panel"
  fi
  if [[ "$1" == *"wings"* ]]; then
      apply_custom_fixes "wings"
  fi
  # -------------------------------------

  if [[ -n $2 ]]; then
    echo -e -n "* Installation of $1 completed. Do you want to proceed to $2 installation? (y/N): "
    read -r CONFIRM
    if [[ "$CONFIRM" =~ [Yy] ]]; then
      execute "$2"
    else
      error "Installation of $2 aborted."
      exit 1
    fi
  fi
}

welcome ""

done=false

while [ "$done" == false ]; do
  options=(
    "Install the panel"
    "Install Wings"
    "Install both [0] and [1] on the same machine"
    "Install panel with canary version"
    "Install Wings with canary version"
    "Install both [3] and [4] on the same machine"
    "Repair/Update Ports (Apply fixes to EXISTING installation)"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    "panel_canary"
    "wings_canary"
    "panel_canary;wings_canary"
    "fix_only"
  )

  output "What would you like to do?"

  for i in "${!options[@]}"; do
    output "[$i] ${options[$i]}"
  done

  echo -n "* Input 0-$((${#actions[@]} - 1)): "
  read -r action

  [ -z "$action" ] && error "Input is required" && continue

  valid_input=("$(for ((i = 0; i <= ${#actions[@]} - 1; i += 1)); do echo "${i}"; done)")

  [[ ! " ${valid_input[*]} " =~ ${action} ]] && error "Invalid option"

  [[ " ${valid_input[*]} " =~ ${action} ]] && done=true && IFS=";" read -r i1 i2 <<<"${actions[$action]}" && execute "$i1" "$i2"

done

# Remove lib.sh
rm -rf /tmp/lib.sh
