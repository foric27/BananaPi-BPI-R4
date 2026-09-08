#!/bin/bash
#
# build.sh -- Локальная сборка immortalwrt_25.12_wifi7 для BananaPi BPI-R4
#
# Реплицирует GitHub Actions workflow immortalwrt_25.12_wifi7.yml
# для запуска на локальной машине (Ubuntu/Debian).
#
# Опции:
#   --no-menuconfig     Пропустить интерактивный menuconfig
#                       (пропускается автоматически, если stdin не терминал)
#   --jobs N            Число потоков компиляции (по умолчанию: nproc)
#   --refresh-go-cache  Очистить кеш Go-модулей (dl/go-mod-cache) перед сборкой
#   --help              Показать справку
#

set -e
set -o pipefail

# ============================================================
# Конфигурация (из env-переменных workflow)
# ============================================================
REPO_URL="https://github.com/chasey-dev/immortalwrt-mt798x-rebase.git"
REPO_BRANCH="25.12-dev-wifi7"
CONFIG_FILE="immortalwrt/MTK/defconfig-vendor-wifi"
DIY_SH="immortalwrt/diy-mtk.sh"
NPROC=$(nproc)
NO_MENUCONFIG=0
REFRESH_GO_CACHE=0

# GITHUB_WORKSPACE нужен diy-mtk.sh для поиска патчей
export GITHUB_WORKSPACE="$(pwd)"

usage() {
    cat <<EOF
Использование: $0 [опции]

  --no-menuconfig     Пропустить интерактивный menuconfig
  --jobs N            Число потоков компиляции (по умолчанию: nproc)
  --refresh-go-cache  Очистить кеш Go-модулей перед сборкой
  --help              Показать эту справку
EOF
}

# Парсинг аргументов
while [ $# -gt 0 ]; do
    case "$1" in
        --no-menuconfig)
            NO_MENUCONFIG=1
            ;;
        --jobs)
            shift
            [ $# -gt 0 ] || { echo "[ERROR] --jobs требует числовой аргумент" >&2; exit 1; }
            case "$1" in
                ''|*[!0-9]*) echo "[ERROR] --jobs: не число: $1" >&2; exit 1 ;;
            esac
            [ "$1" -ge 1 ] || { echo "[ERROR] --jobs: должно быть >= 1" >&2; exit 1; }
            NPROC=$1
            ;;
        --refresh-go-cache)
            REFRESH_GO_CACHE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "[ERROR] Неизвестный аргумент: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
    shift
done

# menuconfig только в интерактивном терминале (паритет с CI)
if [ ! -t 0 ]; then
    NO_MENUCONFIG=1
fi

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Очистка PATH от Windows-путей с пробелами/скобками (WSL)
_filtered_path="$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -v ' ' | grep -v '(' | grep -v '^\s*$' | tr '\n' ':' | sed 's/:$//' || true)"
if [ -z "$_filtered_path" ]; then
    error "После фильтрации PATH пуст — проверьте окружение (WSL?)"
    exit 1
fi
export PATH="$_filtered_path"
unset _filtered_path

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
# Шаг 3: Клонирование / Обновление исходников
# ============================================================
if [ -d "openwrt" ] && [ ! -d "openwrt/.git" ]; then
    error "Директория openwrt/ существует, но не является git-репозиторием."
    error "Удалите её (rm -rf openwrt) и перезапустите скрипт."
    exit 1
fi

if [ -d "openwrt" ]; then
    info "Директория openwrt/ существует, обновление до свежего $REPO_BRANCH..."
    git -C openwrt fetch --depth 1 origin "$REPO_BRANCH"
    git -C openwrt reset --hard FETCH_HEAD
    git -C openwrt clean -fd
else
    info "Клонирование $REPO_URL (ветка $REPO_BRANCH)..."
    if ! git clone --depth 1 "$REPO_URL" -b "$REPO_BRANCH" openwrt; then
        error "Не удалось склонировать репозиторий"
        exit 1
    fi
    git -C openwrt log --pretty=tformat:"%h" -n1 tools toolchain || echo "Нет истории toolchain"
fi

# ============================================================
# Шаг 4: DIY-скрипт (кастомизация пакетов + патчи + фиды)
# ============================================================
info "=== Запуск diy-mtk.sh ==="
chmod +x "$GITHUB_WORKSPACE/$DIY_SH"
git -C openwrt rev-parse --short HEAD
# diy-mtk.sh работает с относительными путями package/... —
# запускать строго из корня дерева openwrt/
( cd openwrt && "$GITHUB_WORKSPACE/$DIY_SH" )

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

