#!/bin/sh
# deploy.sh — автоматическое локальное развертывание приложения TaskBoard.
# Запуск: ./deploy.sh

set -eu   # остановка при ошибке команды и при использовании необъявленной переменной

# ---------- Настройки ----------
APP_NAME="taskboard"
REPOSITORY_URL="https://github.com/trewqryt/taskboard"
APP_MODULE="app.main:app"
APP_PORT="8000"
DB_NAME="taskboard"
DB_USER="taskboard"
DB_PASSWORD="taskboard"
DB_HOST="localhost"
DB_PORT="5432"

# Если скрипт лежит внутри репозитория — работаем в нём, иначе клонируем рядом
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    APP_DIR="$SCRIPT_DIR"
else
    APP_DIR="$PWD/$APP_NAME"
fi

# ---------- Вспомогательные функции ----------
log() { printf '[INFO] %s\n' "$*"; }
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

# sudo нужен только если мы не root
if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 || die "Нужны права root или установленный sudo"
    SUDO="sudo"
fi

