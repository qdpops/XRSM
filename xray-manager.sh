#!/bin/bash

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

XRAY_DIR="/opt/xray"
XRAY_CONFIG="$XRAY_DIR/config.json"
DOCKER_COMPOSE="$XRAY_DIR/docker-compose.yml"
TRAEFIK_DIR="/opt/traefik"
TRAEFIK_CONFIG="$TRAEFIK_DIR/traefik.yml"
TRAEFIK_COMPOSE="$TRAEFIK_DIR/docker-compose.yml"
DEFAULT_DEST_SITE="github.com:443"

# Функция для вывода цветного текста
print_color() {
    local color=$1
    shift
    echo -e "${color}$@${NC}"
}

# Функция генерации UUID
generate_uuid() {
    docker run --rm teddysun/xray:25.10.15 xray uuid 2>/dev/null
}

# Функция генерации shortId
generate_short_id() {
    openssl rand -hex 8
}

# Функция генерации ключей Reality
generate_reality_keys() {
    # Попробуем вывести ключи через контейнер xray
    local output

    output=$(docker run --rm teddysun/xray:25.10.15 xray x25519 2>/dev/null || true)

    if [[ -z "$output" ]]; then
        output=$(docker run --rm --entrypoint /usr/bin/xray teddysun/xray:25.10.15 x25519 2>/dev/null || true)
    fi

    if [[ -z "$output" ]]; then
        print_color $RED "Ошибка генерации ключей через Docker."
        return 1
    fi

    echo "$output"
    return 0
}

# Функция получения публичного ключа из приватного (попытка)
get_public_key() {
    local private_key=$1
    local output public_key

    # Попытка через xray
    output=$(docker run --rm teddysun/xray:25.10.15 xray x25519 -i "$private_key" 2>/dev/null || true)

    # Парсим "Password:" или "Public key:" или "PublicKey:"
    public_key=$(echo "$output" | awk '/Password:|Public key:|PublicKey:/{print $NF; exit}')

    if [[ -z "$public_key" ]]; then
        # fallback — если ничего не удалось, возвращаем исходный приватный ключ (не идеально, но полезно)
        public_key="$private_key"
    fi

    echo "$public_key"
}

# Установка Traefik
install_traefik() {
    print_color $BLUE "=== Настройка Traefik ==="

    # Проверка существования Traefik
    if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
        print_color $GREEN "✓ Traefik уже запущен"
        return 0
    fi

    print_color $YELLOW "Создание директории для Traefik..."
    mkdir -p "$TRAEFIK_DIR"

    # Создание конфигурации Traefik
    print_color $YELLOW "Создание конфигурации Traefik..."
    cat > "$TRAEFIK_CONFIG" <<EOF
api:
  dashboard: true
  insecure: true

entryPoints:
  web:
    address: ":80"
  https:
    address: ":443"

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: proxy

log:
  level: INFO
EOF

    # Создание docker-compose.yml для Traefik
    print_color $YELLOW "Создание docker-compose.yml для Traefik..."
    cat > "$TRAEFIK_COMPOSE" <<EOF
services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - proxy
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"
    volumes:
      - /etc/localtime:/etc/localtime:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - $TRAEFIK_DIR/traefik.yml:/traefik.yml:ro
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.traefik.entrypoints=web"
      - "traefik.http.routers.traefik.rule=Host(\`traefik.localhost\`)"
      - "traefik.http.services.traefik.loadbalancer.server.port=8080"

networks:
  proxy:
    external: true
EOF

    # Создание сети proxy если нет
    if ! docker network ls --format '{{.Name}}' | grep -q "^proxy$"; then
        print_color $YELLOW "Создание сети proxy..."
        docker network create proxy || true
    fi

    # Запуск Traefik
    print_color $YELLOW "Запуск Traefik..."
    cd "$TRAEFIK_DIR"
    docker compose up -d

    sleep 3

    if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
        print_color $GREEN "✓ Traefik успешно запущен"
        print_color $BLUE "Dashboard доступен на http://YOUR_SERVER_IP:8080"
        return 0
    else
        print_color $RED "✗ Ошибка запуска Traefik. Проверьте логи:"
        docker compose logs --tail=20
        return 1
    fi
}

