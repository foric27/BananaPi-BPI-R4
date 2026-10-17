#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
set -euo pipefail
#
# customize.sh -- кастомизация чистой OpenWrt (openwrt-25.12) фидом
#                mediatek/mtk-openwrt-feeds (25.12 / kernel 6.12)
#
# Порядок (по гайду MTK + наши слои):
#   1) фиды (add mtk feed -> update/install)
#   2) файлы/тулы MTK
#   3) WiFi-стек MTK (mac80211-вариант: remove_list + files)
#   4) очередь патчей (MTK base/feeds/вариант + наши) и ОДИН проход применения
#   5) адаптации backports, hostapd-снапшот
#   6) community/локальные пакеты, фиксы базового дерева
#   7) фиксы базового дерева и гейты (WiFi-стек, 8GB U-Boot/ATF, MAC, kernel pins)
#
# Значения kernel-символов живут в config/defconfig, объявления — в
# config/Config-kernel.in (патч 1030).
#
# Запускать строго из корня дерева OpenWrt (так делают build.sh и workflow).
#

trap 'echo "[CUSTOM] Ошибка в customize.sh на строке $LINENO" >&2' ERR

if [ ! -f rules.mk ] || [ ! -x scripts/feeds ]; then
    echo "[CUSTOM] Запуск только из корня дерева openwrt/ (текущий cwd: $PWD)" >&2
    exit 1
fi

# Без него относительные пути к patches/ и src/ молча превращаются в /src/...
: "${GITHUB_WORKSPACE:?[CUSTOM] GITHUB_WORKSPACE не задан (запускайте через build.sh или CI)}"

MTK_FEED="${GITHUB_WORKSPACE}/src/mtk-openwrt-feeds"
MTK_VER="25.12"
PATCHES="${GITHUB_WORKSPACE}/patches/25.12"
if [ ! -d "$MTK_FEED/$MTK_VER" ]; then
    echo "[CUSTOM] Фид MTK не найден: $MTK_FEED/$MTK_VER" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
apply_workspace_patch() {
    local patch_file="$1"
    [ -f "$patch_file" ] || return 0
    if git apply --recount --ignore-space-change --ignore-whitespace --reverse --check "$patch_file" >/dev/null 2>&1; then
        return 0
    fi
    git apply --recount --ignore-space-change --ignore-whitespace "$patch_file"
}

# Применение патча MTK с пропуском уже применённого (идемпотентность)
apply_mtk_patch() {
    local patch_file="$1"
    if patch -p1 -R --dry-run -f -i "$patch_file" >/dev/null 2>&1; then
        return 0
    fi
    patch -p1 -f -i "$patch_file" >/dev/null
}

# Повтор сетевых операций (GitHub/фиды бывают недоступны)
run_retry() {
    local _try=1
    while [ "$_try" -le 5 ]; do
        if "$@"; then return 0; fi
        echo "[CUSTOM] операция не удалась (попытка $_try/5): $*" >&2
        _try=$((_try + 1))
        sleep 10
    done
    return 1
}

# ---------------------------------------------------------------------------
# Очередь патчей: элемент "файл|метод", метод mtk (patch) или git (git apply)
# ---------------------------------------------------------------------------
PATCH_QUEUE=()

queue_dir() {
    local f
    [ -d "$1" ] || return 0
    while IFS= read -r f; do
        PATCH_QUEUE+=("$f|$2")
    done < <(find "$1" -name '*.patch' | sort)
}

# ============================================================
# 1. MTK feed + фиды
# ============================================================
grep -q 'mtk_openwrt_feed' feeds.conf.default || \
    echo "src-git mtk_openwrt_feed https://github.com/mediatek/mtk-openwrt-feeds.git;main" >> feeds.conf.default

echo "[CUSTOM] feeds update -a"
run_retry ./scripts/feeds update -a
echo "[CUSTOM] feeds install -a"
./scripts/feeds install -a

