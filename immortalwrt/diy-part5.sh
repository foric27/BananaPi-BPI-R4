#!/bin/bash
# diy-part5.sh — подготовка фидов и community-пакетов для ImmortalWrt 25.12 (BPI-R4)
#
# Скрипт выполняется внутри дерева OpenWrt после `feeds update`.
# Наши репозитории задаются в workflow (immortalwrt-25.12-bpi-r4.yml):
#   LUCI_APP_REPO_URL / LUCI_APP_REPO_BRANCH — форк LuCI-приложений foric27/luci-app.

# Репозитории сторонних пакетов и их ветки. Ветки указаны явно, чтобы сборка
# не зависела от default-ветки апстрима; для обновления правится строка ниже.
REPO_HELLOWORLD="https://github.com/fw876/helloworld";                                  BRANCH_HELLOWORLD="dev"
REPO_PASSWALL_PACKAGES="https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git"; BRANCH_PASSWALL_PACKAGES="main"
REPO_PASSWALL="https://github.com/Openwrt-Passwall/openwrt-passwall.git";               BRANCH_PASSWALL="main"
REPO_NIKKI="https://github.com/nikkinikki-org/OpenWrt-nikki";                           BRANCH_NIKKI="main"
REPO_SOCAT="https://github.com/1522042029/luci-app-socat";                              BRANCH_SOCAT="main"
REPO_ARGON="https://github.com/jerrykuku/luci-theme-argon";                             BRANCH_ARGON="master"
REPO_JELL="https://github.com/kenzok8/jell";                                            BRANCH_JELL="main"
REPO_DDNSTO="https://github.com/linkease/ddnsto-openwrt-package";                       BRANCH_DDNSTO="main"
REPO_MOSDNS="https://github.com/sbwml/luci-app-mosdns";                                 BRANCH_MOSDNS="v5"
REPO_OPENCLASH="https://github.com/vernesong/OpenClash";                                BRANCH_OPENCLASH="master"

# Наш форк LuCI-приложений: URL и ветка приходят из workflow.
LUCI_APP_REPO_URL="${LUCI_APP_REPO_URL:-https://github.com/foric27/luci-app}"
LUCI_APP_REPO_BRANCH="${LUCI_APP_REPO_BRANCH:-main}"

# Применяет литеральную замену в Makefile, если файл и старый текст существуют.
patch_makefile_dep() {
    local file_path="$1"
    local old_text="$2"
    local new_text="$3"
    local perl_status

    [ -f "$file_path" ] || return 0
    grep -qF "$old_text" "$file_path" || return 0

    PATCH_OLD_TEXT="$old_text" PATCH_NEW_TEXT="$new_text" \
        perl -0pi -e 'BEGIN { $old = $ENV{"PATCH_OLD_TEXT"}; $new = $ENV{"PATCH_NEW_TEXT"}; }
            $count = s/\Q$old\E/$new/g;
            END { exit($count > 0 ? 0 : 2); }' "$file_path"
    perl_status=$?

    [ "$perl_status" -eq 0 ] || {
        echo "Failed to apply literal patch to $file_path" >&2
        return "$perl_status"
    }
}

# Применяет патч из репозитория сборки, если он ещё не применён.
apply_workspace_patch() {
    local patch_file="$1"

    [ -f "$patch_file" ] || return 0

    if git apply --recount --ignore-space-change --ignore-whitespace --reverse --check "$patch_file" >/dev/null 2>&1; then
        return 0
    fi

    git apply --recount --ignore-space-change --ignore-whitespace "$patch_file"
}

# В 25.12 autocore использует files/tempinfo вместо раскладки files/arm из 24.10.
# Сохраняем строку температуры на обзоре и её значение CPU.
_autocore_makefile="package/emortal/autocore/Makefile"
if [ -f "$_autocore_makefile" ] && [ -f package/emortal/autocore/files/tempinfo ]; then
    install -m 0755 "$GITHUB_WORKSPACE/scripts/tempinfo" \
        package/emortal/autocore/files/tempinfo || exit 1
    _temp_deps=""
    for _temp_dep in wireless-tools coreutils-timeout; do
        if ! grep -qF "+TARGET_mediatek:$_temp_dep" "$_autocore_makefile"; then
            _temp_deps="${_temp_deps:+$_temp_deps }+TARGET_mediatek:$_temp_dep"
        fi
    done
    if [ -n "$_temp_deps" ]; then
        # Добавляем зависимости в блок DEPENDS этого пакета, не затрагивая
        # строки других платформ и vendor-пакет mhz.
        if ! awk -v deps="$_temp_deps" '
            /^define Package\/autocore$/ { in_package = 1 }
            in_package && /^endef$/ {
                print "  DEPENDS+=" deps
                in_package = 0
                inserted++
            }
            { print }
            END { if (inserted != 1) exit 1 }
        ' "$_autocore_makefile" > "$_autocore_makefile.tempinfo"; then
            rm -f "$_autocore_makefile.tempinfo"
            echo 'Cannot locate the autocore package dependency block' >&2
            exit 1
        fi
        mv -f "$_autocore_makefile.tempinfo" "$_autocore_makefile" || exit 1
    fi
    for _temp_dep in wireless-tools coreutils-timeout; do
        grep -qF "+TARGET_mediatek:$_temp_dep" "$_autocore_makefile" || {
            echo "Failed to add autocore temperature dependency: $_temp_dep" >&2
            exit 1
        }
    done
