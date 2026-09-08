#!/bin/bash
set -e
#
# diy-mtk.sh -- Сообщества пакеты и конфигурация для сборки chasey-dev
#
# WiFi собирается через upstream mac80211/mt76 (mt7996e). Дремлющие фиксы
# vendor-драйвера mt_wifi7 (Kconfig-маппинги, совместимостные патчи 900-904)
# удалены; при возврате на vendor-драйвер восстановить из git-истории.
#

# Диагностика: номер строки при аварийном завершении (set -e)
trap 'echo "[DIY] Ошибка в diy-mtk.sh на строке $LINENO" >&2' ERR

# Гвард: скрипт оперирует относительными путями (package/..., scripts/feeds)
# и обязан запускаться из корня дерева OpenWrt (так делает build.sh и workflow).
if [ ! -f rules.mk ] || [ ! -x scripts/feeds ]; then
    echo "[DIY] Запуск только из корня дерева openwrt/ (текущий cwd: $PWD)" >&2
    exit 1
fi

patch_makefile_dep() {
    local file_path="$1"
    local old_text="$2"
    local new_text="$3"
    local perl_status

    [ -f "$file_path" ] || return 0
    grep -qzF "$old_text" "$file_path" || return 0

    PATCH_OLD_TEXT="$old_text" PATCH_NEW_TEXT="$new_text" \
        perl -0pi -e 'BEGIN { $old = $ENV{"PATCH_OLD_TEXT"}; $new = $ENV{"PATCH_NEW_TEXT"}; }
            $count = s/\Q$old\E/$new/g;
            END { exit($count > 0 ? 0 : 2); }' "$file_path"
    perl_status=$?

    [ "$perl_status" -eq 0 ] || {
        echo "Не удалось применить литеральный патч к $file_path" >&2
        return "$perl_status"
    }
}

apply_workspace_patch() {
    local patch_file="$1"

    [ -f "$patch_file" ] || return 0

    if git apply --recount --ignore-space-change --ignore-whitespace --reverse --check "$patch_file" >/dev/null 2>&1; then
        return 0
    fi

    git apply --recount --ignore-space-change --ignore-whitespace "$patch_file"
}

# ============================================================
# Пакеты сообщества (клонирование параллельно)
# ============================================================
mkdir -p package/community
pushd package/community >/dev/null

# Формат: имя;владелец/репозиторий
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

# Удаление перед клонированием (всегда чистое)
_clone_pids=""
for _entry in $COMMUNITY_PKGS; do
    _name="${_entry%%;*}"
    _repo="${_entry#*;}"
    ( rm -rf "$_name"; git clone --depth=1 --quiet "https://github.com/$_repo" "$_name" ) \
        || { echo "[DIY] Не удалось склонировать $_repo" >&2; exit 1; } &
    _clone_pids="$_clone_pids $!"
done

_clone_fail=0
for _pid in $_clone_pids; do
    wait "$_pid" || _clone_fail=1
done
popd >/dev/null

if [ "$_clone_fail" -ne 0 ]; then
    echo "[DIY] Ошибка клонирования community-пакетов" >&2
    exit 1
fi
echo "[DIY] community-пакеты склонированы (параллельно)"

# ============================================================
# Локальные пакеты (переведены на русский, источник: github.com/MedyMa/luci-app)
# Копируется всё содержимое packages/ — новые приложения подхватываются
# автоматически. Включение в прошивку контролируется defconfig
# (гейт REQUIRED_IN_CONFIG в build.sh).
# ============================================================
# rm -rf + cp -aT: идемпотентно (без вложенного копирования при повторном запуске)
if ! ls "$GITHUB_WORKSPACE/packages/"* >/dev/null 2>&1; then
    echo "Каталог $GITHUB_WORKSPACE/packages/ пуст или отсутствует" >&2
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
echo "[DIY] локальные пакеты скопированы:$_copied_list"

# ============================================================
# Фиксы базового дерева
# ============================================================

# Обход GCC 14 + musl fortify для mbedtls
if ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
    if grep -q '\$(if \$(findstring cortex-a53,\$(CONFIG_CPU_TYPE)),-march=armv8-a)' package/libs/mbedtls/Makefile; then
        sed -i '/$(if $(findstring cortex-a53,$(CONFIG_CPU_TYPE)),-march=armv8-a)/a TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile
  else
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
  fi
fi

