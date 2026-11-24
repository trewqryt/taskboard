
#!/bin/sh
# TaskBoard - Automatic Deployment Script
# Ubuntu / Debian

set -eu

# ==========================================
# 1. CONFIGURATION
# ==========================================

APP_NAME="taskboard"
REPOSITORY_URL="https://github.com/trewqryt/taskboard.git"
APP_MODULE="app.main:app"
APP_PORT="8000"

DB_NAME="taskboard"
DB_USER="taskboard"
DB_PASSWORD="taskboard"
DB_HOST="localhost"
DB_PORT="5432"

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ -f "$SCRIPT_DIR/requirements.txt" ]; then
    APP_DIR="$SCRIPT_DIR"
else
    APP_DIR="$PWD/$APP_NAME"
fi

log() {
    printf '[INFO] %s\n' "$1"
}

die() {
    printf '[ERROR] %s\n' "$1" >&2
    exit 1
}

# ==========================================
# 2. CHECK SUDO
# ==========================================

if [ "$(id -u)" -eq 0 ]; then
    SUDO=""
else
    command -v sudo >/dev/null 2>&1 ||
        die "sudo is not installed"
    SUDO="sudo"
fi

# ==========================================
# 3. INSTALL SYSTEM PACKAGES
# ==========================================

log "Checking system packages..."

command -v apt-get >/dev/null 2>&1 ||
    die "This script requires Ubuntu or Debian"

PACKAGES=""

command -v git >/dev/null 2>&1 ||
    PACKAGES="$PACKAGES git"

command -v python3 >/dev/null 2>&1 ||
    PACKAGES="$PACKAGES python3"

command -v curl >/dev/null 2>&1 ||
    PACKAGES="$PACKAGES curl"

command -v psql >/dev/null 2>&1 ||
    PACKAGES="$PACKAGES postgresql"

# PostgreSQL server must also be installed
if ! command -v pg_lsclusters >/dev/null 2>&1; then
    PACKAGES="$PACKAGES postgresql"
fi

# Check Python pip
if ! python3 -m pip --version >/dev/null 2>&1; then
    PACKAGES="$PACKAGES python3-pip"
fi

# Check Python venv and ensurepip
if ! python3 -c "import venv, ensurepip" \
    >/dev/null 2>&1; then
    PACKAGES="$PACKAGES python3-venv"
fi

# Check the actual ability to create a venv
if command -v python3 >/dev/null 2>&1; then
    TEST_VENV=$(mktemp -d)

    if ! python3 -m venv "$TEST_VENV" \
        >/dev/null 2>&1; then

        PACKAGES="$PACKAGES python3-venv"
    fi

    rm -rf "$TEST_VENV"
fi

if [ -n "$PACKAGES" ]; then
    log "Installing missing packages..."

    $SUDO apt-get update

    # Intentional word splitting for package names
    # shellcheck disable=SC2086
    $SUDO env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y $PACKAGES ||
        die "Package installation failed"
else
    log "All system packages are installed"
fi

# ==========================================
# 4. CLONE REPOSITORY
# ==========================================

if [ ! -d "$APP_DIR/.git" ]; then
    log "Cloning TaskBoard repository..."

    git clone "$REPOSITORY_URL" "$APP_DIR" ||
        die "Git clone failed"
else
    log "Repository already exists"
fi

cd "$APP_DIR" ||
    die "Cannot open application directory"

[ -f requirements.txt ] ||
    die "requirements.txt not found"

# ==========================================
# 5. CREATE PYTHON VIRTUAL ENVIRONMENT
# ==========================================

if [ ! -x ".venv/bin/python" ] ||
   ! .venv/bin/python -m pip --version \
        >/dev/null 2>&1; then

    log "Creating Python virtual environment..."

    rm -rf .venv

    python3 -m venv .venv ||
        die "Virtual environment creation failed"
else
    log "Using existing virtual environment"
fi

# ==========================================
# 6. INSTALL PYTHON DEPENDENCIES
# ==========================================

log "Installing Python dependencies..."

.venv/bin/python -m pip install \
    -r requirements.txt ||
    die "Python dependencies installation failed"

# ==========================================
# 7. START POSTGRESQL
# ==========================================

log "Starting PostgreSQL..."

if command -v systemctl >/dev/null 2>&1 &&
   [ -d /run/systemd/system ]; then

    $SUDO systemctl enable --now postgresql ||
        die "PostgreSQL startup failed"
