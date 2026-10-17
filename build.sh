#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# build.sh -- Локальная сборка OpenWrt для BananaPi BPI-R4 (стабильные ветки)
#
# База: openwrt/openwrt (openwrt-25.12, HEAD) + mediatek/mtk-openwrt-feeds (main, HEAD)
# Патчи MTK адаптируются к актуальной базе. Реплицирует CI-workflow
# .github/workflows/bpi-r4-openwrt-build.yml для локальной машины.
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
REPO_URL="https://github.com/openwrt/openwrt.git"
REPO_BRANCH="openwrt-25.12"
# Точную ревизию можно зафиксировать, не редактируя файл:
#   OPENWRT_REF=<branch|tag|40-hex-sha> MTK_FEED_REF=<...> ./build.sh
# Пустое значение означает «следить за веткой» (REPO_BRANCH / MTK_FEED_BRANCH).
OPENWRT_REF="${OPENWRT_REF:-$REPO_BRANCH}"
MTK_FEED_URL="https://github.com/mediatek/mtk-openwrt-feeds.git"
MTK_FEED_BRANCH="main"
MTK_FEED_REF="${MTK_FEED_REF:-$MTK_FEED_BRANCH}"
# hostapd's src/build.rules uses CONFIG_FILE as an include path; an inherited
# CONFIG_FILE would make the afc sub-build look for config/defconfig relative
# to its own directory. Keep our own name and clear any inherited value.
unset CONFIG_FILE
OWRT_CONFIG_FILE="config/defconfig"
DIY_SH="scripts/customize.sh"
# Внешние деревья (клон/сборка) и служебные каталоги
SOURCE_DIR="src"
OPENWRT_DIR="$SOURCE_DIR/openwrt"
MTK_FEED_DIR="$SOURCE_DIR/mtk-openwrt-feeds"
NPROC=$(nproc)
NO_MENUCONFIG=0
REFRESH_GO_CACHE=0

# GITHUB_WORKSPACE нужен customize.sh для поиска патчей
export GITHUB_WORKSPACE="$(pwd)"