# hostapd: исключение приватного MTK MLO PMKSA патча (975) из сборок без 11BE.
# Upstream-патч ссылается на sta->mld_assoc_link_id / sta->mld_info, которые
# существуют только при CONFIG_IEEE80211BE; это дерево собирает wpad без 11BE
# (DRIVER_11x_SUPPORT — скрытые символы со значением по умолчанию n, а `make defconfig`
# сбрасывает их), поэтому MLO-блок должен быть исключён из компиляции. Upstream
# переписал патч 15-16.08.2025 (новые переменные pmksa_addr/pmksa_link_addr, новый стиль
# комментариев), что сломало предыдущую инъекцию защитного текста. Используются
# regex-защиты, которые переживают изменения текста/комментариев, и увеличивается
# счётчик строк ханка на +3 строки, добавляемые инъекцией.
_mt975="package/network/services/hostapd/patches/975-mtk-mlo-pass-pmksa-link-address.patch"
if [ -f "$_mt975" ]; then
    if perl -0777 -e '
        local $/;
        my $txt = <STDIN>;
        my $n = 0;
        $n++ if $txt =~ s/^(\+\t)bool is_ml = ap_sta_has_ml_rsn\(hapd, sta\);\n/${1}bool is_ml = false;\n+#ifdef CONFIG_IEEE80211BE\n${1}is_ml = ap_sta_has_ml_rsn(hapd, sta);\n/m;
        $n++ if $txt =~ s/^(\+\tif \(is_ml\) \{.*?^(\+\t)\}\n)/$1+#endif \/* CONFIG_IEEE80211BE *\/\n/ms;
        if ($n == 2) {
            $txt =~ s/^(\@\@ [^\n]*\+[0-9]+,)(\d+)( \@\@(?=[^\n]*\n \n void sae_accept_sta))/sprintf("%s%d%s", $1, $2 + 3, $3)/me;
            print $txt;
            exit 0;
        }
        exit 2;
    ' < "$_mt975" > "$_mt975.new"; then
        mv "$_mt975.new" "$_mt975"
        echo "[DIY] hostapd 975 guard: #ifdef CONFIG_IEEE80211BE инжектирован (regex, hunk count +3)"
    else
        rm -f "$_mt975.new"
        echo "[DIY] hostapd 975 guard: ПРОПУСК - формат патча 975 изменился, MLO-блок оставлен без защиты" >&2
    fi
fi

# MTK Wi-Fi профили: замена версии chasey-dev на mt7990-only сборку padavanonly
# (версия chasey-dev ссылается на несуществующие файлы mt7622/mt7615 и использует сломанную
# подстановку shell-команд для значений Kconfig). Частичный sparse-клон: скачивается
# только package/mtk/drivers/wifi-profile вместо всего дерева (сотни МБ).
rm -rf package/mtk/drivers/wifi-profile
rm -rf /tmp/padavanonly-wifi-profile
if ! git clone --depth=1 --filter=blob:none --sparse --quiet \
        -b mt798x-mt799x-6.6-mtwifi \
        https://github.com/padavanonly/immortalwrt-mt798x-6.6.git \
        /tmp/padavanonly-wifi-profile 2>/dev/null; then
    echo "[DIY] sparse-clone недоступен, используется полный клон" >&2
    git clone --depth=1 --quiet -b mt798x-mt799x-6.6-mtwifi \
        https://github.com/padavanonly/immortalwrt-mt798x-6.6.git \
        /tmp/padavanonly-wifi-profile
fi
git -C /tmp/padavanonly-wifi-profile sparse-checkout set package/mtk/drivers/wifi-profile >/dev/null 2>&1 || true
if [ ! -d "/tmp/padavanonly-wifi-profile/package/mtk/drivers/wifi-profile" ]; then
    echo "[DIY] wifi-profile не найден в padavanonly/mt798x-mt799x-6.6-mtwifi" >&2
    exit 1
fi
mv /tmp/padavanonly-wifi-profile/package/mtk/drivers/wifi-profile package/mtk/drivers/wifi-profile
rm -rf /tmp/padavanonly-wifi-profile
# Удаление устаревшего wifi_jedi → /sbin/wifi установка (конфликтует с wifi-scripts ImmortalWrt 25.12)
sed -i 's|$(INSTALL_BIN) ./files/common/wifi_jedi $(1)/sbin/wifi|# DIY: removed – conflicts with wifi-scripts|' \
    package/mtk/drivers/wifi-profile/Makefile
echo "[DIY] wifi-profile заменён на mt7990-only версию padavanonly"

# datconf: отключение параллельной сборки (5 подпакетов делят одно дерево CMake, гонка при -j>1)
if [ -f "package/mtk/applications/datconf/Makefile" ] && \
   ! grep -q 'PKG_BUILD_PARALLEL' "package/mtk/applications/datconf/Makefile"; then
    sed -i '/^PKG_RELEASE:=/a PKG_BUILD_PARALLEL:=0' "package/mtk/applications/datconf/Makefile"
    echo "[DIY] datconf: параллельная сборка отключена"
fi

# ============================================================
# Фиды
# ============================================================