else
    $SUDO service postgresql start ||
        die "PostgreSQL startup failed"
fi

# Check database connection
$SUDO runuser -u postgres -- psql -tAc "SELECT 1" \
    >/dev/null ||
    die "Cannot connect to PostgreSQL"

# ==========================================
# 8. CREATE DATABASE USER
# ==========================================

log "Configuring PostgreSQL user..."

USER_EXISTS=$(
    $SUDO runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'"
)

if [ "$USER_EXISTS" != "1" ]; then

    log "Creating database user..."

    $SUDO runuser -u postgres -- psql \
        -v ON_ERROR_STOP=1 \
        -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';" ||
        die "Cannot create database user"
else
    log "Database user already exists"
fi

# Ensure the password matches the application
$SUDO runuser -u postgres -- psql \
    -v ON_ERROR_STOP=1 \
    -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';" ||
    die "Cannot configure database password"

# ==========================================
# 9. CREATE DATABASE
# ==========================================

log "Configuring database..."

DB_EXISTS=$(
    $SUDO runuser -u postgres -- psql -tAc \
    "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'"
)

if [ "$DB_EXISTS" != "1" ]; then

    log "Creating database..."

    $SUDO runuser -u postgres -- createdb \
        -O "$DB_USER" "$DB_NAME" ||
        die "Database creation failed"
else
    log "Database already exists"
fi

# Ensure the application user owns the database
$SUDO runuser -u postgres -- psql \
    -v ON_ERROR_STOP=1 \
    -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER;" ||
    die "Cannot configure database owner"

# Grant permissions
$SUDO runuser -u postgres -- psql \
    -v ON_ERROR_STOP=1 \
    -d "$DB_NAME" \
    -c "GRANT ALL ON SCHEMA public TO $DB_USER;" ||
    die "Cannot grant schema permissions"

# ==========================================
# 10. DATABASE CONNECTION CHECK
# ==========================================

unset PGPASSWORD

# ==========================================
# DATABASE ENVIRONMENT CONFIGURATION
# ==========================================

log "Configuring database environment..."

export DATABASE_URL="postgresql+psycopg2://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}"

export APP_NAME="$APP_NAME"

log "Database environment configured"

log "Checking database connection..."

export PGPASSWORD="$DB_PASSWORD"

psql -h "$DB_HOST" \
     -p "$DB_PORT" \
     -U "$DB_USER" \
     -d "$DB_NAME" \
     -tAc "SELECT 1" >/dev/null ||
     die "Database connection failed"

unset PGPASSWORD

# ==========================================
# 11. START FASTAPI
# ==========================================

log "Starting FastAPI application..."

APP_URL="http://127.0.0.1:$APP_PORT"
HEALTH_URL="$APP_URL/api/health"
LOG_FILE="$APP_DIR/taskboard.log"

# If the application is already running,
# reuse it instead of starting another process.
if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    log "TaskBoard is already running"
    log "Application deployed successfully."
    log "Application: http://localhost:$APP_PORT"
    log "Swagger: http://localhost:$APP_PORT/docs"
    exit 0
fi

# Prevent starting a second server on a busy port
if command -v ss >/dev/null 2>&1; then
    if ss -ltn | grep -q ":$APP_PORT "; then
        die "Port $APP_PORT is already in use"
    fi
fi

.venv/bin/python -m uvicorn "$APP_MODULE" \
    --host 127.0.0.1 \
    --port "$APP_PORT" \
    > "$LOG_FILE" 2>&1 &

APP_PID=$!

# ==========================================
# 12. HEALTHCHECK
# ==========================================

log "Waiting for application..."

ATTEMPT=0
MAX_ATTEMPTS=30

while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do

    if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then

        echo ""
        log "Application deployed successfully!"
        log "Application: http://localhost:$APP_PORT"
        log "Swagger API: http://localhost:$APP_PORT/docs"
        log "Healthcheck: http://localhost:$APP_PORT/api/health"
        echo ""

        log "Press Ctrl+C to stop the server"

        wait "$APP_PID"
        exit $?
    fi

    if ! kill -0 "$APP_PID" 2>/dev/null; then
        cat "$LOG_FILE" >&2
        die "FastAPI stopped unexpectedly"
    fi

    sleep 1
    ATTEMPT=$((ATTEMPT + 1))
done

cat "$LOG_FILE" >&2
kill "$APP_PID" 2>/dev/null || true
die "Healthcheck failed after 30 seconds"

