#!/bin/bash
#
# build.sh -- Локальная сборка immortalwrt_25.12_wifi7 для BananaPi BPI-R4
#
# Реплицирует GitHub Actions workflow immortalwrt_25.12_wifi7.yml
# для запуска на локальной машине (Ubuntu/Debian).
#
# Опции:
#   --no-menuconfig  Пропустить интерактивный menuconfig
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
NO_MENUCONFIG=0

# GITHUB_WORKSPACE нужен diy-mtk.sh для поиска патчей
export GITHUB_WORKSPACE="$(pwd)"

# Очистка PATH от Windows-путей с пробелами/скобками (WSL)
export PATH=$(echo "$PATH" | tr ':' '\n' | grep -v ' ' | grep -v '(' | grep -v '^\s*$' | tr '\n' ':' | sed 's/:$//')

# Парсинг аргументов
for arg in "$@"; do
    case "$arg" in
        --no-menuconfig) NO_MENUCONFIG=1 ;;
    esac
done

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Очистка старых логов (старше 7 дней)
find "$GITHUB_WORKSPACE" -maxdepth 1 -name "build-*.log" -mtime +7 -delete 2>/dev/null || true

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
    if ! git clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" openwrt; then
        error "Не удалось склонировать репозиторий"
        exit 1
    fi
    cd openwrt
    git log --pretty=tformat:"%h" -n1 tools toolchain || echo "Нет истории toolchain"
    cd "$GITHUB_WORKSPACE"
fi

# ============================================================
# Шаг 4: DIY-скрипт (кастомизация пакетов + патчи + фиды)
# ============================================================
info "=== Запуск diy-mtk.sh ==="
cd openwrt
chmod +x "$GITHUB_WORKSPACE/$DIY_SH"
"$GITHUB_WORKSPACE/$DIY_SH"
cd "$GITHUB_WORKSPACE"

# ============================================================
# Шаг 5: Загрузка конфигурации
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
# Шаг 6: Сборка
# ============================================================
info "=== Сборка прошивки ==="
cd openwrt

BUILD_START=$(date +%s)

info "make defconfig..."
make defconfig

# Интерактивный выбор пакетов (опционально)
if [ "$NO_MENUCONFIG" -eq 0 ]; then
    info "Запуск menuconfig для настройки пакетов..."
    make menuconfig
else
    info "menuconfig пропущен (--no-menuconfig)"
fi

info "Ключевые опции конфигурации:"
grep -E "^CONFIG_TARGET|^CONFIG_PACKAGE_luci|^CONFIG_PACKAGE_kmod-mediatek" .config | head -20

# Очистка Go-кеша ДО загрузки (чтобы избежать неполных модулей)
rm -rf dl/go-mod-cache tmp/go-build

info "Загрузка пакетов (make download -j$NPROC)..."
make download -j"$NPROC" 2>&1
# Удаление битых загрузок
find dl -size -1024c -exec ls -l {} \;
find dl -size -1024c -exec rm -f {} \;

LOG_FILE="$GITHUB_WORKSPACE/build-$(date +'%Y%m%d-%H%M%S').log"
info "Компиляция ($NPROC потоков, verbose). Лог: $LOG_FILE"
make -j"$NPROC" V=s 2>&1 | tee "$LOG_FILE"
MAKE_STATUS=${PIPESTATUS[0]}

cd "$GITHUB_WORKSPACE"

if [ $MAKE_STATUS -ne 0 ]; then
    error "Сборка завершилась с ошибкой (код: $MAKE_STATUS). Лог: $LOG_FILE"
    exit $MAKE_STATUS
fi

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))

# Статистика ccache
if [ -d "openwrt/.ccache" ] && command -v ccache >/dev/null 2>&1; then
    info "=== Статистика ccache ==="
    CCACHE_DIR="$PWD/openwrt/.ccache" ccache --show-stats
    du -sh openwrt/.ccache
fi

# ============================================================
# Шаг 7: Копирование прошивки
# ============================================================
info "=== Копирование прошивки ==="
rm -rf output/*
mkdir -p output
cp -r openwrt/bin/targets/mediatek/filogic/* output/
[ -f "$LOG_FILE" ] && cp "$LOG_FILE" output/

# ============================================================
# Итог
# ============================================================
echo ""
info "=== Итог сборки ==="
info "Прошивка:"
ls -lh output/*.img.gz 2>/dev/null || ls -lh output/*.itb 2>/dev/null || warn "Прошивка не найдена"
info "Пакетов: $(ls output/packages/*.apk 2>/dev/null | wc -l)"
info "Время сборки: $((BUILD_DURATION / 60)) мин $((BUILD_DURATION % 60)) сек"
info "Лог: $LOG_FILE"
info "=== Сборка завершена ==="