usage() {
    cat <<EOF
Использование: $0 [опции]

  --no-menuconfig     Пропустить интерактивный menuconfig
  --jobs N            Число потоков компиляции (по умолчанию: nproc)
  --refresh-go-cache  Очистить кеш Go-модулей перед сборкой
  --help              Показать эту справку

Переменные окружения:
  OPENWRT_REF=<ref>   Ветка/тег/40-hex SHA OpenWrt (по умолчанию $REPO_BRANCH)
  MTK_FEED_REF=<ref>  Ветка/тег/40-hex SHA mtk-openwrt-feeds (по умолчанию $MTK_FEED_BRANCH)
  CURL_OPTIONS=...    Таймауты curl для make download (см. ниже)
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

# Полный 40-hex id — значит, ревизия пинована, а не ветка/тег.
is_commit_sha() {
    [[ "$1" =~ ^[0-9a-fA-F]{40}$ ]]
}

# Клон с повтором. Клонируем во временный каталог: если сеть оборвалась,
# следующая попытка не упирается в «destination path already exists».
clone_retry() {
    local url="$1" ref="$2" dir="$3" _try=1
    while [ "$_try" -le 5 ]; do
        rm -rf "$dir.tmp"
        if is_commit_sha "$ref"; then
            if git init -q "$dir.tmp" &&
               git -C "$dir.tmp" remote add origin "$url" &&
               git -C "$dir.tmp" fetch --depth 1 origin "$ref" &&
               git -C "$dir.tmp" checkout -q FETCH_HEAD; then
                mv "$dir.tmp" "$dir"
                return 0
            fi
        elif git clone --depth 1 -b "$ref" "$url" "$dir.tmp"; then
            mv "$dir.tmp" "$dir"
            return 0
        fi
        warn "клон не удался (попытка $_try/5): $url@$ref"
        _try=$((_try + 1))
        sleep 10
    done
    rm -rf "$dir.tmp"
    return 1
}

# Обновление существующего дерева до ветки/тега/SHA.
update_repo() {
    local dir="$1" ref="$2" _try=1
    while [ "$_try" -le 5 ]; do
        if git -C "$dir" fetch --depth 1 origin "$ref" &&
           git -C "$dir" reset --hard -q FETCH_HEAD &&
           git -C "$dir" clean -fdq; then
            return 0
        fi
        warn "обновление не удалось (попытка $_try/5): $dir@$ref"
        _try=$((_try + 1))
        sleep 10
    done
    return 1
}

# Очистка старых логов (старше 7 дней)
find "$GITHUB_WORKSPACE" -maxdepth 1 -name "build-*.log" -mtime +7 -delete 2>/dev/null || true

# ============================================================
# Шаг 1: Проверка зависимостей
# ============================================================
info "=== Проверка зависимостей ==="

REQUIRED_PACKAGES=(
    build-essential clang flex g++ gawk gcc-multilib gettext
    git libncurses-dev libssl-dev python3-setuptools rsync unzip
    zlib1g-dev swig libpython3-dev aria2 jq subversion qemu-utils zstd
    ccache rename libelf-dev perl
)

# gcc-multilib — метапакет; на новых Ubuntu он может отсутствовать при
# установленном gcc-<N>-multilib. Проверяем возможность собрать -m32, а не
# только имя пакета: иначе build.sh требует установку того, что уже есть.
pkg_present() {
    local pkg="$1" status _c _o _rc
    dpkg -s "$pkg" >/dev/null 2>&1 && return 0
    [ "$pkg" = "gcc-multilib" ] || return 1
    status=$(dpkg-query -W -f='${db:Status-Abbrev}\n' 'gcc-*-multilib' 2>/dev/null || true)
    case "$status" in
        *ii*) ;;
        *) return 1 ;;
    esac
    _c=$(mktemp) || return 1
    _o=$(mktemp) || { rm -f "$_c"; return 1; }
    printf 'int main(void){return 0;}\n' > "$_c"
    gcc -m32 -c "$_c" -o "$_o" >/dev/null 2>&1
    _rc=$?
    rm -f "$_c" "$_o"
    return "$_rc"
}

MISSING_PACKAGES=()
for pkg in "${REQUIRED_PACKAGES[@]}"; do
    if ! pkg_present "$pkg"; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    warn "Отсутствуют пакеты: ${MISSING_PACKAGES[*]}"
    # В неинтерактивном окружении sudo без пароля может зависнуть на запросе.
    # Лучше сразу назвать команду установки, чем ждать таймаут.
    if [ -t 0 ]; then
        info "Установка недостающих пакетов..."
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${MISSING_PACKAGES[@]}"
    elif sudo -n true 2>/dev/null; then
        info "Установка недостающих пакетов (passwordless sudo)..."
        sudo -n apt-get update -qq
        sudo -n apt-get install -y -qq "${MISSING_PACKAGES[@]}"
    else
        error "Нет TTY и passwordless sudo. Установите вручную:"
        error "  sudo apt-get install -y ${MISSING_PACKAGES[*]}"
        exit 1
    fi
    info "Пакеты установлены"
else
    info "Все зависимости установлены"
fi

# ============================================================
# Шаг 2: Клонирование / Обновление исходников
# ============================================================
mkdir -p "$SOURCE_DIR"

if [ -d "$OPENWRT_DIR" ] && [ ! -d "$OPENWRT_DIR/.git" ]; then
    error "Директория $OPENWRT_DIR/ существует, но не является git-репозиторием."
    error "Удалите её (rm -rf $OPENWRT_DIR) и перезапустите скрипт."
    exit 1
fi

