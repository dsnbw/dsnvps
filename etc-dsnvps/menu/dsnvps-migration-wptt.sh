#!/bin/bash
# DSNVPS Migration từ WPTT
# Migration từ VPS cũ chạy WPTT về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Function: Migration từ WPTT (được gọi từ smart_migration)
migrate_from_wptt() {
    # Kiểm tra kết nối VPS cũ
    check_old_vps_connection
    
    # Lấy thông tin kết nối
    vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

    if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb [ -f /etc/wptt/.wptt.conf ]" 2>/dev/null; then
        handle_error "VPS cũ KHÔNG chạy WPTT"
    fi
    echo "-------------------------------------------------------------------------"
    echo "Bắt đầu migration từ WPTT..."; sleep 2
    #    echo "-------------------------------------------------------------------------"
   # echo "==> Đã tạo file cấu hình cho WPTT"
   #     echo "-------------------------------------------------------------------------"
    
    # Lấy thông tin từ file dsnvps.txt
    if [ -f /tmp/dsnvps.txt ]; then
        mysql_user=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
        home_folder=$(grep "home_folder=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
        nginx_conf=$(grep "nginx_conf=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
        
     #   echo "• MySQL User: $mysql_user"
     #   echo "• MySQL Password: [Ẩn]"
     #   echo "• Home Folder: $home_folder"
     #   echo "• Nginx Config: $nginx_conf"
    else
        handle_error "Không tìm thấy thông tin MySQL từ file dsnvps.txt"
    fi

    # Tạo script backup trên VPS cũ
    cat <<'EOF' > /tmp/dsnvps-prepare-data.sh
#!/bin/bash
# Script backup dữ liệu từ WPTT

mkdir -p /home/dsnvps/sql /home/dsnvps
rm -f /home/dsnvps/domains.txt

# Kiểm tra file cấu hình WPTT
if [ ! -f /etc/wptt/.wptt.conf ]; then
    echo "Cảnh báo: Không tìm thấy file cấu hình WPTT"
    exit 1
fi

# Đọc thông tin từ file cấu hình WPTT
source /etc/wptt/.wptt.conf

# Tìm domain từ vhost files trong WPTT
VHOST_DIR="/etc/wptt/vhost"
SITE_DIR="/usr/local/lsws"

echo "Đang tạo danh sách domain..."
if [ -d "$VHOST_DIR" ]; then
    for conf in $VHOST_DIR/.*.conf; do
        [ -f "$conf" ] || continue
        domain=$(basename "$conf" | sed 's/^\.//;s/\.conf$//')
        html_path="$SITE_DIR/$domain/html"
        if [ -d "$html_path" ]; then
            echo "$domain | $SITE_DIR/$domain" >> /home/dsnvps/domains.txt
            echo "Tìm thấy domain: $domain"
        fi
    done
else
    echo "Cảnh báo: Không tìm thấy thư mục vhost WPTT"
fi

# Lấy thông tin MySQL từ file dsnvps.txt
if [ -f /tmp/dsnvps.txt ]; then
    MYSQL_USER=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    MYSQL_PASS=$(grep "pass_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    
    if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASS" ]; then
        # Lấy danh sách database không phải system
            echo "-------------------------------------------------------------------------"
        echo "=> Đang backup database từ VPS cũ..."
            echo "-------------------------------------------------------------------------"
        echo "=> Đang lấy danh sách database từ VPS cũ..."
        DBS=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SHOW DATABASES;" 2>/dev/null | grep -Ev "(Database|information_schema|mysql|performance_schema|sys)")
        
        if [ -n "$DBS" ]; then
        database_count=$(echo "$DBS" | wc -l)
            echo "-------------------------------------------------------------------------"
        echo "==> Tìm thấy $database_count database để backup"; sleep 2
        
        # Tạo file danh sách database
        echo "# Danh sách database từ VPS cũ" > /home/dsnvps/database_list.txt
        echo "# Format: old_db_name|old_db_user|old_db_pass" >> /home/dsnvps/database_list.txt
        
        current_db=0
        for db in $DBS; do
            current_db=$((current_db + 1))
            echo "-------------------------------------------------------------------------"
            echo "Backup database ($current_db/$database_count): $db"
            
            # Đếm số tables trong database
            table_count=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null | tail -1)
            
            if [ -n "$table_count" ]; then
                echo "-------------------------------------------------------------------------"
                echo "==> Database $db - Tiến hành backup"; sleep 2
                # Backup từng database với tên file theo format X_tables_database.sql.gz
                if mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASS" \
                    --single-transaction \
                    --routines \
                    --triggers \
                    --lock-tables=false \
                    "$db" 2>/dev/null | gzip > /home/dsnvps/sql/"${table_count}_tables_${db}.sql.gz"; then
                                    echo "-------------------------------------------------------------------------"
                    echo "==> Hoàn thành backup database: $db -> ${table_count}_tables_${db}.sql.gz"
                                    echo "========================================================================="
                    # Ghi thông tin database cũ vào file mapping
                    echo "$db|$MYSQL_USER|$MYSQL_PASS" >> /home/dsnvps/database_list.txt
                fi
            fi
        done
            echo "-------------------------------------------------------------------------"
        echo "==> Đã backup $database_count database từ VPS cũ"; sleep 2
    else
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy database nào trên VPS cũ"
    fi
    
        # Backup toàn bộ để giữ user và privileges
        # mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASS" --all-databases | gzip > /home/dsnvps/dsnvps.sql.gz
    else
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy thông tin MySQL từ file dsnvps.txt"
    fi
else
    echo "-------------------------------------------------------------------------"
    echo "==> Cảnh báo: Không tìm thấy file dsnvps.txt"
fi
EOF

    # Gửi script và file dsnvps.txt lên VPS cũ
    scp -P "$sshport" /tmp/dsnvps-prepare-data.sh root@$vpsipcu:/tmp/ >/dev/null 2>&1
    scp -P "$sshport" /tmp/dsnvps.txt root@$vpsipcu:/tmp/ >/dev/null 2>&1
    ssh -p "$sshport" root@$vpsipcu "TERM=dumb chmod +x /tmp/dsnvps-prepare-data.sh && bash /tmp/dsnvps-prepare-data.sh" 2>/dev/null

    # Tải dữ liệu về VPS mới
    mkdir -p /home/dsnvps_restore/sql /tmp/dataolstmp /etc/dsnvps/.tmp
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/domains.txt /home/dsnvps_restore/ 2>/dev/null
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/database_list.txt /home/dsnvps_restore/ 2>/dev/null
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/etc/wptt/.wptt.conf /etc/dsnvps/.tmp/0pp0axbgc 2>/dev/null
    
    # Tải cấu hình vhost từ VPS cũ
    #echo "-------------------------------------------------------------------------"
    #echo "Đang tải cấu hình vhost từ VPS cũ..."; sleep 2
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/etc/wptt/vhost/.??* /tmp/dataolstmp/ 2>/dev/null
    
    # Tải file backup database về VPS mới
        echo "-------------------------------------------------------------------------"
    echo "Đang tải file backup database từ VPS cũ..."; sleep 2
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/sql/ /home/dsnvps_restore/sql/ 2>/dev/null

    # Phục hồi database trước
        echo "-------------------------------------------------------------------------"
    echo "Đang phục hồi database..."; sleep 2

    # Phục hồi database
    total_dbs=$(grep -v "^#" /home/dsnvps_restore/database_list.txt | grep -v "^$" | wc -l)
    current_db=0

    # Tạo file mapping database cũ -> mới với format đẹp
    echo "# Thay thông tin database tương ứng với database mới" > /home/dsnvps_restore/list-database.txt
    echo "# Username - Data_name - Password" >> /home/dsnvps_restore/list-database.txt
    echo "" >> /home/dsnvps_restore/list-database.txt

    mariadbpass=$(get_mariadb_password)

    # Xử lý từng database
    while IFS='|' read -r old_db_name _old_db_user _old_db_pass; do
        # Bỏ qua comment và dòng trống
        [[ "$old_db_name" =~ ^#.*$ ]] && continue
        [[ -z "$old_db_name" ]] && continue
        
        current_db=$((current_db + 1))
        
        # Giữ nguyên tên database cũ cho VPS mới
        db_name="$old_db_name"
        new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
        new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
            echo "-------------------------------------------------------------------------"
        echo "Tạo database ($current_db/$total_dbs): $db_name"
        
        # Tạo database và user mới
        if create_database_and_user "$db_name" "$new_username" "$new_password" "$mariadbpass"; then
            # Phục hồi dữ liệu với kiểm tra số tables
            # Tìm file backup với pattern X_tables_database.sql.gz
            backup_file=$(find /home/dsnvps_restore/sql/ -name "*_tables_${old_db_name}.sql.gz" 2>/dev/null | head -1)
            
            if [ -n "$backup_file" ]; then
                restore_database_from_backup "$backup_file" "$db_name" "$mariadbpass"
            else
                echo "==> Cảnh báo: Không tìm thấy file backup cho database $old_db_name"
            fi
        fi
        
        # Ghi vào file mapping với format đẹp
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
        
        # Ghi vào DBinfo.txt theo chuẩn DSNVPS (giữ nguyên tên)
        write_database_info "$db_name" "$new_username" "$new_password"
        
        sleep 2
    done < /home/dsnvps_restore/database_list.txt

    # Copy website files sau khi phục hồi database
        echo "-------------------------------------------------------------------------"
    echo ""
    echo "Đang copy mã nguồn website..."; sleep 2
    
    # Kiểm tra file domains.txt có tồn tại không
    if [ ! -f /home/dsnvps_restore/domains.txt ]; then
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy file domains.txt"
       # echo "==> Tạo file domains.txt mặc định..."
        echo "" > /home/dsnvps_restore/domains.txt
    fi
    
    total_domains=$(wc -l < /home/dsnvps_restore/domains.txt)
    current_domain=0

    while IFS='|' read -r domain path; do
        domain=$(echo "$domain" | xargs)
        path=$(echo "$path" | xargs)
        if [[ -n "$domain" && -n "$path" ]]; then
            current_domain=$((current_domain + 1))
            echo "-------------------------------------------------------------------------"
            echo "Copy website ($current_domain/$total_domains): $domain"
            
            mkdir -p /home/$domain/public_html
            
            # Sử dụng đường dẫn đúng cho WPTT: $path/html/
            if rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$path/html/" "/home/$domain/public_html/" 2>/dev/null; then
            ## Thiet lap phan quyen ####           
find /home/$domain/public_html -type d -exec chmod 755 {} \;
find /home/$domain/public_html -type f -exec chmod 644 {} \;
chown -R nginx:nginx /home/$domain/public_html
##################
                echo "=> Hoàn thành copy website: $domain"
            else
                echo "Cảnh báo: Không thể copy website $domain"
            fi
        fi
    done < /home/dsnvps_restore/domains.txt

    # Dọn dẹp
    rm -rf /home/dsnvps_restore/sql
    rm -rf /tmp/dataolstmp
    rm -f /tmp/dsnvps-prepare-data.sh
    rm -f /tmp/dsnvps.txt

    clear
    echo "========================================================================="
    echo "HOÀN THÀNH MIGRATION TỪ WPTT"
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
}