# BananaPi R4 Firmware

## Tips
* Default Gateway: 192.168.2.1
* Default Password: password
* Support BRI-R4-NIC-BE14 Model
* Support MTK-HNAT

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