if [ -d "$OPENWRT_DIR" ]; then
    info "Директория $OPENWRT_DIR/ существует, обновление до $OPENWRT_REF..."
    update_repo "$OPENWRT_DIR" "$OPENWRT_REF" || {
        error "Не удалось обновить OpenWrt до $OPENWRT_REF"
        exit 1
    }
else
    info "Клонирование $REPO_URL ($OPENWRT_REF) в $OPENWRT_DIR..."
    if ! clone_retry "$REPO_URL" "$OPENWRT_REF" "$OPENWRT_DIR"; then
        error "Не удалось склонировать репозиторий"
        exit 1
    fi
    git -C "$OPENWRT_DIR" log --pretty=tformat:"%h" -n1 tools toolchain || echo "Нет истории toolchain"
fi

# MTK feed (патчи/файлы/пакеты MTK для 25.12)
if [ -d "$MTK_FEED_DIR" ]; then
    info "Обновление $MTK_FEED_DIR ($MTK_FEED_REF)..."
    update_repo "$MTK_FEED_DIR" "$MTK_FEED_REF" || {
        error "Не удалось обновить mtk-openwrt-feeds до $MTK_FEED_REF"
        exit 1
    }
else
    info "Клонирование $MTK_FEED_URL ($MTK_FEED_REF) в $MTK_FEED_DIR..."
    if ! clone_retry "$MTK_FEED_URL" "$MTK_FEED_REF" "$MTK_FEED_DIR"; then
        error "Не удалось склонировать mtk-openwrt-feeds"
        exit 1
    fi
fi

# Точные ревизии, которые уйдут в образ: по ним сборку можно повторить.
OPENWRT_COMMIT=$(git -C "$OPENWRT_DIR" rev-parse HEAD)
MTK_FEED_COMMIT=$(git -C "$MTK_FEED_DIR" rev-parse HEAD)
info "OpenWrt: $OPENWRT_COMMIT ($OPENWRT_REF)"
info "mtk-openwrt-feeds: $MTK_FEED_COMMIT ($MTK_FEED_REF)"

