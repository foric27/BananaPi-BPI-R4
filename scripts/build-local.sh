#!/bin/bash
# build-local.sh — локальная сборка прошивки BPI-R4 (ImmortalWrt 25.12)
#
# Локальный аналог GitHub Actions: шаги повторяют workflow
# .github/workflows/immortalwrt-25.12-bpi-r4.yml, а все изменения дерева OpenWrt
# делают те же DIY-скрипты, что и в CI:
#   immortalwrt/diy-part5.sh — фиды, community-пакеты, патчи, 8 ГБ, синхронизация репозиториев;
#   immortalwrt/diy-part6.sh — проверка профиля/пакетов и патч mt76.
#
# Быстрая пересборка: если исходники, фиды и community-репозитории не менялись,
# скрипт только докатывает изменения через make и не перекачивает пакеты.
# При изменениях удалённых репозиториев diy-part5.sh обновляет клоны
# (сверка через git ls-remote), фиды перечитываются, пакеты скачиваются заново.
#
# Использование:
#   scripts/build-local.sh [--force] [--jobs N]
#     --force    обновить всё и принудительно скачать пакеты
#     --jobs N   число потоков сборки (по умолчанию — nproc)
#
# Переопределяемые переменные окружения:
#   OPENWRT_DIR, REPO_URL, REPO_BRANCH, CONFIG_FILE, DIY_P1_SH, DIY_P2_SH, JOBS

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OPENWRT_DIR="${OPENWRT_DIR:-$REPO_DIR/openwrt}"
REPO_URL="${REPO_URL:-https://github.com/immortalwrt/immortalwrt}"
REPO_BRANCH="${REPO_BRANCH:-openwrt-25.12}"
CONFIG_FILE="${CONFIG_FILE:-$REPO_DIR/immortalwrt/mediatek/defconfig-25.12}"
DIY_P1_SH="${DIY_P1_SH:-$REPO_DIR/immortalwrt/diy-part5.sh}"
DIY_P2_SH="${DIY_P2_SH:-$REPO_DIR/immortalwrt/diy-part6.sh}"
STATE_DIR="$OPENWRT_DIR/.diy-state"
JOBS="${JOBS:-$(nproc)}"
FORCE=0

# Кэш ccache держим внутри дерева сборки: $HOME в этой среде только для чтения.
export CCACHE_DIR="$OPENWRT_DIR/.ccache"
export CCACHE_BASEDIR="$OPENWRT_DIR"

# Убираем из PATH пользовательские python-обвязки ($HOME/.local/bin):
# buildroot выбирает для хостовых инструментов первый python3.13/python3,
# а uv-питон из ~/.local/bin идёт без setuptools и ломает prereq u-boot.
_read_path=()
IFS=: read -r -a _read_path <<< "$PATH"
PATH=""
for _dir in "${_read_path[@]}"; do
    [ "$_dir" = "$HOME/.local/bin" ] && continue
    PATH="${PATH:+$PATH:}$_dir"
done
export PATH
unset _read_path _dir

# Скрипты сборки и DIY-скрипты используют $GITHUB_WORKSPACE как корень репозитория.
export GITHUB_WORKSPACE="$REPO_DIR"
export LUCI_APP_REPO_URL="${LUCI_APP_REPO_URL:-https://github.com/foric27/luci-app}"
export LUCI_APP_REPO_BRANCH="${LUCI_APP_REPO_BRANCH:-main}"

OPENWRT_UPDATED=0
FEEDS_UPDATED=0
REPOS_UPDATED=0
CONFIG_CHANGED=0

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*" >&2; }

usage() {
    sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        -f|--force) FORCE=1; shift ;;
        -j|--jobs) JOBS="${2:?не указано число потоков}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "Неизвестный аргумент: $1 (используйте --help)" >&2; exit 2 ;;
    esac
done

remote_branch_sha() {
    git ls-remote --heads "$1" "refs/heads/$2" 2>/dev/null | awk '{print $1}' | head -n1 || true
}

