#!/bin/bash
# DSNVPS Migration từ Flashpanel
# Migration từ VPS cũ chạy Flashpanel về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Function: Migration từ Flashpanel (được gọi từ smart_migration)
migrate_from_flashpanel() {
    # Kiểm tra kết nối VPS cũ
    check_old_vps_connection
    
    # Lấy thông tin kết nối
    vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

    if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb [ -d /root/.flashpanel ]" 2>/dev/null; then
        handle_error "VPS cũ KHÔNG chạy Flashpanel"
    fi
    echo "-------------------------------------------------------------------------"
    echo "Bắt đầu migration từ Flashpanel..."
    #echo "-------------------------------------------------------------------------"
    #echo "==> Đã tạo file cấu hình cho Flashpanel"
    #echo "-------------------------------------------------------------------------"
    
    # Lấy thông tin từ file dsnvps.txt
    if [ -f /tmp/dsnvps.txt ]; then
        mysql_user=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
        home_folder=$(grep "home_folder=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
        nginx_conf=$(grep "nginx_conf=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
        
#        echo "• MySQL User: $mysql_user"
 #       echo "• MySQL Password: [Ẩn]"
 #       echo "• Home Folder: $home_folder"
 #       echo "• Nginx Config: $nginx_conf"
    else
        handle_error "Không tìm thấy thông tin MySQL từ file dsnvps.txt"
    fi

    # Tạo script backup trên VPS cũ
    cat <<'EOF' > /tmp/dsnvps-prepare-data.sh
#!/bin/bash
# Script backup dữ liệu từ Flashpanel

mkdir -p /home/dsnvps/sql /home/dsnvps
rm -f /home/dsnvps/domains.txt

# Lấy thông tin MySQL từ file dsnvps.txt
if [ -f /tmp/dsnvps.txt ]; then
    MYSQL_USER=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    MYSQL_PASS=$(grep "pass_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    
    if [ -n "$MYSQL_USER" ] && [ -n "$MYSQL_PASS" ]; then
        # Lấy danh sách database không phải system
            echo "-------------------------------------------------------------------------"
        echo "=> Đang backup database từ VPS cũ..."; sleep 2
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
            echo "========================================================================="
            echo "Backup database ($current_db/$database_count): $db"
            
            # Đếm số tables trong database
            table_count=$(mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db';" 2>/dev/null | tail -1)
            
            # Đảm bảo table_count là số hợp lệ
            if [[ "$table_count" =~ ^[0-9]+$ ]] && [ "$table_count" -ge 0 ]; then
                echo "-------------------------------------------------------------------------"
                echo "==> Database $db - Tiến hành backup (Tables: $table_count)"
                # Backup từng database với tên file theo format X_tables_database.sql.gz vào thư mục theo tên DB
                mkdir -p /home/dsnvps/sql/"$db"
                if mysqldump -u"$MYSQL_USER" -p"$MYSQL_PASS" \
                    --single-transaction \
                    --routines \
                    --triggers \
                    --lock-tables=false \
                    "$db" 2>/dev/null | gzip > /home/dsnvps/sql/"$db"/"${table_count}_tables_${db}.sql.gz"; then
                                    echo "-------------------------------------------------------------------------"
                    echo "==> Hoàn thành backup database: $db -> ${table_count}_tables_${db}.sql.gz"
                                    echo "========================================================================="
                    # Ghi thông tin database cũ vào file mapping
                    echo "$db|$MYSQL_USER|$MYSQL_PASS" >> /home/dsnvps/database_list.txt
                else
                    echo "==> Cảnh báo: Không thể backup database $db"
                fi
            else
                echo "==> Cảnh báo: Không thể đếm tables cho database $db (table_count: '$table_count')"
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

# Tìm domain từ thư mục Flashpanel
echo "Đang tạo danh sách domain..."
FLASHPANEL_DIR="/home/flashpanel"

if [ -d "$FLASHPANEL_DIR" ]; then
    for domain_dir in "$FLASHPANEL_DIR"/*; do
        [ -d "$domain_dir" ] || continue
        
        # Lấy tên domain từ đường dẫn
        domain=$(basename "$domain_dir")
        
        # Kiểm tra domain có chứa ít nhất 1 dấu chấm
        if [[ "$domain" =~ \. ]]; then
            echo "$domain | $domain_dir" >> /home/dsnvps/domains.txt
            echo "Tìm thấy domain: $domain"
        fi
    done
else
    echo "Cảnh báo: Không tìm thấy thư mục Flashpanel"
fi

echo "Hoàn thành backup dữ liệu"
EOF

    # Gửi script và file dsnvps.txt lên VPS cũ
    scp -P "$sshport" /tmp/dsnvps-prepare-data.sh root@$vpsipcu:/tmp/ >/dev/null 2>&1
    scp -P "$sshport" /tmp/dsnvps.txt root@$vpsipcu:/tmp/ >/dev/null 2>&1
    ssh -p "$sshport" root@$vpsipcu "TERM=dumb chmod +x /tmp/dsnvps-prepare-data.sh && bash /tmp/dsnvps-prepare-data.sh" 2>/dev/null

    # Tải dữ liệu về VPS mới
    mkdir -p /home/dsnvps_restore /tmp/dataolstmp /etc/dsnvps/.tmp
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/domains.txt /home/dsnvps_restore/ 2>/dev/null
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/database_list.txt /home/dsnvps_restore/ 2>/dev/null
    
    # Tải file backup database về VPS mới theo đường dẫn thống nhất
        echo "-------------------------------------------------------------------------"
    echo "Đang tải file backup database từ VPS cũ..."
    rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps/sql/ /home/dsnvps.demo/private_html/backup/ 2>/dev/null

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
        
        # Giữ nguyên tên database cũ
        db_name="$old_db_name"
            echo "-------------------------------------------------------------------------"
        echo "Xử lý database ($current_db/$total_dbs): $db_name"
        
        # Kiểm tra database có trong /root/DBinfo.txt chưa
        existing_info=$(get_existing_db_info "$db_name")
        if [ $? -eq 0 ] && [ -n "$existing_info" ]; then
            # Database đã có trong DBinfo.txt - dùng thông tin cũ, chỉ phục hồi
            new_username=$(echo "$existing_info" | cut -d'|' -f1)
            new_password=$(echo "$existing_info" | cut -d'|' -f2)
            echo "==> Database $db_name đã có trong DBinfo.txt - sử dụng thông tin cũ: user=$new_username"
        else
            # Database chưa có trong DBinfo.txt - tạo mới
            echo "==> Database $db_name chưa có trong DBinfo.txt - tạo mới"
            new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
            new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
            
            # Tạo database và user mới
            if ! create_database_and_user "$db_name" "$new_username" "$new_password" "$mariadbpass"; then
                echo "==> Cảnh báo: Không thể tạo database $db_name"
                continue
            fi
        fi
        
        # Phục hồi dữ liệu: chọn file backup có số tables lớn nhất trong thư mục theo tên DB
        best_file=""
        best_count=-1
        for f in /home/dsnvps.demo/private_html/backup/"${db_name}"/*_tables_${db_name}.sql.gz; do
            [ -e "$f" ] || continue
            base=$(basename "$f")
            count_part=${base%%_tables_*}
            if [[ "$count_part" =~ ^[0-9]+$ ]]; then
                if [ "$count_part" -gt "$best_count" ]; then
                    best_count=$count_part
                    best_file="$f"
                fi
            fi
        done
        if [ -n "$best_file" ]; then
            echo "==> Tìm thấy file backup: $(basename "$best_file") (tables=$best_count)"
            restore_database_from_backup "$best_file" "$db_name" "$mariadbpass"
        else
            echo "==> Cảnh báo: Không tìm thấy file backup cho database $db_name"
            echo "==> Debug: Tìm kiếm pattern *_tables_${db_name}.sql.gz trong /home/dsnvps.demo/private_html/backup/"
            ls -la /home/dsnvps.demo/private_html/backup/ 2>/dev/null | grep -i "${db_name}" || echo "==> Không tìm thấy file nào chứa tên database $db_name"
        fi
        
        # Luôn ghi vào file mapping
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
        
        # Chỉ ghi vào DBinfo.txt khi database mới được tạo (chưa có trong DBinfo.txt)
        existing_info=$(get_existing_db_info "$db_name")
        if [ $? -ne 0 ] || [ -z "$existing_info" ]; then
            # Database chưa có trong DBinfo.txt - ghi thông tin mới
            write_database_info "$db_name" "$new_username" "$new_password"
            #echo "==> Đã ghi thông tin database mới vào DBinfo.txt"
        fi
        
        sleep 2
    done < /home/dsnvps_restore/database_list.txt

    # Copy website files sau khi phục hồi database
        echo "-------------------------------------------------------------------------"
    echo ""
    echo "Đang copy mã nguồn website..."
    
    # Kiểm tra file domains.txt có tồn tại không
    if [ ! -f /home/dsnvps_restore/domains.txt ]; then
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy file domains.txt"
        echo "==> Tạo file domains.txt mặc định..."
        echo "" > /home/dsnvps_restore/domains.txt
    fi
    
    total_domains=$(wc -l < /home/dsnvps_restore/domains.txt)
    current_domain=0

    # Kiểm tra nếu không có domain nào
    if [ "$total_domains" -eq 0 ] || [ ! -s /home/dsnvps_restore/domains.txt ]; then
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy domain nào trên VPS cũ"
        echo "==> Không cần chuyển website"
    else
        while IFS='|' read -r domain path; do
            domain=$(echo "$domain" | xargs)
            path=$(echo "$path" | xargs)
            if [[ -n "$domain" && -n "$path" ]]; then
                current_domain=$((current_domain + 1))
                echo "-------------------------------------------------------------------------"
                echo "Copy website ($current_domain/$total_domains): $domain"; sleep 2
                
                mkdir -p /home/$domain/public_html
                
                # Flashpanel: $path đã là thư mục root, không cần thêm /html/
                if rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$path/" "/home/$domain/public_html/" 2>/dev/null; then
                ## Thiet lap phan quyen ####           
find /home/$domain/public_html -type d -exec chmod 755 {} \;
find /home/$domain/public_html -type f -exec chmod 644 {} \;
chown -R nginx:nginx /home/$domain/public_html
##################
                    echo "==> Hoàn thành copy website: $domain"
                else
                    echo "==> Cảnh báo: Không thể copy website $domain"
                fi
            fi
        done < /home/dsnvps_restore/domains.txt
    fi

    # Dọn dẹp
    rm -rf /home/dsnvps_restore/sql
    rm -rf /tmp/dataolstmp
    rm -f /tmp/dsnvps-prepare-data.sh
    rm -f /tmp/dsnvps.txt

    clear
    echo "========================================================================="
    echo "HOÀN THÀNH MIGRATION TỪ FLASHPANEL"
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