# Зависимости фидов для сообщественных клонов (pcre2 в основном дереве с 25.12)
./scripts/feeds update -a

# Удаление onionshare-cli (нерешённые метаданные, отсутствует в конфиге)
rm -rf feeds/packages/net/onionshare-cli

[ -f feeds/luci/applications/luci-app-package-manager/root/usr/libexec/package-manager-call ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1004-luci-package-manager-apk-upload-untrusted-master.patch"

# vpnc: добавление -p в mkdir для идемпотентности
if grep -q 'mkdir $(PKG_BUILD_DIR)/bin' feeds/packages/net/vpnc/Makefile 2>/dev/null; then
    sed -i '/mkdir $(PKG_BUILD_DIR)\/bin/s/mkdir /mkdir -p /' feeds/packages/net/vpnc/Makefile
fi

# Удаление пакетов из фидов, заменённых клонами/локальными пакетами
# (предотвращает warnings "Not overriding core package" от feeds install -a)
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/applications/luci-app-modemband
rm -rf feeds/luci/themes/luci-theme-argon

./scripts/feeds install -a


# Удаление репо kiddin9 APK (вызывает сломанный подрепо video/)
for f in \
    package/base-files/files/etc/apk/repositories \
    package/base-files/files/etc/apk/repositories.d/* \
    package/utils/alpine-repositories/files/repositories; do
    [ -f "$f" ] && grep -q 'kiddin9' "$f" 2>/dev/null && sed -i '/kiddin9/d' "$f" 2>/dev/null || true
done

# Исправления APK runtime: разрешение локальной загрузки неподписанных APK и отключение сломанных записей фидов
rm -f package/base-files/files/etc/uci-defaults/99-apk-untrusted
[ -d package/base-files/files/etc/uci-defaults ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1005-base-files-apk-manager-fixes-master.patch"

# luci-ssl-openssl: мерж luci-фидов от 2026-08-24 добавил зависимость от
# px5g-openssl, которого нет в этом SDK (chasey-dev rebase) (immortalwrt
# добавил его в своё дерево 20-го августа). Откат на px5g-standalone, который
# присутствует здесь и устанавливает тот же /usr/sbin/px5g.
_ssl_makefile="feeds/luci/collections/luci-ssl-openssl/Makefile"
if [ -f "$_ssl_makefile" ] && \
    grep -qF -- '+px5g-openssl' "$_ssl_makefile" && \
    [ ! -d package/utils/px5g-openssl ]; then
    sed -i 's/+px5g-openssl/+px5g-standalone/' "$_ssl_makefile"
    grep -qF -- '+px5g-standalone' "$_ssl_makefile" || {
        echo 'Не удалось переключить luci-ssl-openssl на px5g-standalone' >&2
        exit 1
    }
    echo "[DIY] luci-ssl-openssl: зависимость px5g-openssl -> px5g-standalone"
fi

# Уменьшение задержки загрузки U-Boot BPI-R4
_uboot_patch="package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch"
if [ -f "$_uboot_patch" ]; then
    patch_makefile_dep "$_uboot_patch" 'CONFIG_BOOTDELAY=30' 'CONFIG_BOOTDELAY=10'
else
    echo "[DIY] ВНИМАНИЕ: $_uboot_patch не найден — BOOTDELAY не уменьшен" >&2
fi

# Исправление пустого install target для uboot-mediatek (вызывает ложные Error 1 ignored)
if grep -q '^define Package/u-boot/install$' package/boot/uboot-mediatek/Makefile 2>/dev/null; then
    sed -i '/^define Package\/u-boot\/install$/,/^endef$/{
        /^define Package\/u-boot\/install$/a\	# install handled by Build/InstallDev
    }' package/boot/uboot-mediatek/Makefile
    echo "[DIY] uboot-mediatek: пустой install target исправлен"
fi

# Фиксация символов ядра Kconfig для избежания интерактивных запросов (новые символы)
CFG="target/linux/mediatek/filogic/config-6.12"
if [ -f "$CFG" ]; then
    for sym in MEDIATEK_2P5GE_PHY NET_MEDIATEK_HNAT MEDIATEK_NETSYS_V3 NETFILTER; do
        case "$sym" in
            MEDIATEK_2P5GE_PHY) val="# CONFIG_${sym} is not set" ;;
            NET_MEDIATEK_HNAT)   val="CONFIG_${sym}=m" ;;
            *)                   val="CONFIG_${sym}=y" ;;
        esac
        sed -i "/^CONFIG_${sym}=/d; /^# CONFIG_${sym} is not set$/d" "$CFG"
        echo "$val" >> "$CFG"
    done
else
    echo "[DIY] ВНИМАНИЕ: $CFG не найден — фиксация символов ядра пропущена" >&2
fi