fi

# Удаляем пакеты фидов, которые заменяются клонами из community-репозиториев.
rm -rf feeds/luci/themes/luci-theme-argon
rm -rf feeds/luci/applications/luci-app-argon-config
rm -rf feeds/luci/applications/luci-app-passwall
rm -rf feeds/luci/applications/luci-app-modemband
rm -rf feeds/packages/net/{xray-core,v2ray-geodata,sing-box,chinadns-ng,dns2socks,hysteria,ipt2socks,microsocks,naiveproxy,shadowsocks-libev,shadowsocks-rust,shadowsocksr-libev,simple-obfs,tcping,trojan-plus,tuic-client,v2ray-plugin,xray-plugin,geoview,shadow-tls}

# Клонируем community-пакеты (ветки зафиксированы в переменных выше).
mkdir -p package/community
pushd package/community
git clone --depth=1 -b "$BRANCH_HELLOWORLD" "$REPO_HELLOWORLD"
git clone --depth=1 -b "$BRANCH_PASSWALL_PACKAGES" "$REPO_PASSWALL_PACKAGES"
git clone --depth=1 -b "$BRANCH_PASSWALL" "$REPO_PASSWALL"
git clone --depth=1 -b "$BRANCH_NIKKI" "$REPO_NIKKI"
git clone --depth=1 -b "$BRANCH_SOCAT" "$REPO_SOCAT"
git clone --depth=1 -b "$BRANCH_ARGON" "$REPO_ARGON"

# Наши LuCI-приложения: один клон foric27/luci-app забирает сразу все пакеты.
mkdir -p package/openwrt-packages
_luci_repo="luci-app"
git clone --depth=1 --single-branch -b "$LUCI_APP_REPO_BRANCH" "$LUCI_APP_REPO_URL" "$_luci_repo"
for _app in luci-app-fan luci-app-sfp-status luci-app-modemband luci-app-traffic rpcd-mod-router-status; do
    mv "$_luci_repo/Luci-app/$_app" package/openwrt-packages/
done
rm -rf "$_luci_repo"
for _app in luci-app-fan luci-app-sfp-status luci-app-modemband luci-app-traffic rpcd-mod-router-status; do
    [ -f "package/openwrt-packages/$_app/Makefile" ] || {
        echo "Package $_app was not fetched from $LUCI_APP_REPO_URL" >&2
        exit 1
    }
done
if [ ! -f package/openwrt-packages/rpcd-mod-router-status/root/etc/init.d/router-status ]; then
    echo "Independent router status package was not fetched" >&2
    exit 1
fi

# wrtbwmon из репозитория jell
git clone --depth=1 -b "$BRANCH_JELL" "$REPO_JELL"
mv jell/wrtbwmon package/openwrt-packages/
rm -rf jell

# ddnsto и его LuCI-приложение: один клон на два пакета
git clone --depth=1 -b "$BRANCH_DDNSTO" "$REPO_DDNSTO"
mv ddnsto-openwrt-package/ddnsto ddnsto-openwrt-package/luci-app-ddnsto package/openwrt-packages/
rm -rf ddnsto-openwrt-package
popd

sh "$GITHUB_WORKSPACE/scripts/fix-mihomo-source.sh" || exit 1

# Сохраняем версионированные Go-компиляторы фида, bootstrap и совместимые
# вспомогательные пакеты: замена дерева старой одноверсионной раскладкой
# удаляет golang1.27/host, нужный cloudflared, tailscale и telegraf.
_go_values="feeds/packages/lang/golang/golang-values.mk"
_go_feed_default="$(sed -n 's/^GO_DEFAULT_VERSION:=[[:space:]]*//p' "$_go_values" 2>/dev/null)"
_go_default="$_go_feed_default"
case "$_go_default" in
    1.[0-9]|1.1[0-9]|1.2[0-6]) _go_default=1.27 ;;