preflight() {
    local tool
    for tool in git make sha256sum bash; do
        command -v "$tool" >/dev/null 2>&1 || { echo "Не найден $tool" >&2; exit 1; }
    done
    [ -f "$CONFIG_FILE" ] || { echo "Не найден конфиг: $CONFIG_FILE" >&2; exit 1; }
    [ -f "$DIY_P1_SH" ] || { echo "Не найден DIY-скрипт: $DIY_P1_SH" >&2; exit 1; }
    [ -f "$DIY_P2_SH" ] || { echo "Не найден DIY-скрипт: $DIY_P2_SH" >&2; exit 1; }

    command -v python3 >/dev/null 2>&1 || { echo "Не найден python3" >&2; exit 1; }
    python3 -c 'import setuptools' >/dev/null 2>&1 || {
        warn "У системного python3 нет setuptools — prereq u-boot может упасть"
    }

    # Buildroot кэширует хостовые симлинки: если staging уже создан, а python3
    # в нём указывает на питон без setuptools, prereq u-boot будет падать.
    if [ -d "$OPENWRT_DIR/staging_dir/host" ]; then
        local host_bin="$OPENWRT_DIR/staging_dir/host/bin"
        local sys_python
        sys_python="$(command -v python3)"
        mkdir -p "$host_bin"
        if [ -n "$sys_python" ] && "$sys_python" -c 'import setuptools' >/dev/null 2>&1; then
            ln -sf "$sys_python" "$host_bin/python3"
        fi
    fi
}

# Шаг 1 («Загрузка исходного кода прошивки» в workflow): клон или обновление OpenWrt.
step_sync_openwrt() {
    local remote_sha local_sha
    if [ ! -d "$OPENWRT_DIR/.git" ]; then
        log "Шаг 1/7: клонирование исходников OpenWrt ($REPO_BRANCH)"
        mkdir -p "$(dirname "$OPENWRT_DIR")"
        git clone --filter=blob:none --single-branch -c core.abbrev=7 \
            -b "$REPO_BRANCH" "$REPO_URL" "$OPENWRT_DIR"
        OPENWRT_UPDATED=1
        return 0
    fi

    remote_sha="$(remote_branch_sha "$REPO_URL" "$REPO_BRANCH")"
    local_sha="$(git -C "$OPENWRT_DIR" rev-parse HEAD)"
    if [ -z "$remote_sha" ]; then
        warn "Не удалось проверить обновления OpenWrt (нет сети?) — использую текущее дерево"
        return 0
    fi
    if [ "$remote_sha" = "$local_sha" ]; then
        echo "[src] OpenWrt актуален ($local_sha)"
        return 0
    fi
    log "Шаг 1/7: обновление исходников OpenWrt: $local_sha -> $remote_sha"
    git -C "$OPENWRT_DIR" fetch --depth=1 origin "$REPO_BRANCH"
    git -C "$OPENWRT_DIR" reset --hard FETCH_HEAD
    OPENWRT_UPDATED=1
}

# Проверяет, изменились ли ветки фидов из feeds.conf.default.
feeds_outdated() {
    local conf="$OPENWRT_DIR/feeds.conf.default"
    local line name url branch remote_sha local_sha
    [ -f "$conf" ] || return 1
    while IFS= read -r line; do
        # shellcheck disable=SC2086
        set -- $line
        case "$1" in
            src-git|src-git-full) ;;
            *) continue ;;
        esac
        name="$2"
        url="${3%%;*}"
        branch=""
        case "$3" in
            *";"*) branch="${3#*;}" ;;
        esac
        [ -n "$branch" ] || branch="master"
        case "$branch" in
            \^*) continue ;;  # фиксированный коммит в feeds.conf — проверять нечего
        esac
        [ -d "$OPENWRT_DIR/feeds/$name/.git" ] || return 0
        remote_sha="$(remote_branch_sha "$url" "$branch")"
        [ -n "$remote_sha" ] || return 1
        local_sha="$(git -C "$OPENWRT_DIR/feeds/$name" rev-parse HEAD 2>/dev/null || true)"
        if [ "$remote_sha" != "$local_sha" ]; then
            echo "[feeds] Фид $name устарел: $local_sha -> $remote_sha"
            return 0
        fi
    done < "$conf"
    return 1
}

