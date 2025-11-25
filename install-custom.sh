#!/bin/bash

set -e

######################################################################################
#                                                                                    #
# Project 'pterodactyl-installer' (MODIFIED VERSION)                                 #
#                                                                                    #
# Этот скрипт автоматически применяет фиксы портов и NAT Loopback                    #
#                                                                                    #
######################################################################################

export GITHUB_SOURCE="v1.2.0"
export SCRIPT_RELEASE="v1.2.0"
export GITHUB_BASE_URL="https://raw.githubusercontent.com/pterodactyl-installer/pterodactyl-installer"

LOG_PATH="/var/log/pterodactyl-installer.log"

# --- БЛОК ЗАПРОСА ПОРТОВ ---
echo -e "\n################################################################################"
echo -e "# НАСТРОЙКА ПОРТОВ (MODIFIED INSTALLER)                                        #"
echo -e "################################################################################\n"

read -p "Введите порт для ПАНЕЛИ (по умолчанию 80, мы ставили 2963): " INPUT_PANEL_PORT
PANEL_PORT=${INPUT_PANEL_PORT:-80}

read -p "Введите порт для WINGS API (по умолчанию 8080, мы ставили 25896): " INPUT_WINGS_PORT
WINGS_PORT=${INPUT_WINGS_PORT:-8080}

read -p "Введите порт для WINGS SFTP (по умолчанию 2022, мы ставили 2772): " INPUT_SFTP_PORT
SFTP_PORT=${INPUT_SFTP_PORT:-2022}

echo -e "\nБудут использованы порты: Панель: $PANEL_PORT | Wings: $WINGS_PORT | SFTP: $SFTP_PORT"
echo -e "Установка продолжится через 3 секунды...\n"
sleep 3
# ---------------------------

# check for curl
if ! [ -x "$(command -v curl)" ]; then
  echo "* curl is required in order for this script to work."
  echo "* install using apt (Debian and derivatives) or yum/dnf (CentOS)"
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

  # 1. Фиксы для ПАНЕЛИ
  if [[ "$COMPONENT" == "panel" ]]; then
    if [ -f /etc/nginx/sites-available/pterodactyl.conf ]; then
        echo "[AUTO-FIX] Настройка Nginx порта на $PANEL_PORT..."
        # Меняем порт 80 на кастомный
        sed -i "s/listen 80;/listen $PANEL_PORT;/g" /etc/nginx/sites-available/pterodactyl.conf
        sed -i "s/listen \[::\]:80;/listen \[::\]:$PANEL_PORT;/g" /etc/nginx/sites-available/pterodactyl.conf
        
        # Исправляем ошибку проксирования (убираем remote из location)
        echo "[AUTO-FIX] Исправление проксирования Nginx..."
        sed -i 's/system|servers|remote/system|servers/g' /etc/nginx/sites-available/pterodactyl.conf
        
        # Обновляем APP_URL в .env если там нет порта
        if [ -f /var/www/pterodactyl/.env ]; then
             # Если порт не 80 и он еще не прописан в APP_URL
             if [[ "$PANEL_PORT" != "80" ]]; then
                 sed -i "s|APP_URL=http://.*|APP_URL=http://$EXT_IP:$PANEL_PORT|g" /var/www/pterodactyl/.env
                 cd /var/www/pterodactyl && php artisan config:clear && php artisan cache:clear
             fi
        fi

        systemctl reload nginx
    fi
    
    # Открываем порт панели
    ufw allow $PANEL_PORT/tcp > /dev/null 2>&1
    iptables -A INPUT -p tcp --dport $PANEL_PORT -j ACCEPT
  fi

  # 2. Фиксы для WINGS
  if [[ "$COMPONENT" == "wings" ]]; then
    echo "[AUTO-FIX] Настройка портов Wings..."
    
    # Открываем порты
    ufw allow $WINGS_PORT/tcp > /dev/null 2>&1
    ufw allow $SFTP_PORT/tcp > /dev/null 2>&1
    iptables -A INPUT -p tcp --dport $WINGS_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SFTP_PORT -j ACCEPT

    # Применяем NAT Loopback Fix (чтобы панель видела ноду по внешнему IP)
    echo "[AUTO-FIX] Применение NAT Loopback Fix..."
    iptables -t nat -A OUTPUT -d $EXT_IP -p tcp --dport $WINGS_PORT -j DNAT --to-destination 127.0.0.1:$WINGS_PORT
    
    # Сохраняем правила IPTABLES (простая попытка)
    if [ -x "$(command -v netfilter-persistent)" ]; then
        netfilter-persistent save
    fi

    # Правим config.yml если он есть (стандартный инсталлер может его не создать полностью)
    if [ -f /etc/pterodactyl/config.yml ]; then
        sed -i "s/port: 8080/port: $WINGS_PORT/g" /etc/pterodactyl/config.yml
        sed -i "s/bind_port: 2022/bind_port: $SFTP_PORT/g" /etc/pterodactyl/config.yml
        # Разрешаем все подключения к API (0.0.0.0)
        sed -i "s/host: 127.0.0.1/host: 0.0.0.0/g" /etc/pterodactyl/config.yml
        systemctl restart wings
    fi
  fi

  echo -e "[AUTO-FIX] Исправления для $COMPONENT завершены.\n"
}
# ---------------------------

execute() {
  echo -e "\n\n* pterodactyl-installer $(date) \n\n" >>$LOG_PATH

  [[ "$1" == *"canary"* ]] && export GITHUB_SOURCE="master" && export SCRIPT_RELEASE="canary"

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
    "Install both [0] and [1] on the same machine (wings script runs after panel)"
    "Install panel with canary version of the script"
    "Install Wings with canary version of the script"
    "Install both [3] and [4] on the same machine"
  )

  actions=(
    "panel"
    "wings"
    "panel;wings"
    "panel_canary"
    "wings_canary"
    "panel_canary;wings_canary"
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

# Remove lib.sh, so next time the script is run the, newest version is downloaded.
rm -rf /tmp/lib.sh