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
    'CONFIG_PACKAGE_luci-app-p910nd=y' \
    'CONFIG_PACKAGE_luci-app-sms-tool-js=y' \
    'CONFIG_PACKAGE_luci-app-uhttpd=y'; do
    grep -qxF "$required" .config || {
        echo "The resolved 25.12 config lost an expected package: $required" >&2
        exit 1
    }
done

# Меняем IP-адрес по умолчанию на 192.168.2.1
sed -i 's/192.168.1.1/192.168.2.1/g' package/base-files/files/bin/config_generate

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