# ============================================================
# 2. Файлы MTK (target/linux/mediatek, package/mtk, scripts, tools, generic)
# ============================================================
cp -a "$MTK_FEED/$MTK_VER/files/." .
echo "[CUSTOM] MTK files скопированы"

# Слой logan_common (общий для Logan-платформ): драйвер ядра mtk_hnat
# (files-6.12) и его quilt-патчи (999-hnat-*, 999-eth-91-*, tunnel/offload).
# Без него kmod-mediatek_hnat собирается пустым, и turboacc не находит HNAT.
LOGAN_FILES="$MTK_FEED/autobuild/unified/global/logan_common/$MTK_VER/files"
if [ -d "$LOGAN_FILES" ]; then
    cp -a "$LOGAN_FILES/." .
    echo "[CUSTOM] logan_common скопирован (HNAT-драйвер + kernel-патчи)"
else
    echo "[CUSTOM] ВНИМАНИЕ: слой logan_common не найден: $LOGAN_FILES" >&2
fi

# Host-тулы MTK (fdt-patch-dm-verify, crc32sum, ar-tool) — tools/Makefile
# патчится на них, поэтому копируем.
if [ -d "$MTK_FEED/tools" ]; then
    mkdir -p tools
    cp -a "$MTK_FEED/tools/." tools/
    echo "[CUSTOM] MTK host-тулы скопированы"
fi

# ============================================================
# 3. WiFi-стек MTK (вариант mac80211): remove_list + файлы
# ============================================================
MAC_DIR="$MTK_FEED/autobuild/unified/filogic/mac80211/$MTK_VER"
if [ ! -d "$MAC_DIR" ]; then
    echo "[CUSTOM] WiFi-стек MTK не найден: $MAC_DIR" >&2
    echo "[CUSTOM] Ожидается вариант mt76/mac80211/hostapd из mtk-openwrt-feeds@main" >&2
    exit 1
fi
if [ -f "$MAC_DIR/remove_list.txt" ]; then
    while read -r _rm; do
        [ -n "$_rm" ] && rm -rf "$_rm"
    done < "$MAC_DIR/remove_list.txt"
fi
[ -d "$MAC_DIR/files" ] && cp -a "$MAC_DIR/files/." .

# ============================================================
# 4. Очередь патчей (порядок важен: MTK base -> feeds -> вариант -> наши)
# ============================================================
queue_dir "$MTK_FEED/$MTK_VER/patches-base" mtk
queue_dir "$MTK_FEED/$MTK_VER/patches-feeds" mtk
queue_dir "$MAC_DIR/patches-base" mtk

# Наши патчи: применяются ВСЕ из patches/25.12 (авто-обнаружение, sorted).
# Маршрутизация в цикле ниже по имени файла.
queue_dir "$PATCHES" auto

_ok=0
for _job in "${PATCH_QUEUE[@]}"; do
    _pf="${_job%|*}"
    _pm="${_job##*|}"
    _bn="$(basename "$_pf")"
    case "$_pm" in
        mtk)
            apply_mtk_patch "$_pf" || { echo "[CUSTOM] не применён патч: $_pf" >&2; exit 1; }
            ;;
        auto)
            case "$_bn" in
                # backports-адаптации: ставятся пакетными патчами mac80211
                # (9998/9999 — применяются последними, после серии MTK)
                0982-*)
                    mkdir -p package/kernel/mac80211/patches/subsys
                    cp -f "$_pf" "package/kernel/mac80211/patches/subsys/9998-backports-drop-qrtr-mhi.patch"
                    echo "[CUSTOM] mac80211: установлен 9998-backports-drop-qrtr-mhi"
                    ;;
                0981-*)
                    mkdir -p package/kernel/mac80211/patches/subsys
                    cp -f "$_pf" "package/kernel/mac80211/patches/subsys/9999-backports-sockaddr-unsized-revert.patch"
                    echo "[CUSTOM] mac80211: установлен 9999-backports-sockaddr-unsized-revert"
                    ;;
                # dtc: пакетный патч (убирает -Werror из meson)
                1020-*)
                    mkdir -p package/utils/dtc/patches
                    cp -f "$_pf" "package/utils/dtc/patches/$_bn"
                    echo "[CUSTOM] dtc: установлен $_bn"
                    ;;
                # kernel-патч: guard tc-flowtable при HNAT (инертный на этой
                # базе, но применим — защита от регрессии)
                999-zzz-*)
                    mkdir -p target/linux/mediatek/patches-6.12
                    cp -f "$_pf" "target/linux/mediatek/patches-6.12/$_bn"
                    echo "[CUSTOM] kernel: установлен $_bn"
                    ;;
                *)
                    apply_workspace_patch "$_pf" || { echo "[CUSTOM] не применён патч: $_pf" >&2; exit 1; }
                    echo "[CUSTOM] применён патч дерева: $_bn"
                    ;;
            esac
            ;;
    esac
    _ok=$((_ok + 1))
