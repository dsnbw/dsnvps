#!/bin/bash
# DSNVPS Migration từ HostVN
# Migration từ VPS cũ chạy HostVN về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Function: Migration từ HostVN (được gọi từ smart_migration)
migrate_from_hostvn() {
	# Kiểm tra kết nối VPS cũ
	check_old_vps_connection
	
	# Lấy thông tin kết nối
	vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
	sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

	# Kiểm tra HostVN signature trên VPS cũ
	if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb [ -f /var/hostvn/.hostvn.conf ]" 2>/dev/null; then
		handle_error "VPS cũ KHÔNG chạy HostVN"
	fi
	
	echo "-------------------------------------------------------------------------"
	echo "==> Bắt đầu chuyển dữ liệu từ HostVN..."
	echo "-------------------------------------------------------------------------"
sleep 5
	# Tạo script backup trên VPS cũ
	cat <<'EOF' > /tmp/dsnvps-prepare-data.sh
#!/bin/bash
# Script backup dữ liệu từ HostVN

set -e

mkdir -p /home/dsnvps/sql /home/dsnvps
rm -f /home/dsnvps/domains.txt /home/dsnvps/database_list.txt

# Đọc thông tin từ file cấu hình HostVN
if [ ! -f /var/hostvn/.hostvn.conf ]; then
	echo "Không tìm thấy /var/hostvn/.hostvn.conf"
	exit 1
fi

# Parse cấu hình
mysql_pwd=$(grep -E '^mysql_pwd=' /var/hostvn/.hostvn.conf | tail -1 | cut -d'=' -f2-)
MYSQL_USER="root"
MYSQL_PASS="$mysql_pwd"

# Tìm domain từ vhost files trong /etc/nginx/conf.d/
VHOST_DIR="/etc/nginx/conf.d"
if [ -d "$VHOST_DIR" ]; then
	for conf_file in "$VHOST_DIR"/*.conf; do
		[ -f "$conf_file" ] || continue
		domain=$(basename "$conf_file" .conf)
		# tên file có >=2 dấu chấm coi như domain/subdomain hợp lệ
		if [[ "$domain" =~ ^[^.]+\.[^.]+(\..+)?$ ]]; then
			root_path=$(grep -E '^\s*root\s+' "$conf_file" 2>/dev/null | awk '{print $2}' | sed 's/;//' | head -1)
			if [ -n "$root_path" ] && [ -d "$root_path" ]; then
				root_path=$(echo "$root_path" | sed 's|/$||')
				echo "$domain | $root_path" >> /home/dsnvps/domains.txt
			fi
		fi
	done
fi

# Lấy danh sách database (loại trừ system)
echo "-------------------------------------------------------------------------"
echo "==> Đang backup database từ VPS cũ..."
DBS=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "^(Database|information_schema|mysql|performance_schema|sys)$")

if [ -n "$DBS" ]; then
	database_count=$(echo "$DBS" | wc -l)
	echo "-------------------------------------------------------------------------"
	echo "==> Tìm thấy $database_count database để backup"
	# Ghi danh sách database (chỉ tên là đủ)
	echo "# Danh sách database từ VPS cũ" > /home/dsnvps/database_list.txt
	echo "# Format: old_db_name" >> /home/dsnvps/database_list.txt

	current_db=0
	for db in $DBS; do
		current_db=$((current_db + 1))
		echo "========================================================================="
		echo "Backup database ($current_db/$database_count): $db"
		# Đếm số bảng
		table_count=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null | tail -1)
		if [[ "$table_count" =~ ^[0-9]+$ ]] && [ "$table_count" -ge 0 ]; then
			echo "-------------------------------------------------------------------------"
			echo "==> Database $db - Tiến hành backup (Tables: $table_count)"
			mkdir -p /home/dsnvps/sql/"$db"
			if mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASS" \
				--single-transaction \
				--routines \
				--triggers \
				--lock-tables=false \
				"$db" 2>/dev/null | gzip > /home/dsnvps/sql/"$db"/"${table_count}_tables_${db}.sql.gz"; then
				echo "-------------------------------------------------------------------------"
				echo "==> Hoàn thành backup database: $db -> ${table_count}_tables_${db}.sql.gz"; sleep 2
				#echo "========================================================================="
				echo "$db" >> /home/dsnvps/database_list.txt
			else
				echo "==> Cảnh báo: Không thể backup database $db"
			fi
		else
			echo "==> Cảnh báo: Không thể đếm tables cho database $db (table_count: '$table_count')"
		fi
	done
else
	echo "==> Cảnh báo: Không tìm thấy database nào trên VPS cũ"
fi
EOF

	# Gửi script và thực thi
	scp -P "$sshport" /tmp/dsnvps-prepare-data.sh root@$vpsipcu:/tmp/ >/dev/null 2>&1
	ssh -p "$sshport" root@$vpsipcu "TERM=dumb chmod +x /tmp/dsnvps-prepare-data.sh && bash /tmp/dsnvps-prepare-data.sh" 2>/dev/null

	# Tải dữ liệu về VPS mới
	mkdir -p /home/dsnvps_restore /tmp/dataolstmp /etc/dsnvps/.tmp
	rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/domains.txt /home/dsnvps_restore/ 2>/dev/null
	rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/database_list.txt /home/dsnvps_restore/ 2>/dev/null
	# Rsync per-db backups theo cấu trúc đã thống nhất
	rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/sql/ /home/dsnvps.demo/private_html/backup/ 2>/dev/null

	# Phục hồi database
	echo "-------------------------------------------------------------------------"
	echo "Đang phục hồi database..."; sleep 5
	total_dbs=$(grep -v "^#" /home/dsnvps_restore/database_list.txt | grep -v "^$" | wc -l)
	current_db=0

	# Tạo file mapping database cũ -> mới với format đẹp
	echo "# Thay thông tin database tương ứng với database mới" > /home/dsnvps_restore/list-database.txt
	echo "# Username - Data_name - Password" >> /home/dsnvps_restore/list-database.txt
	echo "" >> /home/dsnvps_restore/list-database.txt

	mariadbpass=$(get_mariadb_password)

	# Xử lý từng database (chỉ lấy tên ở cột 1)
	while IFS='|' read -r old_db_name __; do
		[[ "$old_db_name" =~ ^#.*$ ]] && continue
		[[ -z "$old_db_name" ]] && continue
		current_db=$((current_db + 1))
		db_name="$old_db_name"
		echo "Xử lý database ($current_db/$total_dbs): $db_name"

		# Lấy thông tin từ /root/DBinfo.txt nếu có
		existing_info=$(get_existing_db_info "$db_name")
		if [ $? -eq 0 ] && [ -n "$existing_info" ]; then
			new_username=$(echo "$existing_info" | cut -d'|' -f1)
			new_password=$(echo "$existing_info" | cut -d'|' -f2)
			echo "==> Database $db_name đã có trong DBinfo.txt - sử dụng thông tin cũ: user=$new_username"
		else
			echo "==> Database $db_name chưa có trong DBinfo.txt - tạo mới"
			new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
			new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
			if ! create_database_and_user "$db_name" "$new_username" "$new_password" "$mariadbpass"; then
				echo "==> Cảnh báo: Không thể tạo database $db_name"
				continue
			fi
		fi

		# Phục hồi dữ liệu: chọn file backup có số tables lớn nhất trong thư mục theo tên DB
		best_file=""; best_count=-1
		for f in /home/dsnvps.demo/private_html/backup/"${db_name}"/*_tables_${db_name}.sql.gz; do
			[ -e "$f" ] || continue
			base=$(basename "$f")
			count_part=${base%%_tables_*}
			if [[ "$count_part" =~ ^[0-9]+$ ]] && [ "$count_part" -gt "$best_count" ]; then
				best_count=$count_part
				best_file="$f"
			fi
		done
		if [ -n "$best_file" ]; then
			echo "==> Tìm thấy file backup: $(basename "$best_file") (tables=$best_count)"; sleep 2
			restore_database_from_backup "$best_file" "$db_name" "$mariadbpass"
		else
			echo "⚠️ Cảnh báo: Không tìm thấy file backup cho database $db_name"
			find /home/dsnvps.demo/private_html/backup/"${db_name}" -maxdepth 1 -type f -name "*${db_name}*" -print 2>/dev/null || true
		fi

		# Luôn ghi vào file mapping kết quả
		{
			echo "========================================================================="
			echo "Database cũ: $old_db_name"
			echo ""
			echo "=> Database mới:"
			echo ""
			echo "Data_name: $db_name"
			echo "Username: $new_username"
			echo "Password: $new_password"
			echo ""
			echo "========================================================================="
		} >> /home/dsnvps_restore/list-database.txt

		# Ghi DBinfo.txt chỉ khi chưa có
		existing_info=$(get_existing_db_info "$db_name")
		if [ $? -ne 0 ] || [ -z "$existing_info" ]; then
			write_database_info "$db_name" "$new_username" "$new_password"
			echo "==> Đã ghi thông tin database mới vào DBinfo.txt"
		else
			echo "==> Database $db_name đã có trong DBinfo.txt - bỏ qua ghi DBinfo.txt"
		fi

		sleep 1
	done < /home/dsnvps_restore/database_list.txt

	# Copy website files sau khi phục hồi database
	echo "------------------------------------------------------------------------- " 
	echo "Đang copy website code..."
	total_domains=$(wc -l < /home/dsnvps_restore/domains.txt 2>/dev/null || echo 0)
	current_domain=0

	while IFS='|' read -r domain path; do
		domain=$(echo "$domain" | xargs)
		path=$(echo "$path" | xargs)
		if [[ -n "$domain" && -n "$path" ]]; then
			current_domain=$((current_domain + 1))
			echo "------------------------------------------------------------------------- " 
			echo "==> Copy website ($current_domain/$total_domains): $domain"
			mkdir -p /home/$domain/public_html
			if rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$path/" "/home/$domain/public_html/" 2>/dev/null; then
				find /home/$domain/public_html -type d -exec chmod 755 {} \;
				find /home/$domain/public_html -type f -exec chmod 644 {} \;
				chown -R nginx:nginx /home/$domain/public_html
				echo "------------------------------------------------------------------------- " 
				echo "==> Hoàn thành copy website: $domain"
			else
				echo "------------------------------------------------------------------------- " 
				echo "⚠️ Cảnh báo: Không thể copy website $domain"
			fi
		fi
	done < /home/dsnvps_restore/domains.txt

	# Dọn dẹp nhẹ
	rm -rf /tmp/dataolstmp
	sleep 3

	clear
	echo "========================================================================="
	echo "HOÀN THÀNH CHUYỂN DỮ LIỆU TỪ VPS CŨ HOSTVN"
	echo "========================================================================="
	echo "==> Đã chuyển dữ liệu thành công:"
	echo "-------------------------------------------------------------------------"
	echo "• Database: Tạo mới"
	echo "• File lưu trữ thông tin: /home/dsnvps_restore/list-database.txt"
	echo "• Xem thông tin database mới [ 4. Xem Thông Tin Database Mới ]"
	echo "-------------------------------------------------------------------------"
	echo "==> Thông tin chi tiết:"
	echo "• Số website đã chuyển: $total_domains"
	echo "• Số database đã chuyển: $total_dbs"
	echo "========================================================================="
	echo "Lưu ý: "
	echo "-------------------------------------------------------------------------"
	echo "1. Bạn cần thêm lần lượt các web vào VPS bằng chức năng [ Thêm Website ]"
	echo "-------------------------------------------------------------------------"
	echo "hoặc [Add Website + Config Vhost For Wordpress Cache] để tạo Vhost cho"
	echo "-------------------------------------------------------------------------"
	echo "tất cả website đã được đưa sang."
	echo "-------------------------------------------------------------------------"
	echo "2. Nếu VPS cũ dùng DSNVPS thì không cần cấu hình lại Database."
	echo "-------------------------------------------------------------------------"
	echo "3. Nếu VPS cũ không dùng DSNVPS thì cần chỉnh sửa lại thông tin database"
	echo "-------------------------------------------------------------------------"
	echo "trong config website. Dùng chức năng [4. Xem Thông Tin Database Mới]"
	echo "-------------------------------------------------------------------------"
	echo "để tìm database mới tương ứng với database cũ."
	echo "-------------------------------------------------------------------------"
	echo "3. Nếu Zend Opcache BẬT nên sau khi edit php xong, cần clear Zend Opcache"
	echo "-------------------------------------------------------------------------"
	echo "để file php được cập nhật."
	echo "========================================================================="
	echo "Nhấn Enter để quay về menu chính..."
	read -r
	main_menu
	echo "==> Thông tin chi tiết:"
	echo "• Số website đã chuyển: $total_domains"
	echo "• Số database đã chuyển: $total_dbs"
	echo "========================================================================="
}