esac
case "$_go_default" in
    ''|*[!0-9.]*)
        echo 'The 25.12 packages feed must provide its native versioned Go helpers' >&2
        exit 1
        ;;
esac
if ! grep -qxF "PKG_NAME:=golang$_go_default" "feeds/packages/lang/golang/golang$_go_default/Makefile"; then
    echo "Missing native Go $_go_default toolchain in the packages feed" >&2
    exit 1
fi
# Для community-пакетов нужен Go не ниже 1.27; более новый default фида сохраняем.
if [ "$_go_default" != "$_go_feed_default" ]; then
    sed -i "s/^GO_DEFAULT_VERSION:=.*/GO_DEFAULT_VERSION:=$_go_default/" "$_go_values" || exit 1
fi
rm -rf feeds/packages/net/mosdns
git clone --depth=1 -b "$BRANCH_MOSDNS" "$REPO_MOSDNS" package/mosdns

mkdir -p package/OpenClash
pushd package/OpenClash
git clone --depth=1 -b "$BRANCH_OPENCLASH" "$REPO_OPENCLASH"
popd

# helloworld simple-obfs/shadowsocks-libev: отключаем недетерминированный PKG_MIRROR_HASH
for f in \
    package/community/helloworld/simple-obfs/Makefile \
    package/community/helloworld/shadowsocks-libev/Makefile; do
    [ -f "$f" ] && sed -i '/^PKG_MIRROR_HASH:=/s/:=.*/:=skip/' "$f"
done

# Vendored cpuid v2.0.4 в containerd не проходит проверку linkname в Go >= 1.23.
# MAKE_FLAGS фиксируется в BuildPackage, поэтому строку нужно вставить перед ним.
f=feeds/packages/utils/containerd/Makefile
if [ ! -f "$f" ]; then
    echo "[DIY] containerd Makefile missing: $f" >&2
elif ! grep -q 'checklinkname=0' "$f"; then
    awk -v ins="MAKE_FLAGS += EXTRA_LDFLAGS='-s -w -checklinkname=0'" '{print} /^Build\/Compile=/ {print ins}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    echo "[DIY] containerd: -checklinkname=0 injected=$(grep -c 'checklinkname=0' "$f")"
fi

# Обход проблемы GCC 14 + musl fortify для mbedtls
if ! grep -q '_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile; then
    if grep -q '\$(if \$(findstring cortex-a53,\$(CONFIG_CPU_TYPE)),-march=armv8-a)' package/libs/mbedtls/Makefile; then
        sed -i '/$(if $(findstring cortex-a53,$(CONFIG_CPU_TYPE)),-march=armv8-a)/a TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' package/libs/mbedtls/Makefile
  else
    echo 'TARGET_CFLAGS += -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0' >> package/libs/mbedtls/Makefile
  fi
fi

# Удаляем onionshare-cli (неразрешённые метаданные, пакета нет в нашей конфигурации)
rm -rf feeds/packages/net/onionshare-cli

