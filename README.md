# DSNVPS v7.1.0 - Ultra Edition (VPSSIM + WPTangToc OLS + 2026+ Auto-Optimizer)

Bộ công cụ quản trị VPS LEMP (Nginx + PHP-FPM + MariaDB) dòng lệnh **toàn diện, siêu nhẹ, không mã hóa (100% Clear-text Bash)**, kết hợp thế mạnh quản trị đa năng của **VPSSIM** và bộ tối ưu hiệu năng/bảo mật hiện đại của **WPTangToc OLS**.

---

## Cài Đặt Nhanh (1 Dòng Lệnh)

### 1. Cài đặt tự động toàn bộ LEMP Stack + Tối ưu Server (Fresh VPS)
```bash
curl -sSL https://raw.githubusercontent.com/dsnbw/dsnvps/main/install.sh | sudo bash
```

Hoặc tùy chọn phiên bản PHP, cổng quản trị, ngôn ngữ:
```bash
curl -sSL https://raw.githubusercontent.com/dsnbw/dsnvps/main/install.sh | sudo bash -s -- --auto --php 8.4 --port 34618 --lang vi
```

### 2. Nâng cấp DSNVPS & Chạy Tối Ưu Hóa trên VPS đang chạy (không ảnh hưởng website/DB)
```bash
curl -sSL https://raw.githubusercontent.com/dsnbw/dsnvps/main/install.sh | sudo bash -s -- --upgrade --auto
```

---

## Hệ Điều Hành & Kiến Trúc Hỗ Trợ

| Hệ điều hành | Phiên bản | Kiến trúc |
|---|---|---|
| **Ubuntu** | 20.04, 22.04, 24.04, 26.04+ | `x86_64` & `ARM64` |
| **Debian** | 11, 12, 13+ | `x86_64` & `ARM64` |
| **AlmaLinux / Rocky / RHEL / Oracle Linux** | 8, 9, 10+ | `x86_64` & `ARM64` |

---

## Các Kỹ Thuật Tối Ưu Hiện Đại (Tự Động Áp Dụng Khi Cài Đặt)

- **Kernel & Network Tuning**: Google **TCP BBR / BBR2 / BBR3** + `fq` qdisc, `tcp_fastopen=3`, `tcp_notsent_lowat=16384`, buffer QUIC/HTTP3, tối ưu `nf_conntrack`, `aio-max-nr`, `inotify`, giới hạn file descriptor `524288`.
- **ZRAM Swap (`zstd`)**: Tạo Swap nén trực tiếp trên RAM (`zstd`, ưu tiên `prio=100`), đồng bộ `vm.swappiness=100`, `vm.page-cluster=0`, giảm ghi/xóa SSD/NVMe và chống OOM.
- **MariaDB `jemalloc` + Auto-Tune**: Cài đặt `libjemalloc2` qua systemd `LD_PRELOAD` (có auto-rollback an toàn), tự động tính `innodb_buffer_pool_size` theo RAM và `innodb_io_capacity=2000` cho SSD/NVMe.
- **OOM Score Protection**: Bảo vệ `sshd` (`-1000`), `mariadb` (`-600`), `nginx` (`-300`), `redis/valkey/memcached` (`-200`) khỏi bị Kernel OOM Killer đóng nhầm khi quá tải.
- **PHP 8+ OPcache + Tracing JIT**: Tự động kích hoạt `opcache.jit=tracing`, cấp `jit_buffer_size` theo RAM thực tế (tự bảo vệ nếu RAM <= 1 GB hoặc đang cài ionCube), `realpath_cache_size=4096k`.
- **Nginx Tối Đa Tốc Độ**: Nén kép **Brotli + Gzip**, `pcre_jit on`, `open_file_cache`, TLS 1.3 + `ssl_buffer_size 4k` + `0-RTT`, và **Nginx FastCGI Page Cache** + **Preload Sitemap Crawler**.
- **Disk I/O & Log Cap**: Tự động gắn cờ `noatime` (và `logbsize=256k` cho XFS) vào `/etc/fstab`, bật `fstrim.timer`, tắt **Transparent Huge Pages (THP)**, giới hạn `systemd-journald` (100 MB disk / 20 MB RAM).
- **Dọn Sạch Bloatware Tự Động**: Gỡ bỏ `snapd`, `fwupd`, `multipathd`, `ModemManager`, `udisks2`, `apport`, `open-vm-tools`, `packagekit`, `unattended-upgrades` và chặn cài lại `snapd`.
- **Cài Đặt Tự Sửa Lỗi (Self-Healing)**: Tự xử lý khóa `apt/dpkg` treo, sửa lỗi đồng hồ/DNS, tạo swap tạm khi VPS RAM thấp (< 1 GB), xử lý xung đột cổng 80/443 (Apache/httpd/OLS), tự đặt SELinux Permissive trên RHEL, và bảo vệ cổng SSH hiện tại khi cấu hình Firewall.