done
echo "[CUSTOM] применено/установлено патчей: $_ok"

# ============================================================
# 5. hostapd-снапшот (после патчей варианта)
# ============================================================
# hostapd-снапшот MTK отсутствует в зеркалах — префетч тарболла из git.w1.fi
# и отключение сверки PKG_MIRROR_HASH (источник пинован по SHA).
_hs_mk="package/network/services/hostapd/Makefile"
if [ -f "$_hs_mk" ]; then
    _hs_date="$(grep -m1 '^PKG_SOURCE_DATE:=' "$_hs_mk" | cut -d= -f2 | tr '-' '.')"
    _hs_sha="$(grep -m1 '^PKG_SOURCE_VERSION:=' "$_hs_mk" | cut -d= -f2)"
    _hs_ver="${_hs_date}~$(printf '%s' "$_hs_sha" | cut -c1-8)"
    if [ -z "$_hs_date" ] || [ -z "$_hs_sha" ]; then
        echo "[CUSTOM] hostapd: не удалось прочитать PKG_SOURCE_DATE/PKG_SOURCE_VERSION" >&2
        exit 1
    fi
    mkdir -p dl
    if [ ! -s "dl/hostapd-${_hs_ver}.tar.zst" ]; then
        echo "[CUSTOM] hostapd: префетч снапшота ${_hs_ver} из git.w1.fi"
        rm -rf .hs-fetch "hostapd-${_hs_ver}"
        mkdir -p .hs-fetch
        (
            cd .hs-fetch
            git init -q .
            git remote add origin https://git.w1.fi/hostap.git
            _try=1
            while [ "$_try" -le 5 ]; do
                if git -c http.version=HTTP/1.1 \
                       -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
                       fetch -q --depth 1 origin "$_hs_sha" && \
                   git checkout -q FETCH_HEAD; then
                    break
                fi
                echo "[CUSTOM] hostapd: попытка $_try не удалась, повтор..." >&2
                _try=$((_try + 1))
                sleep 5
            done
            [ -d .git ] && git rev-parse -q --verify FETCH_HEAD >/dev/null || {
                echo "[CUSTOM] hostapd: не удалось получить снапшот после ретраев" >&2
                exit 1
            }
            git submodule update --init --recursive -q 2>/dev/null || true
        )
        rm -rf .hs-fetch/.git
        mv .hs-fetch "hostapd-${_hs_ver}"
        _ZSTD="$(command -v zstd || true)"
        [ -n "$_ZSTD" ] || _ZSTD="$GITHUB_WORKSPACE/src/openwrt/staging_dir/host/bin/zstd"
        _hs_tar="dl/hostapd-${_hs_ver}.tar.zst"
        _hs_tmp="${_hs_tar}.tmp"
        # pipefail обязателен: иначе сбой tar в конвейере ниже не виден,
        # и в dl/ остаётся обрезанный архив, который всплывёт при распаковке.
        if ! tar --numeric-owner --owner=0 --group=0 --sort=name -c "hostapd-${_hs_ver}" | \
                "$_ZSTD" -T0 -19 -c > "$_hs_tmp"; then
            rm -rf "hostapd-${_hs_ver}" "$_hs_tmp"
            echo "[CUSTOM] hostapd: не удалось упаковать снапшот" >&2
            exit 1
        fi
        if [ ! -s "$_hs_tmp" ] || ! "$_ZSTD" -t "$_hs_tmp"; then
            rm -rf "hostapd-${_hs_ver}" "$_hs_tmp"
            echo "[CUSTOM] hostapd: архив не прошёл проверку zstd -t" >&2
            exit 1
        fi
        mv -f "$_hs_tmp" "$_hs_tar"
        rm -rf "hostapd-${_hs_ver}"
    fi
    sed -i 's/^PKG_MIRROR_HASH:=.*/PKG_MIRROR_HASH:=skip/' "$_hs_mk"
    grep -q '^PKG_MIRROR_HASH:=skip' "$_hs_mk" || {
        echo "[CUSTOM] hostapd: PKG_MIRROR_HASH не удалось перевести в skip" >&2
        exit 1
    }
    echo "[CUSTOM] hostapd: снапшот MTK готов, PKG_MIRROR_HASH=skip"