# Установка Xray
install_xray() {
    print_color $BLUE "=== Установка Xray сервера ==="

    # Запрос данных
    read -p "Введите имя хоста вашего сервера (например, mydomain.com): " SERVER_DOMAIN
    read -p "Введите email первого пользователя: " FIRST_EMAIL
    read -p "Введите dest сайт для маскировки (по умолчанию $DEFAULT_DEST_SITE): " CUSTOM_DEST

    # Установка значений по умолчанию
    if [[ -z "$CUSTOM_DEST" ]]; then
        CUSTOM_DEST="$DEFAULT_DEST_SITE"
    fi

    # Проверка наличия обязательных полей
    if [[ -z "$SERVER_DOMAIN" ]] || [[ -z "$FIRST_EMAIL" ]]; then
        print_color $RED "Ошибка: имя хоста и email обязательны для заполнения!"
        exit 1
    fi

    print_color $YELLOW "Проверка установки Docker и Docker Compose..."
    if ! command -v docker &> /dev/null; then
        print_color $RED "Docker не установлен! Установите Docker и повторите попытку."
        exit 1
    fi

    if ! command -v docker compose &> /dev/null; then
        print_color $RED "Docker Compose не установлен! Установите Docker Compose и повторите попытку."
        exit 1
    fi

    # Проверка сети proxy
    print_color $YELLOW "Проверка сети proxy..."
    if ! docker network ls --format '{{.Name}}' | grep -q "^proxy$"; then
        print_color $YELLOW "Создание сети proxy..."
        docker network create proxy
    fi

    # Установка Traefik если его нет
    install_traefik
    if [ $? -ne 0 ]; then
        print_color $RED "Ошибка установки Traefik. Прерывание установки Xray."
        exit 1
    fi

    # Создание директории
    print_color $YELLOW "Создание директории $XRAY_DIR..."
    mkdir -p "$XRAY_DIR"

    # Генерация ключей и идентификаторов
    print_color $YELLOW "Генерация ключей и идентификаторов..."
    FIRST_UUID=$(generate_uuid)
    if [[ -z "$FIRST_UUID" ]]; then
        print_color $RED "Не удалось сгенерировать UUID"
        exit 1
    fi
    FIRST_SHORT_ID=$(generate_short_id)

    # Генерация Reality ключей
    print_color $YELLOW "Генерация Reality ключей..."
    KEYS_OUTPUT=$(generate_reality_keys)
    if [[ $? -ne 0 ]] || [[ -z "$KEYS_OUTPUT" ]]; then
        print_color $RED "Ошибка генерации reality ключей"
        exit 1
    fi

    # Парсинг ключей (ищем Private/PrivateKey и Public/Password/Public key)
    PRIVATE_KEY=$(echo "$KEYS_OUTPUT" | awk '/PrivateKey:|Private key:|PrivateKey:/{print $NF; exit}')
    PUBLIC_KEY=$(echo "$KEYS_OUTPUT" | awk '/Password:|Public key:|PublicKey:/{print $NF; exit}')

    # Фоллбек — если public пустой, пробуем извлечь через get_public_key
    if [[ -z "$PUBLIC_KEY" && -n "$PRIVATE_KEY" ]]; then
        PUBLIC_KEY=$(get_public_key "$PRIVATE_KEY")
    fi

    # Проверка что ключи не пустые
    if [[ -z "$PRIVATE_KEY" ]] || [[ -z "$PUBLIC_KEY" ]]; then
        print_color $RED "Ошибка парсинга ключей!"
        print_color $YELLOW "Вывод генерации ключей:"
        echo "$KEYS_OUTPUT"
        exit 1
    fi

    print_color $GREEN "Private Key: $PRIVATE_KEY"
    print_color $GREEN "Public Key: $PUBLIC_KEY"

    # Подготовим dest_domain (без порта) для serverNames и VLESS SNI
    DEST_DOMAIN=$(echo "$CUSTOM_DEST" | cut -d':' -f1)

    # Создание config.json
    print_color $YELLOW "Создание конфигурационного файла..."
    cat > "$XRAY_CONFIG" <<EOF
{
    "log": {
        "loglevel": "debug"
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": 9000,
            "protocol": "vless",
            "settings": {
                "clients": [
                    {
                        "id": "$FIRST_UUID",
                        "flow": "xtls-rprx-vision",
                        "email": "$FIRST_EMAIL"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "dest": "$CUSTOM_DEST",
                    "serverNames": [
                        "$DEST_DOMAIN"
                    ],
                    "privateKey": "$PRIVATE_KEY",
                    "shortIds": [
                        "$FIRST_SHORT_ID"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": [
                    "http",
                    "tls",
                    "quic"
                ],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom",
            "tag": "direct"
        }
    ]
}
EOF

    # Проверка что конфиг создан и содержит privateKey
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_color $RED "Ошибка: конфиг файл не создан!"
        exit 1
    fi

    # Проверка что privateKey не пустой в конфиге
    CONFIG_PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
    if [[ -z "$CONFIG_PRIVATE_KEY" ]] || [[ "$CONFIG_PRIVATE_KEY" == "null" ]]; then
        print_color $RED "Ошибка: privateKey пустой в конфиге!"
        print_color $YELLOW "Содержимое конфига:"
        cat "$XRAY_CONFIG"
        exit 1
    fi

    print_color $GREEN "✓ Конфигурация создана успешно"
    print_color $BLUE "Private Key в конфиге: $CONFIG_PRIVATE_KEY"

    # Создание docker-compose.yml для Xray (с правками меток Traefik для passthrough)
    print_color $YELLOW "Создание docker-compose.yml..."
    cat > "$DOCKER_COMPOSE" <<EOF
services:
  xray:
    image: teddysun/xray:25.10.15
    restart: unless-stopped
    networks:
      - proxy
    volumes:
      - $XRAY_DIR:/etc/xray
    environment:
      - v2ray.vmess.aead.forced=false
      - TZ=Europe/Moscow
    labels:
      - "traefik.enable=true"
      # TCP router для Reality (HostSNI должен совпадать с тем, что клиент передаёт в SNI)
      - "traefik.tcp.routers.xray.entrypoints=https"
      - "traefik.tcp.routers.xray.rule=HostSNI(\`$DEST_DOMAIN\`)"
      - "traefik.tcp.routers.xray.tls=true"
      - "traefik.tcp.routers.xray.tls.passthrough=true"
      - "traefik.tcp.services.xray.loadbalancer.server.port=9000"
networks:
  proxy:
    external: true
EOF

    # Запуск контейнера
    print_color $YELLOW "Запуск Xray контейнера..."
    cd "$XRAY_DIR"
    docker compose up -d

    # Проверка статуса
    sleep 3

    if docker compose ps | grep -E "Up|running" > /dev/null 2>&1; then
        print_color $GREEN "✓ Xray успешно установлен и запущен!"

        # Показываем последние логи для проверки
        print_color $YELLOW "\nПоследние строки логов:"
        docker compose logs --tail=5
    else
        print_color $RED "✗ Контейнер не запущен. Проверьте логи:"
        docker compose logs --tail=20
        exit 1
    fi

    # Сохранение данных для последующего использования
    echo "$PUBLIC_KEY" > "$XRAY_DIR/.public_key"
    echo "$SERVER_DOMAIN" > "$XRAY_DIR/.server_domain"
    echo "$CUSTOM_DEST" > "$XRAY_DIR/.dest_site"

    # Генерация VLESS ссылки (используем DEST_DOMAIN как sni)
    generate_vless_link "$FIRST_UUID" "$FIRST_EMAIL" "$SERVER_DOMAIN" "$PUBLIC_KEY" "$FIRST_SHORT_ID" "$DEST_DOMAIN"

    print_color $GREEN "\n=== Установка завершена! ==="
    print_color $BLUE "Server (traefik host): $SERVER_DOMAIN"
    print_color $BLUE "Dest (mask): $CUSTOM_DEST"
}

# Функция добавления нового пользователя
add_user() {
    print_color $BLUE "=== Добавление нового пользователя ==="

    # Проверка существования конфига
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_color $RED "Ошибка: Xray не установлен. Сначала выполните установку."
        return 1
    fi

    # Запрос email
    read -p "Введите email нового пользователя: " NEW_EMAIL

    if [[ -z "$NEW_EMAIL" ]]; then
        print_color $RED "Ошибка: email не может быть пустым!"
        return 1
    fi

    # Генерация UUID и shortId для нового пользователя
    print_color $YELLOW "Генерация UUID и shortId..."
    NEW_UUID=$(generate_uuid)
    NEW_SHORT_ID=$(generate_short_id)

    print_color $GREEN "UUID: $NEW_UUID"
    print_color $GREEN "ShortId: $NEW_SHORT_ID"

    # Добавление пользователя в конфиг
    print_color $YELLOW "Добавление пользователя в конфигурацию..."

    jq --arg uuid "$NEW_UUID" \
       --arg email "$NEW_EMAIL" \
       --arg shortid "$NEW_SHORT_ID" \
       '.inbounds[0].settings.clients += [{"id": $uuid, "flow": "xtls-rprx-vision", "email": $email}] |
        .inbounds[0].streamSettings.realitySettings.shortIds += [$shortid]' \
        "$XRAY_CONFIG" > "${XRAY_CONFIG}.tmp" || { print_color $RED "Ошибка при обновлении конфига"; return 1; }

    mv "${XRAY_CONFIG}.tmp" "$XRAY_CONFIG"

    # Перезапуск контейнера
    print_color $YELLOW "Перезапуск Xray контейнера..."
    cd "$XRAY_DIR"
    docker compose restart

    sleep 2

    if docker compose ps | grep -E "Up|running" > /dev/null 2>&1; then
        print_color $GREEN "✓ Пользователь успешно добавлен!"
    else
        print_color $RED "✗ Контейнер не запущен. Проверьте логи:"
        docker compose logs --tail=20
        return 1
    fi

    # Получение данных сервера
    SERVER_DOMAIN=$(cat "$XRAY_DIR/.server_domain" 2>/dev/null)
    if [[ -z "$SERVER_DOMAIN" ]]; then
        print_color $YELLOW "Не найден сохраненный домен. Используйте конфигурацию."
        SERVER_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG")
    fi

    # Получение PUBLIC_KEY
    PUBLIC_KEY=$(cat "$XRAY_DIR/.public_key" 2>/dev/null)
    if [[ -z "$PUBLIC_KEY" ]]; then
        PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")
        PUBLIC_KEY=$(get_public_key "$PRIVATE_KEY")
    fi

    # DEST_DOMAIN
    DEST_DOMAIN=$(jq -r '.inbounds[0].streamSettings.realitySettings.dest' "$XRAY_CONFIG" | cut -d':' -f1)

    # Генерация VLESS ссылки
    generate_vless_link "$NEW_UUID" "$NEW_EMAIL" "$SERVER_DOMAIN" "$PUBLIC_KEY" "$NEW_SHORT_ID" "$DEST_DOMAIN"
}

# Функция генерации VLESS ссылки
generate_vless_link() {
    local UUID=$1
    local EMAIL=$2
    local SERVER=$3
    local PUBLIC_KEY=$4
    local SHORT_ID=$5
    local DEST_DOMAIN=$6

    # Кодирование параметров для URL
    local ENCODED_EMAIL=$(printf %s "$EMAIL" | jq -sRr @uri)

    local VLESS_LINK="vless://${UUID}@${SERVER}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_DOMAIN}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp&headerType=none#${ENCODED_EMAIL}"

    print_color $GREEN "\n=========================================="
    print_color $GREEN "VLESS ссылка для пользователя: $EMAIL"
    print_color $GREEN "=========================================="
    echo "$VLESS_LINK"
    print_color $GREEN "=========================================="
    print_color $YELLOW "\nПараметры подключения:"
    print_color $YELLOW "UUID: $UUID"
    print_color $YELLOW "Server (host): $SERVER"
    print_color $YELLOW "Port: 443"
    print_color $YELLOW "SNI: $DEST_DOMAIN (домен маскировки)"
    print_color $YELLOW "Public Key: $PUBLIC_KEY"
    print_color $YELLOW "Short ID: $SHORT_ID"
    print_color $YELLOW "Flow: xtls-rprx-vision"
    print_color $YELLOW "========================================\n"
}

# Список пользователей
list_users() {
    print_color $BLUE "=== Список пользователей ==="

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_color $RED "Ошибка: Xray не установлен."
        return 1
    fi

    print_color $GREEN "\nТекущие пользователи:\n"

    local clients=$(jq -r '.inbounds[0].settings.clients' "$XRAY_CONFIG")
    local shortids=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds' "$XRAY_CONFIG")

    local count=$(echo "$clients" | jq 'length')

    for ((i=0; i<$count; i++)); do
        local email=$(echo "$clients" | jq -r ".[$i].email")
        local uuid=$(echo "$clients" | jq -r ".[$i].id")
        local shortid_index=$((i))  # соответствие индексов (мы не добавляем пустой элемент)
        local shortid=$(echo "$shortids" | jq -r ".[$shortid_index]")

        print_color $BLUE "Пользователь #$((i+1)):"
        echo "  Email: $email"
        echo "  UUID: $uuid"
        echo "  ShortID: $shortid"
        echo "---"
    done
}

# Статус
check_status() {
    print_color $BLUE "=== Статус Xray ==="

    if [[ ! -d "$XRAY_DIR" ]]; then
        print_color $RED "✗ Xray не установлен"
        return 1
    fi

    cd "$XRAY_DIR"

    if docker compose ps | grep -E "Up|running" > /dev/null 2>&1; then
        print_color $GREEN "✓ Xray работает"
        echo ""
        docker compose ps
        echo ""
        print_color $YELLOW "Последние 20 строк логов:"
        docker compose logs --tail=20
    else
        print_color $RED "✗ Xray не запущен"
        docker compose ps
        echo ""
        print_color $YELLOW "Логи:"
        docker compose logs --tail=20
    fi
}

# Просмотр логов
view_logs() {
    print_color $BLUE "=== Логи Xray ==="

    if [[ ! -d "$XRAY_DIR" ]]; then
        print_color $RED "✗ Xray не установлен"
        return 1
    fi

    cd "$XRAY_DIR"
    read -p "Сколько строк показать? (по умолчанию 50): " LINES
    LINES=${LINES:-50}

    docker compose logs --tail=$LINES -f
}

# Показать конфигурацию
show_config() {
    print_color $BLUE "=== Конфигурация Xray ==="

    if [[ ! -f "$XRAY_CONFIG" ]]; then
        print_color $RED "Ошибка: конфигурация не найдена."
        return 1
    fi

    cat "$XRAY_CONFIG"
}

# Главное меню
show_menu() {
    clear
    print_color $BLUE "========================================"
    print_color $BLUE "   Xray Reality Server Manager"
    print_color $BLUE "========================================"
    echo "1. Установить Xray сервер (с Traefik)"
    echo "2. Добавить нового пользователя"
    echo "3. Список пользователей"
    echo "4. Проверить статус"
    echo "5. Перезапустить Xray"
    echo "6. Остановить Xray"
    echo "7. Запустить Xray"
    echo "8. Просмотр логов"
    echo "9. Показать конфигурацию"
    echo "10. Проверить статус Traefik"
    echo "0. Выход"
    print_color $BLUE "========================================"
    read -p "Выберите действие: " choice

    case $choice in
        1) install_xray ;;
        2) add_user ;;
        3) list_users ;;
        4) check_status ;;
        5)
            print_color $YELLOW "Перезапуск Xray..."
            cd "$XRAY_DIR"
            docker compose restart
            print_color $GREEN "✓ Xray перезапущен"
            ;;
        6)
            print_color $YELLOW "Остановка Xray..."
            cd "$XRAY_DIR"
            docker compose stop
            print_color $GREEN "✓ Xray остановлен"
            ;;
        7)
            print_color $YELLOW "Запуск Xray..."
            cd "$XRAY_DIR"
            docker compose start
            print_color $GREEN "✓ Xray запущен"
            ;;
        8) view_logs ;;
        9) show_config ;;
        10)
            print_color $BLUE "=== Статус Traefik ==="
            if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
                print_color $GREEN "✓ Traefik работает"
                echo ""
                docker ps | grep traefik
                echo ""
                print_color $YELLOW "Последние 20 строк логов:"
                cd "$TRAEFIK_DIR"
                docker compose logs --tail=20
            else
                print_color $RED "✗ Traefik не запущен"
            fi
            ;;
        0)
            print_color $GREEN "Выход..."
            exit 0
            ;;
        *)
            print_color $RED "Неверный выбор!"
            ;;
    esac

    echo ""
    read -p "Нажмите Enter для продолжения..."
    show_menu
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   print_color $RED "Этот скрипт должен быть запущен с правами root (sudo)"
   exit 1
fi

# Проверка установки jq
if ! command -v jq &> /dev/null; then
    print_color $YELLOW "Установка jq..."
    apt update && apt install -y jq
fi

# Проверка установки openssl
if ! command -v openssl &> /dev/null; then
    print_color $YELLOW "Установка openssl..."
    apt update && apt install -y openssl
fi

# Запуск меню
show_menu
