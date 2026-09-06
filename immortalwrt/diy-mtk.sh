#!/bin/bash
#
# diy-mtk.sh -- Сообщества пакеты и конфигурация для сборки chasey-dev
#

merge_package(){
    repo=`echo $1 | rev | cut -d'/' -f 1 | rev`
    pkg=`echo $2 | rev | cut -d'/' -f 1 | rev`
    git clone --depth=1 --single-branch $1
    [ -d package/openwrt-packages ] || mkdir -p package/openwrt-packages
    mv $2 package/openwrt-packages/
    rm -rf $repo
}

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

# Удаление upstream-фидов, заменённых сообщественными клонами ниже
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/applications/luci-app-modemband
rm -rf package/mtk/applications/luci-app-turboacc-mtk
rm -rf feeds/packages/net/adguardhome

# Клонирование пакетов сообщества
mkdir -p package/community
pushd package/community
rm -rf luci-theme-argon luci-app-argon-config
git clone --depth=1 https://github.com/jerrykuku/luci-theme-argon
git clone --depth=1 https://github.com/jerrykuku/luci-app-argon-config
merge_package https://github.com/kenzok8/jell jell/adguardhome
# Исправление сломанного default_username.patch: upstream zh-cn.json был реорганизован
# с момента создания патча (контекст ханка переместился с ~L571 на ~L755, отступы
# изменились с 4 пробелов на 2). Замена на исправленный ханк, чтобы сборка
# не падала на этапе подготовки AdGuardHome.
_adguardhome_patch="package/openwrt-packages/adguardhome/patches/default_username.patch"
if [ -f "$_adguardhome_patch" ]; then
	cat > "$_adguardhome_patch" << 'AGPATCH'
--- a/client/src/__locales/zh-cn.json
+++ b/client/src/__locales/zh-cn.json
@@ -752,7 +752,7 @@
   "use_private_ptr_resolvers_title": "使用私人反向 DNS 解析器",
   "use_saved_key": "使用之前保存的密钥",
   "username_label": "用户名",
-  "username_placeholder": "输入用户名",
+  "username_placeholder": "默认用户名密码都是root",
   "validated_with_dnssec": "通过 DNSSEC 验证",
   "version": "版本",
   "version_request_error": "检查更新失败。请检查互联网连接。",
AGPATCH
	echo "[DIY] adguardhome default_username.patch пересобран для v0.107.78"
fi
# Локальные пакеты (переведены на русский, источник: github.com/MedyMa/luci-app)
for pkg in luci-app-fan luci-app-sfp-status luci-app-adguardhome luci-app-modemband luci-app-turboacc-mtk; do
    cp -r "$GITHUB_WORKSPACE/packages/$pkg" package/openwrt-packages/
done
popd

# adguardhome: пропуск хеша фронтенда (хеш релизного ассета GitHub непостоянен)
patch_makefile_dep \
    package/community/package/openwrt-packages/adguardhome/Makefile \
    'FRONTEND_HASH:=084bf3e00ca3e49487fc5a87270b4e1eb26617710ca6116b9e42ce90cb1ad358' \
    'FRONTEND_HASH:=skip'

# Обход GCC 14 + musl fortify для mbedtls
if ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
    if grep -q '\$(if \$(findstring cortex-a53,\$(CONFIG_CPU_TYPE)),-march=armv8-a)' package/libs/mbedtls/Makefile; then
        sed -i '/$(if $(findstring cortex-a53,$(CONFIG_CPU_TYPE)),-march=armv8-a)/a TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile
  else
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
  fi
fi

# Удаление onionshare-cli (нерешённые метаданные, отсутствует в конфиге)
rm -rf feeds/packages/net/onionshare-cli

