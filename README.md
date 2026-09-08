# BananaPi R4 Firmware

## Tips
* Default Gateway: 192.168.1.1
* Password: none
* Support BRI-R4-NIC-BE14 Model
* Support MTK-HNAT

## Настройка автоматических сборок

### Секреты (Secrets)

**Секрет `RELEASES_TOKEN` больше не требуется** — удаление старых релизов
выполняется встроенным `GITHUB_TOKEN` через gh-CLI (права workflow:
`contents: write` + `actions: write`). Персональный токен можно удалить
из **Settings → Secrets and variables → Actions**.

### Настройки Actions

Убедитесь, что Actions разрешены:
1. **GitHub repo → Settings → Actions → General**
2. **Workflow permissions** → "Read and write permissions"
3. **Allow all actions and reusable workflows** → включено

### Ручной запуск

1. Перейдите в **Actions → immortalwrt_25.12_wifi7**
2. Нажмите **Run workflow**
3. Сборка запустится автоматически

### Автоматический запуск

Сборка выполняется ежедневно в 01:00 МСК по расписанию.

## References
* https://github.com/immortalwrt/immortalwrt
* https://github.com/P3TERX/Actions-OpenWrt
* https://github.com/padavanonly/immortalwrt-mt798x-6.6

## Локальные пакеты

LuCI-приложения взяты из [MedyMa/luci-app](https://github.com/MedyMa/luci-app) и переведены на русский язык:

| Пакет | Описание | Автор |
|---|---|---|
| luci-app-fan | Управление вентилятором (BPI-R4) | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-sfp-status | Статус SFP-модулей | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-modemband | Управление полосами модема | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-turboacc-mtk | Сетевое ускорение MediaTek | [MedyMa](https://github.com/MedyMa/luci-app) |
| openwrt-caddy | Веб-сервер Caddy v2.11.4 | [caddyserver](https://github.com/caddyserver/caddy) |
| luci-app-caddy | LuCI-интерфейс для Caddy | [kiddin9](https://github.com/kiddin9/op-packages) |

## Сторонние LuCI-приложения

Приложения подключены при сборке через `git clone` (не локальные пакеты):

| Пакет | Описание | Автор | Репозиторий |
|---|---|---|---|
| luci-theme-argon | Тема Argon | [jerrykuku](https://github.com/jerrykuku) | [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon) |
| luci-app-argon-config | Настройки темы Argon | [jerrykuku](https://github.com/jerrykuku) | [luci-app-argon-config](https://github.com/jerrykuku/luci-app-argon-config) |
| luci-app-temp-status | Датчики температуры | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-temp-status](https://github.com/gSpotx2f/luci-app-temp-status) |
| luci-app-cpu-status | Загрузка CPU | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-cpu-status](https://github.com/gSpotx2f/luci-app-cpu-status) |
| luci-app-cpu-perf | Управление производительностью CPU | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-cpu-perf](https://github.com/gSpotx2f/luci-app-cpu-perf) |
| luci-app-interfaces-statistics | Статистика сетевых интерфейсов | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-interfaces-statistics](https://github.com/gSpotx2f/luci-app-interfaces-statistics) |
| luci-app-disks-info | Информация о дисках | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-disks-info](https://github.com/gSpotx2f/luci-app-disks-info) |
| luci-app-internet-detector | Детектор интернета | [gSpotx2f](https://github.com/gSpotx2f) | [luci-app-internet-detector](https://github.com/gSpotx2f/luci-app-internet-detector) |
