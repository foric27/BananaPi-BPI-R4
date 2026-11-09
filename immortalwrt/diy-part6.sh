#!/bin/bash
# diy-part6.sh — проверка профиля BPI-R4 и патч mt76 для ImmortalWrt 25.12

set -e

# Проверяем, что после `make defconfig` выбран только BPI-R4 и сохранены
# обязательные настройки Wi-Fi: драйвер mt7996e и прошивка mt7990.
configure_bpi_r4() {
    local selected_device required
    [ -r .config ] || { echo 'Missing 25.12 .config' >&2; return 1; }
    make defconfig

    selected_device="$(sed -n '/^CONFIG_TARGET_.*_DEVICE_.*=y$/p' .config)"
    if [ "$selected_device" != 'CONFIG_TARGET_mediatek_filogic_DEVICE_bananapi_bpi-r4=y' ]; then
        echo "25.12 must select only BPI-R4; resolved devices: $selected_device" >&2
        exit 1
    fi
    for required in \
        'CONFIG_TARGET_mediatek_filogic=y' \
        'CONFIG_TARGET_PROFILE="DEVICE_bananapi_bpi-r4"' \
        'CONFIG_PACKAGE_kmod-mt7996e=y' \
        'CONFIG_PACKAGE_kmod-mt7990-firmware=y'; do
        grep -qxF "$required" .config || {
            echo "25.12 profile lost a required setting: $required" >&2
            exit 1
        }
    done
}

configure_bpi_r4

# Проверяем, что все добавленные пакеты реально есть в итоговой конфигурации
# (иначе make defconfig мог молча выбросить неизвестный символ).
for required in \
    'CONFIG_LUCI_LANG_ru=y' \
    'CONFIG_PACKAGE_luci-i18n-base-ru=y' \
    'CONFIG_PACKAGE_kmod-nls-cp866=y' \
    'CONFIG_PACKAGE_kmod-nls-cp1251=y' \
    'CONFIG_PACKAGE_kmod-nls-koi8r=y' \
    'CONFIG_PACKAGE_lldpd=y' \
    'CONFIG_PACKAGE_luci-app-lldpd=y' \
    'CONFIG_PACKAGE_snmpd-nossl=y' \
    'CONFIG_PACKAGE_luci-app-snmpd=y' \
    'CONFIG_PACKAGE_acme-acmesh=y' \
    'CONFIG_PACKAGE_luci-app-acme=y' \
    'CONFIG_PACKAGE_frps=y' \
    'CONFIG_PACKAGE_luci-app-frps=y' \
    'CONFIG_PACKAGE_luci-app-sms-tool-js=y' \
    'CONFIG_PACKAGE_lighttpd=y' \
    'CONFIG_PACKAGE_luci-app-uhttpd=y'; do
    grep -qxF "$required" .config || {
        echo "The resolved 25.12 config lost an expected package: $required" >&2
        exit 1
    }
done

# Отключённые по запросу пакеты не должны вернуться (в т.ч. как зависимости).
for forbidden in \
    'CONFIG_PACKAGE_aria2=y' \
    'CONFIG_PACKAGE_ariang=y' \
    'CONFIG_PACKAGE_luci-app-aria2=y' \
    'CONFIG_PACKAGE_ddns-scripts-services=y' \
    'CONFIG_PACKAGE_luci-app-ddns=y' \
    'CONFIG_PACKAGE_netdata=y' \
    'CONFIG_PACKAGE_luci-app-netdata=y' \
    'CONFIG_PACKAGE_p910nd=y' \
    'CONFIG_PACKAGE_luci-app-p910nd=y' \
    'CONFIG_PACKAGE_luci-app-usb-printer=y' \
    'CONFIG_PACKAGE_shairport-sync-openssl=y' \
    'CONFIG_PACKAGE_luci-app-airplay2=y' \
    'CONFIG_PACKAGE_vlmcsd=y' \
    'CONFIG_PACKAGE_luci-app-vlmcsd=y' \
    'CONFIG_PACKAGE_luci-app-wol=y' \
    'CONFIG_PACKAGE_luci-app-wechatpush=y' \
    'CONFIG_PACKAGE_luci-app-ramfree=y' \
    'CONFIG_PACKAGE_fibocom-dial=y'; do
    if grep -qxF "$forbidden" .config; then
        echo "A disabled package is still selected: $forbidden" >&2
        exit 1
    fi