# Патч LuCI package-manager: разрешаем загрузку локальных APK-пакетов
[ -f feeds/luci/applications/luci-app-package-manager/root/usr/libexec/package-manager-call ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1004-luci-package-manager-apk-upload-untrusted-master.patch"

# vpnc: добавляем -p к mkdir для идемпотентности
if grep -q 'mkdir $(PKG_BUILD_DIR)/bin' feeds/packages/net/vpnc/Makefile 2>/dev/null; then
    sed -i '/mkdir $(PKG_BUILD_DIR)\/bin/s/mkdir /mkdir -p /' feeds/packages/net/vpnc/Makefile
fi

./scripts/feeds install -a

# Зависимости фидов, нужные клонам community-пакетов (pcre2 в 25.12 уже в основном дереве)
./scripts/feeds install c-ares udns

# Удаляем APK-репозиторий kiddin9 (ломанный video/-подрепозиторий)
for f in \
    package/base-files/files/etc/apk/repositories \
    package/base-files/files/etc/apk/repositories.d/* \
    package/utils/alpine-repositories/files/repositories; do
    [ -f "$f" ] && grep -q 'kiddin9' "$f" 2>/dev/null && sed -i '/kiddin9/d' "$f" 2>/dev/null || true
done

# Правки APK на этапе выполнения: локальные неподписанные пакеты и битые записи фидов
rm -f package/base-files/files/etc/uci-defaults/99-apk-untrusted
[ -d package/base-files/files/etc/uci-defaults ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1005-base-files-apk-manager-fixes-master.patch"

# Проверяем наличие libmbedtls (нужен shadowsocks-libev)
if [ ! -f package/libs/mbedtls/Makefile ]; then
  echo "WARNING: package/libs/mbedtls/Makefile not found" >&2
elif ! grep -q 'define Package/libmbedtls' package/libs/mbedtls/Makefile; then
  echo "WARNING: package/libs/mbedtls/Makefile does not define libmbedtls" >&2
fi

# GO proxy для sing-box
export GOEXPERIMENT=
export GOPROXY=https://proxy.golang.org,direct

# Совместимость с плавающими метаданными фидов.
# rust: rust-lang удалил CI-артефакты LLVM 1.94.0, поэтому download-ci-llvm=true
# отдаёт 404; собираем LLVM из исходников (configure.py: последний --set побеждает).
_rust_makefile="feeds/packages/lang/rust/Makefile"
if [ -f "$_rust_makefile" ]; then
    if grep -qF -- '--set=llvm.download-ci-llvm=false' "$_rust_makefile"; then
        echo "[DIY] rust: llvm.download-ci-llvm already false"
    elif grep -qF -- '--set=llvm.download-ci-llvm=true' "$_rust_makefile"; then
        sed -i 's/--set=llvm\.download-ci-llvm=true/--set=llvm.download-ci-llvm=false/' "$_rust_makefile"
        grep -qF -- '--set=llvm.download-ci-llvm=false' "$_rust_makefile" || {
            echo 'Failed to disable Rust CI LLVM download' >&2
            exit 1
        }
        echo "[DIY] rust: llvm.download-ci-llvm=false (build LLVM from source)"
    else
        echo 'WARNING: rust Makefile has no llvm.download-ci-llvm flag' >&2
    fi
fi

# luci-ssl-openssl: откатываемся на px5g-standalone, если px5g-openssl отсутствует
_ssl_makefile="feeds/luci/collections/luci-ssl-openssl/Makefile"
if [ -f "$_ssl_makefile" ] && \
    grep -qF -- '+px5g-openssl' "$_ssl_makefile" && \
    [ ! -d package/utils/px5g-openssl ]; then
    sed -i 's/+px5g-openssl/+px5g-standalone/' "$_ssl_makefile"
    grep -qF -- '+px5g-standalone' "$_ssl_makefile" || {
        echo 'Failed to switch luci-ssl-openssl to px5g-standalone' >&2
        exit 1
    }
    echo "[DIY] luci-ssl-openssl: dep px5g-openssl -> px5g-standalone"
fi

# Ядро 6.12.103: в слиянии от 2026-08-24 появились патчи fmsh SPI-NAND (436/437),
# которые не применяются; BPI-R4 эти чипы не использует — удаляем.
rm -f target/linux/generic/backport-6.12/436-v7.3-mtd-spinand-fmsh-*.patch \
      target/linux/generic/backport-6.12/437-v7.3-mtd-spinand-fmsh-*.patch
echo "[DIY] removed fmsh backport patches 436/437 (broken against kernel 6.12.103)"

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

# Уменьшаем bootdelay U-Boot для BPI-R4
patch_makefile_dep \
    package/boot/uboot-mediatek/patches/450-add-bpi-r4.patch \
    'CONFIG_BOOTDELAY=30' \
    'CONFIG_BOOTDELAY=10'

# LuCI-патчи для 25.12 (перегенерированы 2026-07-03); проверяются через || true,
# чтобы изменённая база фида не обрывала сборку молча.

# RPCD: метод ubus getWifiStationHints и вспомогательные функции
[ -f feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1000-luci-rpcd-getWifiStationHints-master.patch" || true

# 60_wifi.js: подсказки для wifi7/MLO и поддержка mhz_hi (объединены 1000+1002)
[ -f feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/60_wifi.js ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1000-luci-status-60wifi-master.patch" || true

# wireless.js: подсказки станций + матрица режимов MTK + MLO OFDMA (объединены 1001+999+1003)
[ -f feeds/luci/modules/luci-mod-network/htdocs/luci-static/resources/view/network/wireless.js ] && \
    apply_workspace_patch "$GITHUB_WORKSPACE/patches/filogic/25.12/1001-luci-wireless-combined-master.patch" || true
