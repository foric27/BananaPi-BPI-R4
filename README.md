# BananaPi R4 Firmware

## Tips
* Default Gateway: 192.168.1.1
* Password: none
* Support BRI-R4-NIC-BE14 Model
* Support MTK-HNAT

## Настройка автоматических сборок

### Секреты (Secrets)

Для публикации релизов необходим персональный токен GitHub:

1. Перейдите в **GitHub repo → Settings → Secrets and variables → Actions**
2. Нажмите **New repository secret**
3. Имя: `RELEASES_TOKEN`
4. Значение: Personal Access Token (classic) с правами `contents: write`

Как создать токен:
1. **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. **Generate new token (classic)**
3. Выберите срок действия и права: `contents: write`
4. Скопируйте токен и вставьте в секрет `RELEASES_TOKEN`

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

## Пакеты

LuCI-приложения взяты из [MedyMa/luci-app](https://github.com/MedyMa/luci-app) и переведены на русский язык:

| Пакет | Описание | Автор |
|---|---|---|
| luci-app-fan | Управление вентилятором (BPI-R4) | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-sfp-status | Статус SFP-модулей | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-adguardhome | AdGuard Home | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-modemband | Управление полосами модема | [MedyMa](https://github.com/MedyMa/luci-app) |
| luci-app-turboacc-mtk | Сетевое ускорение MediaTek | [MedyMa](https://github.com/MedyMa/luci-app) |