fi

# ============================================================
# 6. Пакеты: community (git clone) и локальные (packages/)
# ============================================================
mkdir -p package/community
pushd package/community >/dev/null

COMMUNITY_PKGS="
luci-theme-argon;jerrykuku/luci-theme-argon
luci-app-argon-config;jerrykuku/luci-app-argon-config
luci-app-temp-status;gSpotx2f/luci-app-temp-status
luci-app-cpu-status;gSpotx2f/luci-app-cpu-status
luci-app-cpu-perf;gSpotx2f/luci-app-cpu-perf
luci-app-interfaces-statistics;gSpotx2f/luci-app-interfaces-statistics
luci-app-disks-info;gSpotx2f/luci-app-disks-info
luci-app-internet-detector;gSpotx2f/luci-app-internet-detector
"

_clone_pids=""
for _entry in $COMMUNITY_PKGS; do
    _name="${_entry%%;*}"
    _repo="${_entry#*;}"
    ( rm -rf "$_name"; run_retry git clone --depth=1 --quiet "https://github.com/$_repo" "$_name" ) \
        || { echo "[CUSTOM] Не удалось склонировать $_repo" >&2; exit 1; } &
    _clone_pids="$_clone_pids $!"
done

_clone_fail=0
for _pid in $_clone_pids; do
    wait "$_pid" || _clone_fail=1
done
popd >/dev/null

if [ "$_clone_fail" -ne 0 ]; then
    echo "[CUSTOM] Ошибка клонирования community-пакетов" >&2
    exit 1
fi
echo "[CUSTOM] community-пакеты склонированы"

# Локальные пакеты (включение контролируется defconfig, гейт в build.sh)
if ! ls "$GITHUB_WORKSPACE/packages/"* >/dev/null 2>&1; then
    echo "[CUSTOM] Каталог $GITHUB_WORKSPACE/packages/ пуст или отсутствует" >&2
    exit 1
fi
mkdir -p package/openwrt-packages
_copied_list=""
for _src_dir in "$GITHUB_WORKSPACE/packages/"*/; do
    [ -d "$_src_dir" ] || continue
    pkg="$(basename "$_src_dir")"
    _copied_list="$_copied_list $pkg"
    rm -rf "package/openwrt-packages/$pkg"
    cp -aT "$_src_dir" "package/openwrt-packages/$pkg"
done
echo "[CUSTOM] локальные пакеты скопированы:$_copied_list"

# Дубли из фидов, которые мы поставляем локально (иначе warning/конфликт)
for _dup in luci-app-modemband luci-theme-argon luci-app-argon-config; do
    rm -rf "feeds/luci/applications/$_dup" "feeds/luci/themes/$_dup"
done

# ============================================================
# 7. Фиксы базового дерева и гейты
# ============================================================

# GCC 14 + musl fortify для mbedtls
if [ -f package/libs/mbedtls/Makefile ] && ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
fi

