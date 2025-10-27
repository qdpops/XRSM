# 🚀 Xray Reality Server Manager

**Xray Reality Server Manager** — это автоматизированный Bash-скрипт для быстрой установки и управления Xray-сервером с обратным прокси **Traefik (v3.2)**.  
Он создаёт полное окружение на Docker, настраивает TLS passthrough для Xray и предоставляет удобное интерактивное меню для управления сервером.

---

## ✨ Основные возможности

✅ Автоматическая установка **Xray + Traefik**  
✅ Настройка TLS passthrough через Traefik  
✅ Добавление, удаление и просмотр пользователей  
✅ Просмотр логов и состояния сервисов  
✅ Перезапуск, остановка и запуск контейнеров  
✅ Генерация `docker-compose.yml` и `traefik.yml`  
✅ Поддержка кастомного домена `$SERVER_DOMAIN`

---

## 🐳 Требования

- Linux (Ubuntu / Debian / CentOS)
- Docker и Docker Compose
- Права суперпользователя (root)

---

## ⚙️ Установка

```bash
git clone https://github.com/yourusername/xray-reality-manager.git
cd xray-reality-manager
chmod +x setup.sh
./setup.sh
```

---

## 🧭 Меню управления

```text
========================================
   Xray Reality Server Manager
========================================
1. Установить Xray сервер (с Traefik)
2. Добавить нового пользователя
3. Список пользователей
4. Проверить статус
5. Перезапустить Xray
6. Остановить Xray
7. Запустить Xray
8. Просмотр логов
9. Показать конфигурацию
10. Проверить статус Traefik
0. Выход
========================================
```

---

## 🧠 Пример работы

![Screenshot](https://repository-images.githubusercontent.com/1076750715/0a0438be-b345-48cd-94d7-db18f8c540f3)

---

## 🪪 Лицензия

Проект распространяется под лицензией **MIT License**.

---

© 2025 Xray Reality Server Manager by [yourusername]