done

# Веб-серверы: Lighttpd — на 80-м порту (по умолчанию), uhttpd/LuCI — на 8888.
# IP-адрес прошивки остаётся стандартным (192.168.1.1), config_generate не правим.
_uhttpd_config="package/network/services/uhttpd/files/uhttpd.config"
if [ -f "$_uhttpd_config" ]; then
    sed -i 's/0\.0\.0\.0:80/0.0.0.0:8888/g; s/\[::\]:80/[::]:8888/g' "$_uhttpd_config"
    grep -q '0.0.0.0:8888' "$_uhttpd_config" || {
        echo 'Failed to move uhttpd to port 8888' >&2
        exit 1
    }
    echo "[DIY] uhttpd: HTTP-порт по умолчанию 8888 (LuCI: http://192.168.1.1:8888)"
fi

# Стандартный LAN-адрес: в старых локальных деревьях мог остаться sed на
# 192.168.2.1 из предыдущих версий скрипта — возвращаем дефолт 192.168.1.1.
_config_generate="package/base-files/files/bin/config_generate"
if [ -f "$_config_generate" ]; then
    if grep -q '192\.168\.2\.1' "$_config_generate"; then
        sed -i 's/192\.168\.2\.1/192.168.1.1/g' "$_config_generate"
        echo "[DIY] config_generate: восстановлен стандартный IP 192.168.1.1"
    fi
    grep -q '192\.168\.1\.1' "$_config_generate" || {
        echo 'config_generate does not use the default 192.168.1.1 address' >&2
        exit 1
    }
fi

_lighttpd_conf="feeds/packages/net/lighttpd/files/lighttpd.conf"
if [ -f "$_lighttpd_conf" ]; then
    if ! grep -qE '^[[:space:]]*server\.port[[:space:]]*=' "$_lighttpd_conf"; then
        printf '\n# HTTP-порт по умолчанию для Lighttpd\nserver.port = 80\n' >> "$_lighttpd_conf"
    fi
    grep -qE '^[[:space:]]*server\.port[[:space:]]*=[[:space:]]*80' "$_lighttpd_conf" || {
        echo 'Lighttpd is not configured for port 80' >&2
        exit 1
    }
    echo "[DIY] lighttpd: HTTP-порт по умолчанию 80"
fi

# Применяет патч к package/kernel/mt76, если он ещё не применён.
validate_and_apply_mt76_patch() {
    local patch_file="$1"

    [ -f "$patch_file" ] || {
        echo "Missing patch file: $patch_file" >&2
        return 2
    }

    # Нормализуем переводы строк в файле патча перед применением
    perl -0pi -e 's/\r\n/\n/g; s/\r/\n/g' "$patch_file"

    if (cd package/kernel/mt76 && patch -p1 -R --dry-run < "$patch_file" >/dev/null 2>&1); then
        echo "Patch already applied: $patch_file"
        return 0
    fi

    if ! (cd package/kernel/mt76 && patch -p1 --dry-run < "$patch_file" >/dev/null); then
        echo "Patch does not apply cleanly to the current mt76 Makefile: $patch_file" >&2
        exit 1
    fi

    (cd package/kernel/mt76 && patch -p1 < "$patch_file")
}

# В 25.12 прошивка mt7990-firmware уже есть в исходниках, поэтому достаточно
# патча, включающего wed_enable=1.
MT76_PATCH="1007-mt76-makefile-wed-enable.patch"

validate_and_apply_mt76_patch \
  "$GITHUB_WORKSPACE/patches/filogic/mt76/$MT76_PATCH"
