# BananaPi BPI-R4 — OpenWrt + MediaTek SDK

Сборка OpenWrt для BananaPi BPI-R4 (SoC MediaTek MT7988, платформа Filogic)
на **последних стабильных ветках** с патчами официального MediaTek SDK.

* **База:** [`openwrt/openwrt`](https://github.com/openwrt/openwrt), ветка `openwrt-25.12` (HEAD)
* **SDK:** [`mediatek/mtk-openwrt-feeds`](https://github.com/mediatek/mtk-openwrt-feeds), ветка `main` (HEAD)
* **Пин ревизии:** `OPENWRT_REF` / `MTK_FEED_REF` (ветка, тег или 40-hex SHA);
  точные коммиты попадают в `output/source-versions.txt`
* **Ядро:** Linux 6.12 (6.12.108 на момент последней сборки)
* **WiFi:** стек MTK SoftMAC из `mtk-openwrt-feeds@main` — `mt76` (124 патча MTK) +
  `mac80211` (backports 6.18.7) + `hostapd` (снапшот 2026.02.19, 273 патча) +
  `wifi-scripts`/`iw`/`ucode`. Берётся из `autobuild/unified/filogic/mac80211/25.12`;
  применение проверяется гейтом в `customize.sh` (иначе сборка падает)
* **Поддержка:** BPI-R4 / BPI-R4 (NIC BE14), MTK-HNAT, 8GB RAM, MTK U-Boot/ATF

---

## Быстрый старт

```bash
# Полная сборка (клон баз + применение всех патчей + образы)
./build.sh --no-menuconfig

# Опции
./build.sh --help
#   --no-menuconfig     не запускать интерактивный menuconfig
#   --jobs N            число потоков компиляции (по умолчанию nproc)
#   --refresh-go-cache  очистить кеш Go-модулей перед сборкой

# Пин ревизий (ветка/тег/полный 40-hex SHA); без них сборка следует за ветками
OPENWRT_REF=55457403542a747a9427ca4c047d9a63c0dccc84 \
MTK_FEED_REF=794f99d5bc56ee11154b710753c38ea5c83ff088 \
  ./build.sh --no-menuconfig
```

Результат — в `output/` (см. раздел «Артефакты»).

---

## Структура репозитория

| Путь | Назначение |
|---|---|
| `build.sh` | Локальная сборка (полная реплика CI-workflow) |
| `scripts/customize.sh` | Кастомизация дерева: MTK-фид, патчи, адаптации, пакеты, фиксы |
| `config/defconfig` | Конфигурация сборки (`.config`) |
| `packages/` | Локальные пакеты (русифицированы) |
| `patches/25.12/` | Патчи и адаптации |
| `src/` | Внешние деревья `openwrt/` и `mtk-openwrt-feeds/` (клон `build.sh`, gitignore) |
| `output/` | Готовые образы и пакеты |
| `.github/workflows/bpi-r4-openwrt-build.yml` | CI: проверки на push/PR, сборка по расписанию и вручную |
| `LICENSE` | GNU General Public License v2.0 |

---

## Как собирается прошивка

`build.sh` / CI выполняют:

1. Клонируют/обновляют `openwrt/openwrt@openwrt-25.12` и `mediatek/mtk-openwrt-feeds@main`
2. Сбрасывают фиды до чистого состояния
3. Запускают `scripts/customize.sh`:
   - подключают MTK-фид, `feeds update/install`
   - копируют `25.12/files/*` и host-тулы фида (`fdt-patch-dm-verify`, `crc32sum`, `ar-tool`)
   - применяют патчи MTK: **88** (`patches-base`) + **6** (`patches-feeds`)
   - применяют вариант mac80211: **124** патча `mt76`, **142** патча `mac80211`, **273** патча `hostapd`, файлы `wifi-scripts`/`iw`/`ucode`
   - применяют наши адаптации и фиксы (см. ниже)
   - копируют локальные и сторонние LuCI-приложения
   - проходят гейты: WiFi-стек, 8GB U-Boot/ATF, MAC, объявления kernel-символов
4. Загружают исходники, собирают с гейтами обязательных пакетов/артефактов

---

## Проверки и тесты

Быстрые проверки не требуют сборки и запускаются в CI отдельным job'ом
`checks` (push/PR, а также перед каждой сборкой по расписанию):

```bash
bash -n build.sh scripts/customize.sh
find packages -type f \( -name '*.sh' -o -path '*/root/etc/init.d/*' \
  -o -path '*/root/etc/uci-defaults/*' -o -path '*/root/usr/libexec/*' \) \
  ! -name '*.lua' ! -name '*.js' ! -name 'luci.turboacc' -exec bash -n {} \;

cd packages/luci-app-traffic
for t in collector rpcd live peak rollhour fetch-icons; do
  bash "tools/${t}-selftest.sh"
done
for t in catalog-selftest check-icons icon-expansion-selftest icon-resolution-selftest \
         page-render-selftest guard-mutation-test; do
  node "tools/${t}.js"
done
```

Наборы `luci-app-traffic` — offline: conntrack, querylog и nft подменяются
фикстурами, сеть и роутер не нужны. `collector-selftest.sh` герметичен:
пути `/proc/net/dev`, `/proc/net/route`, `/proc/net/route6` и бинарь nft
подставляются через переменные окружения.

---

## Адаптации патчей MTK под актуальную базу

База и фид живут в разных релизных циклах, поэтому часть патчей MTK
адаптируется к дереву патчами из `patches/25.12/`:

| Патч | Что решает |
|---|---|
| `0981-backports-sockaddr-unsized-revert.patch` | Колбэки сокетов в backports варианта рассчитаны на новое ядро (`struct sockaddr_unsized`), а в 6.12 — `struct sockaddr`. Возвращаем совместимый тип (qrtr/ath qmi) |
| `0982-backports-drop-qrtr-mhi.patch` | backports 6.18.7 тянут собственные QRTR/MHI и конфликтуют с ядерными модулями (`redefinition`). Выкидываем их — используются ядерные `kmod-qrtr`/`kmod-mhi` (как в апстриме) |
| `1020-dtc-werror-off.patch` | `dtc` собирается с `-Werror` и падает на GCC 15 |
| `1011-atf-mt7988-4bg.patch` | TF-A: сборки `mt7988-*-comb-4bg` (8GB RAM) |
| `1012-uboot-mt7988-4bg.patch` | U-Boot bpi-r4: зависимость на `*-comb-4bg` TF-A |
| `1013-filogic-bpi-r4-8g.patch` | Возврат ARTIFACTS bpi-r4 (MTK-фид их удалял) + `sdcard_8g.img.gz` и `preloader-8g.bin` |

Дополнительно в `customize.sh`:

* **hostapd-снапшот** `2026.02.19~53d12cd4` отсутствует в зеркалах — тарболл
  префетчится из `git.w1.fi` по зафиксированному SHA (HTTP/1.1, ретраи),
  `PKG_MIRROR_HASH` отключается
* **vpnc** — `mkdir` без `-p` (не идемпотентен)
* **mbedtls** — обход GCC 14 + musl fortify
* **символы ядра** — фиксация новых Kconfig-символов MTK, `NF_CONNTRACK=y`,
  `NF_FLOW_TABLE=y`, `PTP_1588_CLOCK=y` (иначе `vmlinux` не линкуется из-за
  встроенного `mtk_ppe*`)
* **weechat** — `luci-app-weechat` и `weechat-full/minimal` снимаются с
  установки (`scripts/feeds uninstall`): их Kconfig-цикл `select` вызывает
  `recursive dependency detected` в `make defconfig`, а на роутере они не нужны

---

## 8GB RAM и загрузчик

**8GB RAM (BPI-R4):** включены сборки TF-A/U-Boot `comb-4bg`, артефакты
`sdcard_8g.img.gz`, `emmc-preloader-8g.bin`, `snand-preloader-8g.bin`.
Патчи портированы из OpenWrt/ImmortalWrt (PR
[openwrt#21437](https://github.com/openwrt/openwrt/pull/21437), автор
[Frank Wunderlich](https://github.com/frank-w)).

**Загрузчик:** используется официальный MediaTek U-Boot и TF-A из
`mtk-openwrt-feeds` (те же бинари, что выпускает `autobuild`). В артефактах:
`*-bl31-uboot.fip`, `*-preloader.bin` / `*-preloader-8g.bin`, `emmc-gpt.bin`.

---

## Артефакты (`output/`)

| Файл | Назначение |
|---|---|
| `*-squashfs-sysupgrade.itb` | Обновление установленной системы (LuCI / sysupgrade) |
| `*-sdcard.img.gz` | Загрузочный образ SD (4GB/обычная RAM) |
| `*-sdcard_8g.img.gz` | Загрузочный образ SD для плат с 8GB RAM |
| `*-initramfs-recovery.itb` | Восстановительный образ (initramfs) |
| `*-emmc-preloader.bin` / `*-snand-preloader.bin` | BL2 для eMMC / SPI-NAND |
| `*-emmc-preloader-8g.bin` / `*-snand-preloader-8g.bin` | BL2 для 8GB RAM |
| `*-emmc-bl31-uboot.fip` / `*-snand-bl31-uboot.fip` | FIT с BL31 + U-Boot |
| `*-emmc-gpt.bin` | Таблица разделов GPT для eMMC |
| `sha256sums` | Контрольные суммы образов |
| `config.buildinfo` / `feeds.buildinfo` / `version.buildinfo` | Что именно собрано и из каких ревизий |
| `source-versions.txt` | Точные коммиты OpenWrt и mtk-openwrt-feeds (`build.sh`) |
| `packages/` | Пакеты образа + arch-независимые пакеты из `bin/packages` |

Загрузочные образы (SD) содержат U-Boot, BL2 и установочный раздел —
с их помощью прошиваются SPI-NAND/eMMC. `initramfs-recovery` шьётся отдельно
(в SD-образ не включён: MTK recovery ~47М не влезает в отведённое окно).

**Сеть по умолчанию:** `192.168.1.1`, пароль отсутствует.

---

## Локальные пакеты

Русифицированы; исходно из [MedyMa/luci-app](https://github.com/MedyMa/luci-app)
(адаптированы, обновлены, переведены):

| Пакет | Описание | Автор |
|---|---|---|
| `luci-app-fan` | Управление вентилятором BPI-R4 | [MedyMa](https://github.com/MedyMa/luci-app) |
| `luci-app-sfp-status` | Статус SFP-модулей | [MedyMa](https://github.com/MedyMa/luci-app) |
| `luci-app-modemband` | Управление полосами модема | [MedyMa](https://github.com/MedyMa/luci-app) |
| `luci-app-turboacc-mtk` | Сетевое ускорение MediaTek (HNAT) | [MedyMa](https://github.com/MedyMa/luci-app) |
| `luci-app-traffic` (+ ru) | Статистика трафика по приложениям | [MedyMa](https://github.com/MedyMa/luci-app) |
| `modemband` | Утилита управления полосами модема | [Cezary Jackiewicz](https://eko.one.pl) |

## Сторонние LuCI-приложения

Подключаются при сборке через `git clone`:

| Пакет | Описание | Автор |
|---|---|---|
| `luci-theme-argon` | Тема Argon и её настройки (config app входит в тему) | [jerrykuku](https://github.com/jerrykuku) |
| `luci-app-temp-status` | Датчики температуры | [gSpotx2f](https://github.com/gSpotx2f) |
| `luci-app-cpu-status` | Загрузка CPU | [gSpotx2f](https://github.com/gSpotx2f) |
| `luci-app-cpu-perf` | Производительность CPU | [gSpotx2f](https://github.com/gSpotx2f) |
| `luci-app-interfaces-statistics` | Статистика интерфейсов | [gSpotx2f](https://github.com/gSpotx2f) |
| `luci-app-disks-info` | Информация о дисках | [gSpotx2f](https://github.com/gSpotx2f) |
| `luci-app-internet-detector` | Детектор интернета | [gSpotx2f](https://github.com/gSpotx2f) |

---

## CI (GitHub Actions)

Workflow [`.github/workflows/bpi-r4-openwrt-build.yml`](.github/workflows/bpi-r4-openwrt-build.yml):

* job `checks` (push/PR и перед каждой сборкой): `bash -n`, shellcheck
  (advisory) и все offline-наборы `luci-app-traffic`; падение гейтит сборку
* сборка по расписанию (ежедневно, 01:00 МСК) и вручную
  (**Actions → bpi-r4-openwrt → Run workflow**); push/PR сборку не запускают
* те же гейты, что и в `build.sh`: `REQUIRED_IN_CONFIG`, наличие `*.img.gz`/`*.itb`
  и 8GB-артефактов (`sdcard_8g.img.gz`, `preloader-8g.bin`)
* в релиз попадают образы, `sha256sums`, `profiles.json`, `*.buildinfo` и
  `source-versions.txt`; `upload-artifact` падает, если файлов нет
* кеши toolchain (`klever1988/cachewrtbuild`) и ccache, очистка старых кешей/запусков
* публикация артефактов и релиза, хранение 3 последних релизов
* `RELEASES_TOKEN` не требуется — используется встроенный `GITHUB_TOKEN`
  (права `contents: write`, `actions: write` только у job'а сборки)
* пин ревизий — repository variables `OPENWRT_REF` / `MTK_FEED_REF`
  (ветка, тег или 40-hex SHA); точные коммиты попадают в тело релиза

Используемые Actions: [actions/checkout](https://github.com/actions/checkout),
[actions/upload-artifact](https://github.com/actions/upload-artifact),
[actions/cache](https://github.com/actions/cache),
[actions/github-script](https://github.com/actions/github-script),
[easimon/maximize-build-space](https://github.com/easimon/maximize-build-space),
[klever1988/cachewrtbuild](https://github.com/klever1988/cachewrtbuild),
[softprops/action-gh-release](https://github.com/softprops/action-gh-release).

Структура воркфлоу вдохновлена [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt).

---

## Авторы и лицензии

Проект распространяется под **GNU GPL v2.0** (см. [`LICENSE`](LICENSE)).
Компоненты сохраняют собственные лицензии.

| Компонент | Авторы / источник | Лицензия |
|---|---|---|
| OpenWrt | [openwrt/openwrt](https://github.com/openwrt/openwrt) | GPL-2.0 |
| MediaTek SDK (патчи, драйверы, U-Boot/ATF) | [mediatek/mtk-openwrt-feeds](https://github.com/mediatek/mtk-openwrt-feeds) | GPL-2.0 |
| mt76 / mac80211 / hostapd | [openwrt/mt76](https://github.com/openwrt/mt76), [w1.fi/hostap](https://w1.fi/hostap.git) | GPL-2.0 / BSD |
| Патчи 8GB RAM | [Frank Wunderlich](https://github.com/frank-w), ImmortalWrt/OpenWrt PR [#21437](https://github.com/openwrt/openwrt/pull/21437) | GPL-2.0 |
| Предыдущая база (историческая) | [chasey-dev/immortalwrt-mt798x-rebase](https://github.com/chasey-dev/immortalwrt-mt798x-rebase) | GPL-2.0 |
| Форк-источник проекта | [MedyMa/BananaPi-BPI-R4](https://github.com/MedyMa/BananaPi-BPI-R4) | GPL-2.0 |
| Локальные LuCI-пакеты | [MedyMa/luci-app](https://github.com/MedyMa/luci-app) | см. репозитории |
| modemband | Cezary Jackiewicz ([eko.one.pl](https://eko.one.pl)) | MIT |
| Тема Argon | [jerrykuku](https://github.com/jerrykuku) | GPL-3.0 |
| gSpotx2f-приложения | [gSpotx2f](https://github.com/gSpotx2f) | GPL-2.0 |
| CI-шаблон | [P3TERX/Actions-OpenWrt](https://github.com/P3TERX/Actions-OpenWrt) | MIT |

Отдельные файлы локальных пакетов могут содержать собственные заголовки
лицензий (MIT/Apache/GPL) — они имеют приоритет для соответствующих файлов.