# Шаг 2 («Обновление индексов базовых фидов»): только при изменениях.
step_update_feeds() {
    if [ "$OPENWRT_UPDATED" = 1 ] || [ "$FORCE" = 1 ] || feeds_outdated; then
        log "Шаг 2/7: обновление фидов OpenWrt"
        ( cd "$OPENWRT_DIR" && ./scripts/feeds update -a )
        FEEDS_UPDATED=1
    else
        echo "[feeds] Фиды актуальны"
    fi
}

# Шаг 3 («Установка фидов и community-пакетов»): diy-part5.sh.
step_diy_part5() {
    rm -f "$STATE_DIR/repos-updated"
    log "Шаг 3/7: immortalwrt/diy-part5.sh (фиды, community-пакеты, патчи)"
    ( cd "$OPENWRT_DIR" && bash "$DIY_P1_SH" )
    if [ -f "$STATE_DIR/repos-updated" ]; then
        REPOS_UPDATED=1
        echo "[repo] Часть репозиториев обновилась — понадобится скачивание пакетов"
    else
        echo "[repo] Все репозитории актуальны"
    fi
}

# Шаг 4 («Load config»): копируем defconfig в .config только если он изменился.
step_apply_config() {
    local hash saved_hash
    mkdir -p "$STATE_DIR"
    hash="$(sha256sum "$CONFIG_FILE" | awk '{print $1}')"
    saved_hash="$(cat "$STATE_DIR/config.sha" 2>/dev/null || true)"
    if [ "$FORCE" = 1 ] || [ "$hash" != "$saved_hash" ] || [ ! -f "$OPENWRT_DIR/.config" ]; then
        log "Шаг 4/7: применение конфигурации $CONFIG_FILE"
        cp "$CONFIG_FILE" "$OPENWRT_DIR/.config"
        printf '%s\n' "$hash" > "$STATE_DIR/config.sha"
        CONFIG_CHANGED=1
    else
        echo "[config] Конфигурация не менялась"
    fi
}

# Шаг 5: diy-part6.sh — проверка профиля и пакетов, патч mt76, правка IP.
step_diy_part6() {
    log "Шаг 5/7: immortalwrt/diy-part6.sh (проверка конфигурации и патч mt76)"
    ( cd "$OPENWRT_DIR" && bash "$DIY_P2_SH" )
}

# Шаг 6 («Скачивание пакетов»): make defconfig уже сделан в diy-part6.sh.
step_download_packages() {
    if [ "$FORCE" = 1 ] || [ "$OPENWRT_UPDATED" = 1 ] || [ "$FEEDS_UPDATED" = 1 ] \
        || [ "$REPOS_UPDATED" = 1 ] || [ "$CONFIG_CHANGED" = 1 ] || [ ! -d "$OPENWRT_DIR/dl" ]; then
        log "Шаг 6/7: скачивание пакетов (make download -j$JOBS)"
        ( cd "$OPENWRT_DIR" && make download -j"$JOBS" )
    else
        echo "[dl] Исходники, фиды, репозитории и конфигурация не менялись — скачивание пропущено"
    fi
}

# Шаг 7 («Сборка прошивки»).
step_build_firmware() {
    log "Шаг 7/7: сборка прошивки (make -j$JOBS; при ошибке — с меньшей параллельностью)"
    ( cd "$OPENWRT_DIR" && { make -j"$JOBS" || make -j"$(( JOBS / 2 + 1 ))" || make -j1 V=s; } )
    log "Сборка завершена. Каталог образов: $OPENWRT_DIR/bin/targets/mediatek/filogic"
    ls -1 "$OPENWRT_DIR/bin/targets/mediatek/filogic" 2>/dev/null | head -n 40 || true
}

main() {
    preflight

    log "Локальная сборка ImmortalWrt 25.12 для BPI-R4"
    echo "Репозиторий:    $REPO_DIR"
    echo "Дерево OpenWrt: $OPENWRT_DIR"
    echo "DIY part5:      $DIY_P1_SH"
    echo "DIY part6:      $DIY_P2_SH"
    echo "Потоков:        $JOBS"

    step_sync_openwrt
    step_update_feeds
    step_diy_part5
    step_apply_config
    step_diy_part6
    step_download_packages
    step_build_firmware
}

main "$@"
