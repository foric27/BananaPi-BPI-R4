# BananaPi R4 Firmware

## Tips
* Default Gateway: 192.168.1.1
* Default Password: password
* Support BRI-R4-NIC-BE14 Model
* Support MTK-HNAT
* Lighttpd on port 80, LuCI (uhttpd) on port 8888
* NetPulse agent (github.com/gnacho/netpulse) with its LuCI page: the router
  can be monitored by a self-hosted NetPulse server (agent is idle until
  `/etc/config/netpulse-agent` has `server`, `token` and `slug`)
* NetPulse on-box server: HTTPS web UI on port 3100 (`https://192.168.1.1:3100`),
  SQLite data in `/usr/local/netpulse-data` (set `netpulse.server.data_dir` to a
  mounted USB path to keep the database off flash); the initial admin password
  is generated on first boot and printed once in `logread`

## References
* https://github.com/immortalwrt/immortalwrt
* https://github.com/P3TERX/Actions-OpenWrt
* https://github.com/padavanonly/immortalwrt-mt798x-6.6

## Local build

Incremental local build (no GitHub Actions needed):

```sh
# first run: clones ImmortalWrt, feeds and community repositories, then builds
scripts/build-local.sh

# force source/feed updates and package downloads
scripts/build-local.sh --force

# limit build parallelism (default: nproc)
scripts/build-local.sh --jobs 8
```

The script keeps the `openwrt/` tree between runs. Source, feed and community
repositories are compared with their remote branches (`git ls-remote`) and only
updated when they changed; `make download` and the build are skipped/limited when
nothing changed. Images are written to `openwrt/bin/targets/mediatek/filogic`,
including the 8 GB RAM variants (`sdcard_8g.img.gz`, `*-preloader-8g.bin`).