[ -f feeds/luci/applications/luci-app-package-manager/root/usr/libexec/package-manager-call ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1004-luci-package-manager-apk-upload-untrusted-master.patch"

# vpnc: добавление -p в mkdir для идемпотентности
if grep -q 'mkdir $(PKG_BUILD_DIR)/bin' feeds/packages/net/vpnc/Makefile 2>/dev/null; then
    sed -i '/mkdir $(PKG_BUILD_DIR)\/bin/s/mkdir /mkdir -p /' feeds/packages/net/vpnc/Makefile
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
# подстановку shell-команд для значений Kconfig)
rm -rf package/mtk/drivers/wifi-profile
git clone --depth=1 -b mt798x-mt799x-6.6-mtwifi \
    https://github.com/padavanonly/immortalwrt-mt798x-6.6.git \
    /tmp/padavanonly-wifi-profile >/dev/null 2>&1
mv /tmp/padavanonly-wifi-profile/package/mtk/drivers/wifi-profile \
    package/mtk/drivers/wifi-profile
rm -rf /tmp/padavanonly-wifi-profile
# Удаление устаревшего wifi_jedi → /sbin/wifi установка (конфликтует с wifi-scripts ImmortalWrt 25.12)
sed -i 's|$(INSTALL_BIN) ./files/common/wifi_jedi $(1)/sbin/wifi|# DIY: removed – conflicts with wifi-scripts|' \
    package/mtk/drivers/wifi-profile/Makefile
echo "[DIY] wifi-profile заменён на mt7990-only версию padavanonly"

# MTK mt_wifi7: расширение имён карт Kconfig в make, а не в shell
if [ -f "package/mtk/drivers/mt_wifi7/Makefile" ] && \
   grep -q 'CONFIG_first_card_name' "package/mtk/drivers/mt_wifi7/Makefile"; then
    sed -i 's/$$(CONFIG_first_card_name)/$(CONFIG_first_card_name)/g; s/$$(CONFIG_second_card_name)/$(CONFIG_second_card_name)/g; s/$$(CONFIG_third_card_name)/$(CONFIG_third_card_name)/g' \
        "package/mtk/drivers/mt_wifi7/Makefile"
    echo "[DIY] mt_wifi7/Makefile: CONFIG_*_card_name исправлены для расширения make"
fi

# MTK mt_wifi7: сопоставление имён OpenWrt Kconfig с именами vendor Kbuild
_mt_wifi7_makefile="package/mtk/drivers/mt_wifi7/Makefile"
_mt_wifi7_kconfig_anchor='$(foreach c, $(PKG_KCONFIG),$(if $(CONFIG_MTK_WIFI7_$c),CONFIG_$(c)=$(CONFIG_MTK_WIFI7_$(c)))) \'
_mt_wifi7_kconfig_replacement='$(foreach c, $(PKG_KCONFIG),$(if $(CONFIG_MTK_WIFI7_$c),CONFIG_$(c)=$(CONFIG_MTK_WIFI7_$(c)))) \
		CONFIG_WIFI_DRIVER=$(CONFIG_MTK_WIFI7_DRIVER) \
		CONFIG_DOT11_HE_AX=$(CONFIG_MTK_WIFI7_DOT11_AX_SUPPORT) \
		CONFIG_DOT11_EHT_BE=$(CONFIG_MTK_WIFI7_DOT11_BE_SUPPORT) \'

if [ ! -f "$_mt_wifi7_makefile" ]; then
    echo "Требуемый mt_wifi7 Makefile не найден: $_mt_wifi7_makefile" >&2
    exit 1
elif grep -qE '^[[:space:]]*CONFIG_WIFI_DRIVER=\$\(CONFIG_MTK_WIFI7_DRIVER\)[[:space:]]*\\$' "$_mt_wifi7_makefile" && \
     grep -qE '^[[:space:]]*CONFIG_DOT11_HE_AX=\$\(CONFIG_MTK_WIFI7_DOT11_AX_SUPPORT\)[[:space:]]*\\$' "$_mt_wifi7_makefile" && \
     grep -qE '^[[:space:]]*CONFIG_DOT11_EHT_BE=\$\(CONFIG_MTK_WIFI7_DOT11_BE_SUPPORT\)[[:space:]]*\\$' "$_mt_wifi7_makefile"; then
    echo "[DIY] mt_wifi7/Makefile: маппинги vendor Kbuild уже присутствуют"
elif grep -qF "$_mt_wifi7_kconfig_anchor" "$_mt_wifi7_makefile"; then
    patch_makefile_dep \
        "$_mt_wifi7_makefile" \
        "$_mt_wifi7_kconfig_anchor" \
        "$_mt_wifi7_kconfig_replacement" || exit 1
    echo "[DIY] mt_wifi7/Makefile: маппинги vendor Kbuild инжектированы"
else
    echo "Не удалось найти якорь компиляции mt_wifi7 Kconfig в $_mt_wifi7_makefile" >&2
    exit 1
fi

# MTK mt_wifi7: Linux 6.12 перенёс универсальные unaligned-хелперы из asm/.
_mt_wifi7_unaligned_patch_src="$GITHUB_WORKSPACE/patches/filogic/25.12/1006-mt_wifi7-linux-6.12-unaligned-header.patch"
_mt_wifi7_unaligned_patch_dst="package/mtk/drivers/mt_wifi7/patches/900-linux-6.12-unaligned-header.patch"

if [ ! -f "$_mt_wifi7_unaligned_patch_src" ]; then
    echo "Требуемый совместимостный патч mt_wifi7 не найден: $_mt_wifi7_unaligned_patch_src" >&2
    exit 1
fi

install -Dm0644 "$_mt_wifi7_unaligned_patch_src" "$_mt_wifi7_unaligned_patch_dst"
echo "[DIY] mt_wifi7: совместимостный патч unaligned header для Linux 6.12 установлен"

# MTK mt_wifi7: GCC 14 отвергает отсутствующие объявления AC_NUM и PMKSA под
# политикой -Werror драйвера. Эта правка отделена от исправления unaligned, чтобы
# каждый совместимостный патч можно было.review или удалить независимо.
_mt_wifi7_declarations_patch_src="$GITHUB_WORKSPACE/patches/filogic/25.12/1007-mt_wifi7-fix-missing-declarations.patch"
_mt_wifi7_declarations_patch_dst="package/mtk/drivers/mt_wifi7/patches/901-fix-missing-declarations.patch"

if [ ! -f "$_mt_wifi7_declarations_patch_src" ]; then
    echo "Требуемый совместимостный патч mt_wifi7 не найден: $_mt_wifi7_declarations_patch_src" >&2
    exit 1
fi

install -Dm0644 "$_mt_wifi7_declarations_patch_src" "$_mt_wifi7_declarations_patch_dst"
echo "[DIY] mt_wifi7: совместимостный патч отсутствующих объявлений GCC 14 установлен"

# MTK mt_wifi7: rt_channel.c ссылается на MAX_TRANSMIT_POWER, который
# в vendor-исходниках определён только локально в bcn.c. GCC 14 -Werror отвергает
# необъявленный идентификатор; добавляем ту же константу в rt_channel.c.
_mt_wifi7_max_tx_power_patch_src="$GITHUB_WORKSPACE/patches/filogic/25.12/1008-mt_wifi7-fix-max-transmit-power.patch"
_mt_wifi7_max_tx_power_patch_dst="package/mtk/drivers/mt_wifi7/patches/902-fix-max-transmit-power.patch"

if [ ! -f "$_mt_wifi7_max_tx_power_patch_src" ]; then
    echo "Требуемый совместимостный патч mt_wifi7 не найден: $_mt_wifi7_max_tx_power_patch_src" >&2
    exit 1
fi

install -Dm0644 "$_mt_wifi7_max_tx_power_patch_src" "$_mt_wifi7_max_tx_power_patch_dst"
echo "[DIY] mt_wifi7: совместимостный патч объявления MAX_TRANSMIT_POWER установлен"

# MTK mt_wifi7: при CONFIG_MTK_WIFI7_CFG80211_SUPPORT=y vendor-сборка
# определяет RT_CFG80211_SUPPORT, из-за чего owe_cmm.h пропускает свой include
# sae_cmm.h ("#ifndef RT_CFG80211_SUPPORT"). sec_cmm.h по-прежнему компилирует
# поля struct pwd_id_list / struct sae_capability под DOT11_SAE_SUPPORT,
# но подтягивает sae_cmm.h только под SUPP_SAE_SUPPORT, поэтому при выключенном
# APCLI_SUPPLICANT_SUPPORT каждый TU падает с ошибкой "field ...
# has incomplete type". Выравниваем include-guard с field-guard.
_mt_wifi7_sae_patch_src="$GITHUB_WORKSPACE/patches/filogic/25.12/1009-mt_wifi7-fix-incomplete-sae-structs.patch"
_mt_wifi7_sae_patch_dst="package/mtk/drivers/mt_wifi7/patches/903-fix-incomplete-sae-structs.patch"

if [ ! -f "$_mt_wifi7_sae_patch_src" ]; then
    echo "Требуемый совместимостный патч mt_wifi7 не найден: $_mt_wifi7_sae_patch_src" >&2
    exit 1
fi

install -Dm0644 "$_mt_wifi7_sae_patch_src" "$_mt_wifi7_sae_patch_dst"
echo "[DIY] mt_wifi7: совместимостный патч неполных SAE-структур установлен"

# MTK mt_wifi7: поле cac_required struct wifi_dev защищено
# CONFIG_MAP_SUPPORT, но rt_channel.c (MTK_CFG80211_CHAN_SET_FLAG_CAC_REQUIRED
# vendor cmd) и cmm_rdm_mt.c DfsZwBypassCac (MT_DFS_SUPPORT) используют поле
# безусловно, поэтому при выключенном MAP каждый TU падает с ошибкой "no member named
# 'cac_required'". Переносим поле за пределы MAP-guard.
_mt_wifi7_cac_patch_src="$GITHUB_WORKSPACE/patches/filogic/25.12/1010-mt_wifi7-fix-cac-required-field.patch"
_mt_wifi7_cac_patch_dst="package/mtk/drivers/mt_wifi7/patches/904-fix-cac-required-field.patch"

if [ ! -f "$_mt_wifi7_cac_patch_src" ]; then
    echo "Требуемый совместимостный патч mt_wifi7 не найден: $_mt_wifi7_cac_patch_src" >&2
    exit 1
fi

install -Dm0644 "$_mt_wifi7_cac_patch_src" "$_mt_wifi7_cac_patch_dst"
echo "[DIY] mt_wifi7: совместимостный патч поля cac_required установлен"

# datconf: отключение параллельной сборки (5 подпакетов делят одно дерево CMake, гонка при -j>1)
if [ -f "package/mtk/applications/datconf/Makefile" ] && \
   ! grep -q 'PKG_BUILD_PARALLEL' "package/mtk/applications/datconf/Makefile"; then
    sed -i '/^PKG_RELEASE:=/a PKG_BUILD_PARALLEL:=0' "package/mtk/applications/datconf/Makefile"
    echo "[DIY] datconf: параллельная сборка отключена"
fi

# Зависимости фидов для сообщественных клонов (pcre2 в основном дереве с 25.12)
./scripts/feeds update -a

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

patch_makefile_dep \
    feeds/packages/lang/python/python-ubus/Makefile \
    'PKG_BUILD_DEPENDS:=python-setuptools/host' \
    'PKG_BUILD_DEPENDS:=python3/host'
patch_makefile_dep \
    package/feeds/packages/python-ubus/Makefile \
    'PKG_BUILD_DEPENDS:=python-setuptools/host' \
    'PKG_BUILD_DEPENDS:=python3/host'

patch_makefile_dep \
    feeds/packages/admin/zabbix/Makefile \
    'libnetsnmp-ssl' \
    'libnetsnmp'
patch_makefile_dep \
    package/feeds/packages/zabbix/Makefile \
    'libnetsnmp-ssl' \
    'libnetsnmp'

# Уменьшение задержки загрузки U-Boot BPI-R4
patch_makefile_dep \
    package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch \
    'CONFIG_BOOTDELAY=30' \
    'CONFIG_BOOTDELAY=10'

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
    echo "[DIY] Символы ядра Kconfig зафиксированы"
fi