# dtc: -Werror-патч уже установлен единым циклом патчей (см. auto/1020-*)

# vpnc: mkdir без -p не идемпотентен (повторная сборка падает 'File exists')
if [ -f feeds/packages/net/vpnc/Makefile ]; then
    sed -i '/mkdir \$(PKG_BUILD_DIR)\/bin/s/mkdir /mkdir -p /' feeds/packages/net/vpnc/Makefile
fi

# BPI-R4: дубли имён портов. Патч 184 вешает label на gsw-PHY, патч 189
# (полностью перекрывает: те же pinctrl/LED) — на DSA-порты; вместе дают
# дубли "wan"/"lan1..3". Убираем устаревший 184.
_DTS184="target/linux/mediatek/patches-6.12/184-arm64-dts-mediatek-mt7988a-bpi-r4-configure-switch-phys-and-leds.patch"
if [ -f "$_DTS184" ]; then
    rm -f "$_DTS184"
    echo "[CUSTOM] BPI-R4: удалён устаревший DTS-патч 184 (дубли портов)"
fi

# ============================================================
# 8. Гейты: WiFi-стек, 8GB U-Boot/ATF, MAC, объявления kernel-символов
# ============================================================
# README обещает, что неприменение любого из слоёв роняет сборку. Проверки
# ниже — это и есть обещание: молчаливая деградация (пустой набор патчей,
# отсутствующий comb-4bg) должна падать здесь, а не на устройстве.
_gate_fail=0
gate_fail() {
    echo "[CUSTOM] ГЕЙТ: $*" >&2
    _gate_fail=1
}

gate_patch_count() {
    local dir="$1" min="$2" n
    n=$(find "$dir" -name '*.patch' 2>/dev/null | wc -l)
    [ "$n" -ge "$min" ] || gate_fail "ожидалось >= $min патчей в $dir, найдено $n"
}

# WiFi: вариант MTK разложен, его патчи и наши backports-адаптации на месте
gate_patch_count package/kernel/mt76/patches 50
gate_patch_count package/kernel/mac80211/patches 50
gate_patch_count package/network/services/hostapd/patches 50
[ -f package/kernel/mac80211/patches/subsys/9998-backports-drop-qrtr-mhi.patch ] || \
    gate_fail "не установлен 9998-backports-drop-qrtr-mhi.patch"
[ -f package/kernel/mac80211/patches/subsys/9999-backports-sockaddr-unsized-revert.patch ] || \
    gate_fail "не установлен 9999-backports-sockaddr-unsized-revert.patch"

# 8GB: сборки comb-4bg в TF-A/U-Boot (патчи 1011/1012)
grep -q 'comb-4bg' package/boot/arm-trusted-firmware-mediatek/Makefile 2>/dev/null || \
    gate_fail "в TF-A Makefile нет сборок comb-4bg (патч 1011 не применён)"
grep -q 'comb-4bg' package/boot/uboot-mediatek/Makefile 2>/dev/null || \
    gate_fail "в U-Boot Makefile нет зависимостей comb-4bg (патч 1012 не применён)"

# MAC: стабильные адреса для SD/eMMC (патч 1035)
grep -q 'macaddr_generate_from_mmc_cid' \
    target/linux/mediatek/filogic/base-files/etc/board.d/02_network 2>/dev/null || \
    gate_fail "02_network не содержит MAC-фикса для SD/eMMC (патч 1035 не применён)"

# kernel pins: объявления символов, без которых make defconfig их выбросит (патч 1030)
grep -q 'config KERNEL_NF_CONNTRACK' config/Config-kernel.in 2>/dev/null || \
    gate_fail "config/Config-kernel.in не содержит пинов (патч 1030 не применён)"

if [ "$_gate_fail" -ne 0 ]; then
    echo "[CUSTOM] Гейты не пройдены — сборка остановлена" >&2
    exit 1
fi
echo "[CUSTOM] гейты пройдены: WiFi-стек, 8GB, MAC, kernel pins"