# Гейт: все наши переведённые пакеты обязаны остаться в .config.
# make defconfig молча сбрасывает =y при неудовлетворённой зависимости.
REQUIRED_IN_CONFIG="caddy luci-app-caddy luci-app-fan luci-app-modemband luci-app-sfp-status luci-app-turboacc-mtk modemband"
for _sym in $REQUIRED_IN_CONFIG; do
    if ! grep -q "^CONFIG_PACKAGE_${_sym}=y" .config; then
        error "Пакет выпал из конфигурации: CONFIG_PACKAGE_${_sym}=y (неудовлетворённая зависимость?)"
        exit 1
    fi
done
info "Все локальные пакеты в конфигурации:$REQUIRED_IN_CONFIG"

# Интерактивный выбор пакетов (опционально)
if [ "$NO_MENUCONFIG" -eq 0 ]; then
    info "Запуск menuconfig для настройки пакетов..."
    make menuconfig
else
    info "menuconfig пропущен"
fi

info "Ключевые опции конфигурации:"
grep -E "^CONFIG_TARGET|^CONFIG_PACKAGE_luci|^CONFIG_PACKAGE_kmod-mediatek" .config | head -20 || true

# Кеш Go-модулей сохраняется между сборками; очистка --refresh-go-cache
if [ "$REFRESH_GO_CACHE" -eq 1 ]; then
    info "Очистка Go-кеша (--refresh-go-cache)..."
    rm -rf dl/go-mod-cache tmp/go-build
fi

info "Загрузка пакетов (make download -j$NPROC)..."
make download -j"$NPROC" 2>&1
# Удаление битых (обрезанных) загрузок в dl/ верхнего уровня
# (только файлы верхнего уровня: dl/go-mod-cache не трогаем)
if [ -d dl ]; then
    find dl -maxdepth 1 -type f -size -1024c -exec ls -l {} \;
    find dl -maxdepth 1 -type f -size -1024c -exec rm -f {} +
fi

LOG_FILE="$GITHUB_WORKSPACE/build-$(date +'%Y%m%d-%H%M%S').log"
info "Компиляция ($NPROC потоков). Лог: $LOG_FILE"

# Цепочка как в CI: -jN -> -jN/2 (гонки/OOM) -> -j1 V=s (финальная диагностика)
MAKE_STATUS=0
make -j"$NPROC" 2>&1 | tee -a "$LOG_FILE" || MAKE_STATUS=${PIPESTATUS[0]}
if [ "$MAKE_STATUS" -ne 0 ]; then
    warn "Сборка -j$NPROC завершилась с ошибкой (код: $MAKE_STATUS), повтор: -j$((NPROC / 2 + 1))..."
    MAKE_STATUS=0
    make -j$((NPROC / 2 + 1)) 2>&1 | tee -a "$LOG_FILE" || MAKE_STATUS=${PIPESTATUS[0]}
fi
if [ "$MAKE_STATUS" -ne 0 ]; then
    warn "Повторная ошибка (код: $MAKE_STATUS), финальная попытка: -j1 V=s..."
    MAKE_STATUS=0
    make -j1 V=s 2>&1 | tee -a "$LOG_FILE" || MAKE_STATUS=${PIPESTATUS[0]}
fi

cd "$GITHUB_WORKSPACE"

if [ "$MAKE_STATUS" -ne 0 ]; then
    error "Сборка завершилась с ошибкой (код: $MAKE_STATUS). Лог: $LOG_FILE"
    exit "$MAKE_STATUS"
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
mkdir -p output
rm -rf output/*
cp -r openwrt/bin/targets/mediatek/filogic/* output/
[ -f "$LOG_FILE" ] && cp "$LOG_FILE" output/

if ! ls output/*.img.gz >/dev/null 2>&1 && ! ls output/*.itb >/dev/null 2>&1; then
    error "Прошивка не найдена в output/ (ожидается *.img.gz или *.itb)"
    exit 1
fi

# ============================================================
# Итог
# ============================================================
echo ""
info "=== Итог сборки ==="
info "Прошивка:"
ls -lh output/*.img.gz 2>/dev/null || ls -lh output/*.itb 2>/dev/null
info "Пакетов: $(find output/packages -name '*.apk' 2>/dev/null | wc -l)"
info "Время сборки: $((BUILD_DURATION / 60)) мин $((BUILD_DURATION % 60)) сек"
info "Лог: $LOG_FILE"
info "=== Сборка завершена ==="
