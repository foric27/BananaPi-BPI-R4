#!/bin/bash
#
# build.sh -- Локальная сборка immortalwrt_25.12_wifi7 для BananaPi BPI-R4
#
# Реплицирует GitHub Actions workflow immortalwrt_25.12_wifi7.yml
# для запуска на локальной машине (Ubuntu/Debian).
#

set -e

# ============================================================
# Конфигурация (из env-переменных workflow)
# ============================================================
REPO_URL="https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git"
REPO_BRANCH="25.12-dev-wifi7"
CONFIG_FILE="immortalwrt/MTK/defconfig-vendor-wifi"
DIY_SH="immortalwrt/diy-mtk.sh"
NPROC=$(nproc)

# GITHUB_WORKSPACE нужен diy-mtk.sh для поиска патчей
export GITHUB_WORKSPACE="$(pwd)"

# Очистка PATH от Windows-путей с пробелами/скобками (WSL)
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v ' ' | grep -v '(' | tr '\n' ':' | sed 's/:$//')

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# ============================================================
# Шаг 1: Проверка зависимостей
# ============================================================
info "=== Проверка зависимостей ==="

REQUIRED_PACKAGES=(
    build-essential clang flex g++ gawk gcc-multilib gettext
    git libncurses-dev libssl-dev python3-setuptools rsync unzip
    zlib1g-dev swig libpython3-dev aria2 jq subversion qemu-utils
    ccache rename libelf-dev perl
)

MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    warn "Отсутствуют пакеты: ${MISSING_PACKAGES[*]}"
    info "Установка недостающих пакетов..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${MISSING_PACKAGES[@]}"
    info "Пакеты установлены"
else
    info "Все зависимости установлены"
fi

# ============================================================
# Шаг 2: Информация о системе
# ============================================================
info "=== Информация о системе ==="
chmod +x "$GITHUB_WORKSPACE/immortalwrt/"*.sh
"$GITHUB_WORKSPACE/immortalwrt/system-Information.sh"
echo ""

# ============================================================
# Шаг 3: Клонирование / Сброс исходников
# ============================================================
if [ -d "openwrt" ]; then
    info "Директория openwrt/ существует, сброс к чистому состоянию..."
    cd openwrt
    git reset --hard HEAD
    git clean -fd
    cd "$GITHUB_WORKSPACE"
else
    info "Клонирование $REPO_URL (ветка $REPO_BRANCH)..."
    git clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" openwrt
    cd openwrt
    git log --pretty=tformat:"%h" -n1 tools toolchain || echo "Нет истории toolchain"
    cd "$GITHUB_WORKSPACE"
fi

# ============================================================
# Шаг 4: Обновление фидов
# ============================================================
info "=== Обновление фидов ==="
cd openwrt
for feed in packages luci routing telephony video; do
    [ -d "feeds/$feed/.git" ] && {
        git -C "feeds/$feed" reset --hard HEAD
        git -C "feeds/$feed" clean -fd
    }
done
./scripts/feeds update -a
cd "$GITHUB_WORKSPACE"

# ============================================================
# Шаг 5: DIY-скрипт (кастомизация пакетов + патчи)
# ============================================================
info "=== Запуск diy-mtk.sh ==="
cd openwrt
chmod +x "$GITHUB_WORKSPACE/$DIY_SH"
"$GITHUB_WORKSPACE/$DIY_SH"
cd "$GITHUB_WORKSPACE"

# ============================================================
# Шаг 6: Загрузка конфигурации
# ============================================================
info "=== Загрузка конфигурации ==="
if [ -e "$CONFIG_FILE" ]; then
    cat "$CONFIG_FILE" > openwrt/.config
    info "Конфигурация скопирована из $CONFIG_FILE"
else
    error "Файл конфигурации не найден: $CONFIG_FILE"
    exit 1
fi

# ============================================================
# Шаг 7: Сборка
# ============================================================
info "=== Сборка прошивки ==="
cd openwrt

info "make defconfig..."
make defconfig

# Интерактивный выбор пакетов
info "Запуск menuconfig для настройки пакетов..."
make menuconfig

info "Содержимое .config:"
cat .config

info "Загрузка пакетов (make download -j$NPROC)..."
make download -j"$NPROC" 2>&1
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;

# Очистка Go-кеша перед сборкой (всегда, чтобы избежать неполных модулей)
rm -rf dl/go-mod-cache
rm -rf tmp/go-build

LOG_FILE="$GITHUB_WORKSPACE/build-$(date +'%Y%m%d-%H%M%S').log"
info "Компиляция ($NPROC потоков, verbose). Лог: $LOG_FILE"
make -j"$NPROC" V=s 2>&1 | tee "$LOG_FILE"
MAKE_STATUS=${PIPESTATUS[0]}

# Статистика ccache
if [ -d ".ccache" ]; then
    CCACHE_DIR="$PWD/.ccache" staging_dir/host/bin/ccache --show-stats
    du -sh .ccache
fi

cd "$GITHUB_WORKSPACE"

if [ $MAKE_STATUS -ne 0 ]; then
    error "Сборка завершилась с ошибкой (код: $MAKE_STATUS). Лог: $LOG_FILE"
    exit $MAKE_STATUS
fi

# ============================================================
# Шаг 8: Копирование прошивки
# ============================================================
info "=== Копирование прошивки ==="
rm -rf output/*
mkdir -p output
cp -r openwrt/bin/targets/mediatek/filogic/* output/
[ -f "$LOG_FILE" ] && cp "$LOG_FILE" output/
info "Прошивка сохранена в output/"
ls -lh output/

info "=== Сборка завершена ==="