---

## Tính Năng Quản Trị Toàn Diện (44 Nhóm Chức Năng + CLI)

- **Menu 1–39 (VPSSIM Full Unlocked)**: Quản lý Website, Reverse Proxy, SSL Let's Encrypt & Cloudflare Origin 15 năm, Backup/Restore local & Rclone (Google Drive, Dropbox, OneDrive, Telegram), Database, FTP, Cronjob, PHP Version Switcher (7.4–8.4), CSF / NFtables / IPtables, GeoIP2, Cloudflare DDNS, VLESS VPN, Migration từ CentminMod/HocVPS/LarVPS/WPTangToc...
- **Menu 40 – Server Turbo & Optimization Suite**: Bật/tắt & tinh chỉnh toàn bộ các lớp tối ưu hệ thống, xả RAM cache.
- **Menu 41 – DSNVPS WTOP**: Bảng giám sát tài nguyên Real-time (`dsnvps top` / `dsnvps status`).
- **Menu 42 – Security Pro**: Quét mã độc WordPress siêu nhẹ bằng **YARA Engine** + `wp core verify-checksums`, bật/tắt **7G WAF Firewall**, **Chặn Bot AI/Scraper**, kiểm tra hạn chứng chỉ SSL toàn server.
- **Menu 43 – Nginx FastCGI Page Cache & Preload Sitemap**: Bật/tắt cache trang siêu tốc cho WordPress/WooCommerce & làm nóng cache tự động.
- **Menu 8 (WordPress Pro 18–26)**: Khám sức khỏe WP & Autoload DB, Dọn rác DB, Link đăng nhập 1-Click Magic Login, Chặn XML-RPC & tối ưu Heartbeat, Maintenance Mode & WP_DEBUG, Đổi Table Prefix & Salt Keys, Search & Replace URL.

### Lệnh CLI Nhanh
```bash
dsnvps                  # Mở Menu tương tác chính
dsnvps status           # Xem nhanh thông số server & trạng thái tối ưu
dsnvps top              # Giám sát tài nguyên Real-time (WTOP)
dsnvps optimize         # Chạy 1-Click tối ưu toàn diện
dsnvps clean-ram        # Xả bộ nhớ đệm RAM (PageCache/Dentries/Inodes)
dsnvps restart          # Khởi động lại Nginx, PHP-FPM, MariaDB
dsnvps list             # Liệt kê danh sách website trên server
dsnvps ssl-check        # Kiểm tra hạn chứng chỉ SSL tất cả domain
dsnvps scan-malware     # Quét mã độc WordPress bằng YARA Engine
dsnvps preload          # Preload cache từ sitemap XML
dsnvps wp-health        # Khám sức khỏe WordPress & kiểm tra Autoload DB
dsnvps wp-clean         # Dọn rác Database WordPress & Optimize Table
dsnvps help             # Hiển thị toàn bộ lệnh CLI
```
