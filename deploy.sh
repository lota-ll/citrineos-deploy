#!/bin/bash
# ============================================================================
# CitrineOS Deployment Script
# ============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  CitrineOS CSMS Deployment Script"
echo "=============================================="
echo ""

# 1. Перевірка Docker
echo "[1/6] Перевірка Docker..."
if ! command -v docker &> /dev/null; then
    echo "⚠️  Docker не встановлено. Встановлюю..."
    curl -fsSL https://get.docker.com | sudo sh
    sudo apt install -y docker-compose-plugin
    sudo usermod -aG docker $USER
    echo ""
    echo "❗ Docker встановлено. Будь ласка:"
    echo "   1. Вийдіть з сесії: exit"
    echo "   2. Зайдіть знову"
    echo "   3. Запустіть цей скрипт повторно"
    exit 0
fi
echo "✅ Docker $(docker --version | grep -oP 'Docker version \K[0-9.]+')"

# 2. Перевірка Docker Compose
echo ""
echo "[2/6] Перевірка Docker Compose..."
if ! docker compose version &> /dev/null; then
    echo "❌ Docker Compose не знайдено"
    exit 1
fi
echo "✅ Docker Compose $(docker compose version --short)"

# 3. Перевірка файлів
echo ""
echo "[3/6] Перевірка файлів..."
MISSING=0

if [ ! -f "docker-compose.yml" ]; then
    echo "❌ docker-compose.yml не знайдено"
    MISSING=1
fi

if [ ! -f "data/config.json" ]; then
    echo "❌ data/config.json не знайдено"
    MISSING=1
fi

if [ ! -d "hasura-metadata" ]; then
    echo "❌ hasura-metadata/ не знайдено"
    MISSING=1
fi

if [ ! -d "citrineos-operator-ui" ]; then
    echo "❌ citrineos-operator-ui/ не знайдено"
    MISSING=1
fi

if [ $MISSING -eq 1 ]; then
    echo ""
    echo "❌ Деякі файли відсутні. Перевірте директорію."
    exit 1
fi
echo "✅ Всі файли на місці"

# 4. Створення .env для UI
echo ""
echo "[4/6] Налаштування змінних середовища..."
if [ ! -f "citrineos-operator-ui/.env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example citrineos-operator-ui/.env
        echo "✅ Створено citrineos-operator-ui/.env з .env.example"
    else
        echo "⚠️  .env.example не знайдено, створюю .env вручну..."
        cat > citrineos-operator-ui/.env << 'EOF'
VITE_HASURA_ADMIN_SECRET=CitrineOS!
VITE_API_URL=http://localhost:8090/v1/graphql
VITE_WS_URL=ws://localhost:8090/v1/graphql
VITE_CITRINE_CORE_URL=http://localhost:8080
VITE_FILE_SERVER_URL=http://localhost:9000
VITE_ADMIN_EMAIL=admin@citrineos.com
VITE_ADMIN_PASSWORD=P@ssword@1
EOF
        echo "✅ Створено citrineos-operator-ui/.env"
    fi
else
    echo "✅ citrineos-operator-ui/.env вже існує"
fi

# 5. Створення директорій для даних
echo ""
echo "[5/6] Створення директорій для даних..."
mkdir -p data/postgresql/pgdata
mkdir -p data/rabbitmq
mkdir -p data/minio
echo "✅ Директорії створено"

# 6. Запуск Docker Compose
echo ""
echo "[6/6] Запуск Docker Compose..."
echo ""

# Зупинити існуючі контейнери якщо є
docker compose down 2>/dev/null || true

# Запустити з build
docker compose up -d --build

# Очікування запуску
echo ""
echo "Очікування запуску сервісів..."
echo "(це може зайняти 2-5 хвилин)"
echo ""

# Функція перевірки здоров'я
wait_for_healthy() {
    local container=$1
    local max_attempts=$2
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        status=$(docker inspect --format='{{.State.Health.Status}}' $container 2>/dev/null || echo "not_found")
        
        if [ "$status" = "healthy" ]; then
            return 0
        fi
        
        echo "  ⏳ $container: $status (спроба $attempt/$max_attempts)"
        sleep 10
        attempt=$((attempt + 1))
    done
    
    return 1
}

# Очікуємо основні сервіси
echo "Очікування PostgreSQL..."
wait_for_healthy "citrine-postgres" 12 || echo "⚠️  PostgreSQL не готовий"

echo "Очікування RabbitMQ..."
wait_for_healthy "citrine-rabbitmq" 12 || echo "⚠️  RabbitMQ не готовий"

echo "Очікування CitrineOS Core..."
wait_for_healthy "citrine-core" 18 || echo "⚠️  CitrineOS Core не готовий"

echo "Очікування Hasura..."
wait_for_healthy "citrine-hasura" 24 || echo "⚠️  Hasura не готова"

# Фінальний статус
echo ""
echo "=============================================="
echo "  Статус контейнерів:"
echo "=============================================="
docker compose ps
echo ""

# Перевірка доступності
echo "=============================================="
echo "  Перевірка доступності:"
echo "=============================================="

if curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/docs 2>/dev/null | grep -q "200\|301\|302"; then
    echo "✅ CitrineOS API:    http://localhost:8080/docs"
else
    echo "⚠️  CitrineOS API:    http://localhost:8080/docs (не відповідає)"
fi

if curl -s -o /dev/null -w "%{http_code}" http://localhost:8090/healthz 2>/dev/null | grep -q "200"; then
    echo "✅ Hasura GraphQL:   http://localhost:8090/console"
else
    echo "⚠️  Hasura GraphQL:   http://localhost:8090/console (не відповідає)"
fi

if curl -s -o /dev/null -w "%{http_code}" http://localhost:3000 2>/dev/null | grep -q "200\|301\|302"; then
    echo "✅ CitrineOS UI:     http://localhost:3000"
else
    echo "⚠️  CitrineOS UI:     http://localhost:3000 (не відповідає)"
fi

echo ""
echo "=============================================="
echo "  🎉 РОЗГОРТАННЯ ЗАВЕРШЕНО!"
echo "=============================================="
echo ""
echo "Доступні сервіси:"
echo "  • CitrineOS UI:     http://localhost:3000"
echo "  • Hasura Console:   http://localhost:8090/console (пароль: CitrineOS!)"
echo "  • Swagger API:      http://localhost:8080/docs"
echo "  • RabbitMQ:         http://localhost:15672 (guest/guest)"
echo "  • MinIO:            http://localhost:9001 (minioadmin/minioadmin)"
echo ""
echo "OCPP WebSocket порти:"
echo "  • OCPP 1.6:         ws://localhost:8092/{ChargePointId}"
echo "  • OCPP 2.0.1:       ws://localhost:8081/{ChargePointId}"
echo ""
echo "Корисні команди:"
echo "  docker compose logs -f          # Логи всіх сервісів"
echo "  docker compose logs -f citrine  # Логи CitrineOS"
echo "  docker compose down             # Зупинити"
echo ""