# Сброс фидов (MTK-патчи применяются к ним; повторный прогон должен быть чистым)
if [ -d "$OPENWRT_DIR/feeds" ]; then
    info "Сброс фидов до чистого состояния..."
    for _feed_dir in "$OPENWRT_DIR"/feeds/*/; do
        [ -d "${_feed_dir}.git" ] || continue
        git -C "$_feed_dir" reset --hard -q 2>/dev/null || true
        git -C "$_feed_dir" clean -fdq 2>/dev/null || true
    done
fi

# ============================================================
# Шаг 4: DIY-скрипт (MTK files/patches + пакеты + фиксы фидов)
# ============================================================
info "=== Запуск $DIY_SH ==="
chmod +x "$GITHUB_WORKSPACE/$DIY_SH"
git -C "$OPENWRT_DIR" rev-parse --short HEAD
# customize.sh работает с относительными путями package/... —
# запускать строго из корня дерева OpenWrt
( cd "$OPENWRT_DIR" && "$GITHUB_WORKSPACE/$DIY_SH" )

# ============================================================
# Шаг 5: Загрузка конфигурации
# ============================================================
info "=== Загрузка конфигурации ==="
if [ -e "$OWRT_CONFIG_FILE" ]; then
    cat "$OWRT_CONFIG_FILE" > "$OPENWRT_DIR/.config"
    info "Конфигурация скопирована из $OWRT_CONFIG_FILE"
else
    error "Файл конфигурации не найден: $OWRT_CONFIG_FILE"
    exit 1
fi

# ============================================================
# Шаг 6: Сборка
# ============================================================
info "=== Сборка прошивки ==="
cd "$OPENWRT_DIR"

BUILD_START=$(date +%s)

info "make defconfig..."
make defconfig

# Интерактивный выбор пакетов (опционально)
if [ "$NO_MENUCONFIG" -eq 0 ]; then
    info "Запуск menuconfig для настройки пакетов..."
    make menuconfig
else
    info "menuconfig пропущен"
fi

# Гейт: все наши переведённые пакеты обязаны остаться в .config.
# make defconfig молча сбрасывает =y при неудовлетворённой зависимости.
# Проверяем ПОСЛЕ menuconfig: интерактивное изменение тоже не должно
# выкидывать обязательные пакеты незамеченным.
REQUIRED_IN_CONFIG="luci-app-fan luci-app-modemband luci-app-sfp-status luci-app-turboacc-mtk modemband luci-app-traffic smp_util mtkhnat_util"
for _sym in $REQUIRED_IN_CONFIG; do
    if ! grep -q "^CONFIG_PACKAGE_${_sym}=y" .config; then
        error "Пакет выпал из конфигурации: CONFIG_PACKAGE_${_sym}=y (неудовлетворённая зависимость?)"
        exit 1
    fi
done
info "Все локальные пакеты в конфигурации:$REQUIRED_IN_CONFIG"

# Кеш Go-модулей сохраняется между сборками; очистка --refresh-go-cache
if [ "$REFRESH_GO_CACHE" -eq 1 ]; then
    info "Очистка Go-кеша (--refresh-go-cache)..."
    rm -rf dl/go-mod-cache tmp/go-build
fi

info "Загрузка пакетов (make download -j$NPROC)..."
# Таймауты curl против зависаний на сторожевых зеркалах (download.pl читает CURL_OPTIONS)
export CURL_OPTIONS="${CURL_OPTIONS:---connect-timeout 10 --max-time 300 --speed-time 30 --speed-limit 2048}"
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

# ============================================================
# Шаг 7: Копирование прошивки
# ============================================================
info "=== Копирование прошивки ==="
mkdir -p output
rm -rf output/*
cp -r "$OPENWRT_DIR"/bin/targets/mediatek/filogic/* output/
[ -f "$LOG_FILE" ] && cp "$LOG_FILE" output/

# Пакеты, не привязанные к target (LuCI, утилиты), лежат в bin/packages,
# а не в bin/targets/.../packages. Без них output/ — не репозиторий пакетов.
if [ -d "$OPENWRT_DIR/bin/packages" ]; then
    mkdir -p output/packages
    cp -a "$OPENWRT_DIR"/bin/packages/. output/packages/ 2>/dev/null || \
        warn "Не удалось скопировать bin/packages (продолжаем)"
fi

# Точные ревизии исходников — рядом с образами, чтобы сборку можно было повторить.
{
    printf 'openwrt %s (%s)\n' "$OPENWRT_COMMIT" "$OPENWRT_REF"
    printf 'mtk-openwrt-feeds %s (%s)\n' "$MTK_FEED_COMMIT" "$MTK_FEED_REF"
} > output/source-versions.txt

if ! ls output/*.img.gz >/dev/null 2>&1 && ! ls output/*.itb >/dev/null 2>&1; then
    error "Прошивка не найдена в output/ (ожидается *.img.gz или *.itb)"
    exit 1
fi

# Гейт 8GB: должны быть sdcard_8g и preloader -8g
for _art in sdcard_8g.img.gz preloader-8g.bin; do
    if ! ls output/*"$_art" >/dev/null 2>&1; then
        error "Не найден 8GB-артефакт: *$_art"
        exit 1
    fi
done

# ============================================================
# Итог
# ============================================================
echo ""
info "=== Итог сборки ==="
info "Прошивка:"
ls -lh output/*.img.gz 2>/dev/null || ls -lh output/*.itb 2>/dev/null
info "Пакетов: $(find output/packages -name '*.apk' 2>/dev/null | wc -l)"
info "Исходники: openwrt=$OPENWRT_COMMIT mtk-openwrt-feeds=$MTK_FEED_COMMIT"
info "Время сборки: $((BUILD_DURATION / 60)) мин $((BUILD_DURATION % 60)) сек"
info "Лог: $LOG_FILE"
info "=== Сборка завершена ==="
