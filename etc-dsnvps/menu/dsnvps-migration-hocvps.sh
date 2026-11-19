#!/bin/bash
# DSNVPS Migration từ HocVPS
# Migration từ VPS cũ chạy HocVPS về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Function: Migration từ HocVPS (giữ nguyên DB name, tạo user/pass mới nếu cần)
migrate_from_hocvps() {
	# Kiểm tra kết nối VPS cũ
	check_old_vps_connection
	
	# Lấy thông tin kết nối
	vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
	sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

	# Kiểm tra signature HocVPS
	if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /etc/hocvps/scripts.conf" 2>/dev/null; then
		handle_error "Không tìm thấy /etc/hocvps/scripts.conf trên VPS cũ (không phải HocVPS?)"
	fi

	echo "-------------------------------------------------------------------------"
	echo "Bắt đầu chuyển dữ liệu từ HocVPS..."; sleep 2

	# Copy /etc/hocvps/scripts.conf từ VPS cũ về tạm
if ! scp -q -P "$sshport" root@"$vpsipcu":/etc/hocvps/scripts.conf /tmp/hocvps.scripts.conf >/dev/null 2>&1; then
	handle_error "Không thể copy file /etc/hocvps/scripts.conf từ VPS cũ $vpsipcu"
fi

	# Lấy MySQL root credentials từ /tmp/hocvps.scripts.conf
	if [ -f /tmp/hocvps.scripts.conf ]; then
		mysql_user="root"
		# mariadb_root_password="..." -> bỏ dấu nháy kép ở đầu/cuối
		mysql_pass=$(grep -E '^mariadb_root_password=' /tmp/hocvps.scripts.conf | tail -1 | cut -d'=' -f2- | sed -e 's/^"//' -e 's/"$//')
		if [ -z "$mysql_pass" ]; then
			handle_error "Không thể đọc mariadb_root_password từ /etc/hocvps/scripts.conf trên VPS cũ"
		fi
	else
		handle_error "Không tìm thấy /tmp/hocvps.scripts.conf sau khi copy"
	fi

	# Kiểm tra kết nối MySQL trên VPS cũ
	mysql_check=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e 'SELECT 1;' 2>&1" 2>/dev/null)
	mysql_exit_code=$?
	if [ $mysql_exit_code -eq 124 ]; then
		handle_error "Kết nối MySQL bị timeout (quá 60 giây). Vui lòng kiểm tra MySQL trên VPS cũ."
	elif [ $mysql_exit_code -ne 0 ]; then
		handle_error "Không thể kết nối MySQL trên VPS cũ. Kiểm tra /etc/hocvps/scripts.conf. Lỗi: $mysql_check"
	fi
	echo "==> Kết nối MySQL thành công"; sleep 1

	# Lấy danh sách database và backup trên VPS cũ (giữ cấu trúc /backup/<db>/<file>)
	echo "-------------------------------------------------------------------------"
	echo "Đang lấy danh sách database từ VPS cũ..."; sleep 1
	all_databases=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '(Database|information_schema|mysql|performance_schema|sys)'" 2>/dev/null)

	if [ -n "$all_databases" ]; then
		database_count=$(echo "$all_databases" | wc -l)
		echo "-------------------------------------------------------------------------"
		echo "Tìm thấy $database_count database để backup"

		# Tạo thư mục backup gốc trên VPS cũ và mới
		ssh -p "$sshport" root@$vpsipcu "TERM=dumb mkdir -p /home/dsnvps.demo/private_html/backup" 2>/dev/null || true
		mkdir -p /home/dsnvps.demo/private_html/backup

		current_db=0
		for database in $all_databases; do
			current_db=$((current_db + 1))
			echo "-------------------------------------------------------------------------"
			echo "==> Backup database ($current_db/$database_count): $database"; sleep 1

			table_count=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='\''$database'\'';' 2>/dev/null" | tail -1)
			[ -z "$table_count" ] && table_count=0

			backup_dir="/home/dsnvps.demo/private_html/backup/$database"
			ssh -p "$sshport" root@$vpsipcu "TERM=dumb mkdir -p '$backup_dir'" 2>/dev/null || true
			backup_filename="${table_count}_tables_${database}.sql.gz"
			if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysqldump -u$mysql_user -p'$mysql_pass' $database 2>/dev/null | gzip > '$backup_dir/$backup_filename'" 2>/dev/null; then
				echo "==> Cảnh báo: Không thể backup database $database"
			else
				echo "==> Hoàn thành backup database: $database -> $backup_filename"; sleep 1
			fi
		done

		echo "==> Đã backup $database_count database trên VPS cũ"

		# Đồng bộ toàn bộ backup tree từ VPS cũ sang VPS mới
		echo "-------------------------------------------------------------------------"
		echo "Đang đồng bộ backup từ VPS cũ về VPS mới..."
		if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps.demo/private_html/backup/ /home/dsnvps.demo/private_html/backup/ 2>/dev/null; then
			echo "==> Cảnh báo: Không thể đồng bộ backup từ VPS cũ"
		else
			echo "==> Hoàn thành đồng bộ backup"
		fi
	else
		echo "==> Cảnh báo: Không tìm thấy database nào trên VPS cũ"
	fi

	# Phục hồi database trên VPS mới (giữ nguyên tên, idempotent username/password)
	echo "-------------------------------------------------------------------------"
	echo "Đang phục hồi database từ VPS cũ..."; sleep 1

	mariadbpass=$(get_mariadb_password)
	if [ -z "$mariadbpass" ]; then
		handle_error "Không có mật khẩu MariaDB để phục hồi database"
	fi

	if [ -n "$all_databases" ]; then
		database_count=$(echo "$all_databases" | wc -l)
		echo "-------------------------------------------------------------------------"
		echo "==> Tìm thấy $database_count database để phục hồi"; sleep 1

		list_file="/home/dsnvps_restore/list-database.txt"
		mkdir -p "/home/dsnvps_restore"
		{
			echo "# Danh sách database tạo (giữ nguyên tên)"
			echo "-------------------------------------------------------------------------"
		} > "$list_file"

		current_db=0
		for database in $all_databases; do
			database=$(printf "%s" "$database" | tr -d '\r' | sed -E 's/^[ \t]+|[ \t]+$//g')
			current_db=$((current_db + 1))
			echo "-------------------------------------------------------------------------"
			echo "Phục hồi database ($current_db/$database_count): $database"

			# Kiểm tra DB tồn tại chưa
			if database_exists "$database" "$mariadbpass"; then
				echo "==> Database $database đã tồn tại - chỉ phục hồi dữ liệu"
				backup_dir="/home/dsnvps.demo/private_html/backup/$database"
				best_file=""; best_count=-1
				for f in "$backup_dir"/*_tables_${database}.sql.gz; do
					[ -e "$f" ] || continue
					base=$(basename "$f"); count_part=${base%%_tables_*}
					if [[ "$count_part" =~ ^[0-9]+$ ]] && [ "$count_part" -gt "$best_count" ]; then
						best_count=$count_part; best_file="$f"
					fi
				done
				if [ -n "$best_file" ]; then
					restore_database_from_backup "$best_file" "$database" "$mariadbpass"
				else
					echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
				fi
			else
				# Nếu DB chưa tồn tại: giữ tên cũ, tạo user/pass NGẪU NHIÊN (HocVPS không có DBinfo cũ)
				existing_info=$(get_existing_db_info "$database")
				if [ $? -eq 0 ] && [ -n "$existing_info" ]; then
					username=$(echo "$existing_info" | cut -d'|' -f1)
					password=$(echo "$existing_info" | cut -d'|' -f2)
				else
					username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
					password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
				fi

				if create_database_and_user "$database" "$username" "$password" "$mariadbpass"; then
					backup_dir="/home/dsnvps.demo/private_html/backup/$database"
					best_file=""; best_count=-1
					for f in "$backup_dir"/*_tables_${database}.sql.gz; do
						[ -e "$f" ] || continue
						base=$(basename "$f"); count_part=${base%%_tables_*}
						if [[ "$count_part" =~ ^[0-9]+$ ]] && [ "$count_part" -gt "$best_count" ]; then
							best_count=$count_part; best_file="$f"
						fi
					done
					if [ -n "$best_file" ]; then
						restore_database_from_backup "$best_file" "$database" "$mariadbpass"
					else
						echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
					fi

					# Ghi DBinfo.txt chỉ khi chưa có
					existing_info=$(get_existing_db_info "$database")
					if [ $? -ne 0 ] || [ -z "$existing_info" ]; then
						write_database_info "$database" "$username" "$password"
					fi

					# Mapping
					{
						echo "========================================================================="
						echo "Database cũ: $database"
						echo ""
						echo "=> Database mới:"
						echo ""
						echo "Data_name: $database"
						echo "Username: $username"
						echo "Password: $password"
						echo ""
						echo "========================================================================="
					} >> "$list_file"
				else
					echo "==> Cảnh báo: Không thể tạo database $database"
				fi
			fi

			sleep 1
		done
	else
		echo "==> Cảnh báo: Không tìm thấy database nào để phục hồi"
	fi

	# Copy website files (quét /etc/nginx/conf.d/*.conf)
	echo "-------------------------------------------------------------------------"
	echo "==> Đang copy mã nguồn website từ VPS cũ..."; sleep 1
	vhost_files=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb find /etc/nginx/conf.d -name '*.conf' -type f 2>/dev/null")
	if [ -n "$vhost_files" ]; then
		for vhost_file in $vhost_files; do
			domain=$(basename "$vhost_file" .conf)
			if ! echo "$domain" | grep -q '\.' || [ "$domain" = "dsnvps.demo" ]; then
				continue
			fi
			has_server_name=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -q 'server_name' '$vhost_file' 2>/dev/null && echo 'yes' || echo 'no'")
			if [ "$has_server_name" = "yes" ]; then
				root_path=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -E '^\s*root\s+' '$vhost_file' 2>/dev/null | awk '{print \$2}' | sed 's/;//' | head -1")
				if [ -n "$root_path" ]; then
					dir_exists=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d '$root_path' 2>/dev/null && echo 'yes' || echo 'no'")
					if [ "$dir_exists" = "yes" ]; then
						echo "-------------------------------------------------------------------------"
							echo "-------------------------------------------------------------------------"
						echo "Copy website: $domain"
						mkdir -p "/home/$domain/public_html"
						if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$root_path/" "/home/$domain/public_html/" 2>/dev/null; then
							echo "==> Cảnh báo: Không thể copy website $domain"
						else
						## Thiet lap phan quyen ####
find /home/$domain/public_html -type d -exec chmod 755 {} \;
find /home/$domain/public_html -type f -exec chmod 644 {} \;
chown -R nginx:nginx /home/$domain/public_html
##################
							echo "==>  Hoàn thành copy website: $domain"
								echo "-------------------------------------------------------------------------"
						fi
					fi
				fi
			fi
		done
	else
		echo "==> Cảnh báo: Không tìm thấy file vhost nào trong /etc/nginx/conf.d/"
	fi

	clear
	echo "========================================================================="
	echo "HOÀN THÀNH CHUYỂN DỮ LIỆU TỪ VPS CŨ HOCVPS"
	echo "========================================================================="
	echo "==> Đã chuyển dữ liệu thành công:"
	echo "• Database: Đã phục hồi (giữ nguyên tên, idempotent user/pass)"
	echo "• Backup Database: /home/dsnvps.demo/private_html/backup/"
	echo "• Mã nguồn Website: /home/<domain>/public_html"
	echo "-------------------------------------------------------------------------"
	echo "• File mapping: /home/dsnvps_restore/list-database.txt"
	echo "• DB info file: /root/DBinfo.txt"
	echo "========================================================================="
	echo "Nhấn Enter để quay về menu chính..."
	read -r
	main_menu
}

# Cho phép chạy trực tiếp
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	migrate_from_hocvps
fi


