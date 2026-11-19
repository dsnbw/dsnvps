#!/bin/bash
# DSNVPS Migration Common Functions
# Chứa các function chung được sử dụng bởi tất cả các file migration

# Function to handle errors
handle_error() {
    local error_msg="$1"
    local exit_code="${2:-1}"
    clear
    echo "========================================================================="
    echo "CÓ LỖI XẢY RA TRONG QUÁ TRÌNH MIGRATION"
    echo "-------------------------------------------------------------------------"
    echo "$error_msg"
    echo "-------------------------------------------------------------------------"
    echo "Nhấn Enter để tiếp tục..."
    read -r
    main_menu
    return $exit_code
}

# Function to check connection to old VPS
check_old_vps_connection() {
    if [ ! -f /etc/dsnvps/vps_cu.info ]; then
        handle_error "Bạn chưa kết nối server hiện tại tới server cũ.
Hãy chạy chức năng [Kết Nối Tới Server Cũ] trước."
    fi

    # Lấy thông tin VPS cũ
    vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

    if [ -z "$vpsipcu" ] || [ -z "$sshport" ]; then
        handle_error "Thông tin VPS cũ không hợp lệ. Hãy kết nối lại."
    fi

    echo "Kiểm tra kết nối tới VPS cũ: $vpsipcu:$sshport"
    if ! ssh -p "$sshport" -o ConnectTimeout=10 root@$vpsipcu "TERM=dumb echo 'OK'" 2>/dev/null; then
        handle_error "Không thể kết nối tới VPS cũ $vpsipcu:$sshport"
    fi

    echo "========================================================================="
    echo "=> Kết nối thành công tới VPS cũ"
    echo "========================================================================="
    return 0
}

# Function to get MariaDB password
get_mariadb_password() {
    if [ -f /root/.my.cnf ]; then
        mariadbpass=$(awk -F= '/password/ {gsub(/ /,"",$2); print $2}' /root/.my.cnf)
    else
        echo "Cảnh báo: Không tìm thấy file /root/.my.cnf"
        mariadbpass=""
    fi
    
    if [ -z "$mariadbpass" ]; then
        handle_error "Không có mật khẩu MariaDB để tạo database"
    fi
    
    echo "$mariadbpass"
}

# Function to check if database exists
database_exists() {
    local db_name="$1"
    local mariadbpass="$2"
    
    if mysql -u root -p"$mariadbpass" -e "USE \`$db_name\`;" 2>/dev/null; then
        return 0  # Database exists
    else
        return 1  # Database does not exist
    fi
}

# Function: Đọc thông tin database từ DBinfo.txt
get_existing_db_info() {
    local db_name="$1"
    local dbinfo_file="/root/DBinfo.txt"
    
    if [ -f "$dbinfo_file" ]; then
        # Tìm thông tin database theo format DSNVPS: Data name: database_name
        local temp_file="/tmp/db_info_$$"
        awk -v db="Data name: ${db_name}" '
            $0 ~ db {
                getline user_line
                getline pass_line
                print user_line
                print pass_line
                exit
            }
        ' "$dbinfo_file" > "$temp_file"
        
        if [ -s "$temp_file" ]; then
            # Xử lý cả hai format: 
            # - Format mới: "Username : value" hoặc "Password : value" (có dấu cách trước dấu hai chấm, Password viết hoa)
            # - Format cũ: "Username: value" hoặc "password: value" (không có dấu cách, password viết thường)
            # Sử dụng pattern linh hoạt để bắt cả hai trường hợp
            local username=$(awk 'NR==1 {gsub(/^[^:]*:[ ]*/, ""); print}' "$temp_file" | sed 's/^ *//;s/ *$//')
            local password=$(awk 'NR==2 {gsub(/^[^:]*:[ ]*/, ""); print}' "$temp_file" | sed 's/^ *//;s/ *$//')
            rm -f "$temp_file"
            
            if [ -n "$username" ] && [ -n "$password" ]; then
                echo "$username|$password"
                return 0
            fi
        fi
        rm -f "$temp_file"
    fi
    return 1
}

# Function to create database and user
create_database_and_user() {
    local db_name="$1"
    local username="$2"
    local password="$3"
    local mariadbpass="$4"
    
    # Tạo database (idempotent)
    if ! timeout 20 mysql -u root -p"$mariadbpass" -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;" 2>/dev/null; then
        echo "==> Cảnh báo: Không thể tạo database $db_name"
        return 1
    fi
    
    # Tạo user (idempotent). Nếu đã tồn tại, cố gắng cập nhật mật khẩu.
    if ! timeout 20 mysql -u root -p"$mariadbpass" -e "CREATE USER IF NOT EXISTS '$username'@'localhost' IDENTIFIED BY '$password';" 2>/dev/null; then
        echo "==> Cảnh báo: Không thể tạo user $username (có thể đã tồn tại). Thử cập nhật mật khẩu."
        timeout 20 mysql -u root -p"$mariadbpass" -e "ALTER USER '$username'@'localhost' IDENTIFIED BY '$password';" 2>/dev/null || true
    fi
    
    # Cấp quyền
    if ! timeout 20 mysql -u root -p"$mariadbpass" -e "GRANT ALL PRIVILEGES ON \`$db_name\`.* TO '$username'@'localhost';" 2>/dev/null; then
        echo "==> Cảnh báo: Không thể cấp quyền cho user $username"
    fi
    
    # Flush privileges
    timeout 10 mysql -u root -p"$mariadbpass" -e "FLUSH PRIVILEGES;" 2>/dev/null || true
    
    return 0
}

# Function to restore database from backup
restore_database_from_backup() {
    local backup_file="$1"
    local db_name="$2"
    local mariadbpass="$3"
    
    if [ ! -f "$backup_file" ]; then
        echo "==> Cảnh báo: Không tìm thấy file backup $backup_file"
        return 1
    fi
    
    # Lấy số tables từ tên file nếu có pattern X_tables_database.sql.gz
    if [[ "$backup_file" =~ _tables_.*\.sql\.gz$ ]]; then
        expected_tables=$(basename "$backup_file" .sql.gz | cut -d'_' -f1)
        [ "${VERBOSE:-0}" = "1" ] && echo "Phục hồi database: $db_name"
        [ "${VERBOSE:-0}" = "1" ] && echo "File backup: $(basename "$backup_file")"
        [ "${VERBOSE:-0}" = "1" ] && echo "Expected tables: $expected_tables"
        [ "${VERBOSE:-0}" = "1" ] && echo "Tạo database: $db_name"
        
        # Tạo database nếu chưa tồn tại
        if ! mysql -u root -p"$mariadbpass" -e "CREATE DATABASE IF NOT EXISTS \`$db_name\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_520_ci;" 2>/dev/null; then
            echo "==> Cảnh báo: Không thể tạo database $db_name"
            return 1
        fi
        [ "${VERBOSE:-0}" = "1" ] && echo "==> Đã tạo database: $db_name"
        [ "${VERBOSE:-0}" = "1" ] && echo "Đang phục hồi dữ liệu cho database: $db_name"
        
        # Phục hồi database theo cách DSNVPS (sử dụng -f flag)
        if ! timeout 300 sh -c 'gunzip < "$0" | mysql -u root -p"$1" -f "$2"' "$backup_file" "$mariadbpass" "$db_name" 2>/dev/null; then
            echo "==> Cảnh báo: Không thể phục hồi database $db_name"
            return 1
        else
            # Kiểm tra số tables sau khi phục hồi
            actual_tables=$(timeout 20 mysql -u root -p"$mariadbpass" -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$db_name';" 2>/dev/null | tail -1)
            if [ "${VERBOSE:-0}" = "1" ]; then
                echo "==> Hoàn thành phục hồi database: $db_name (tables: $actual_tables/$expected_tables)"
            else
                # In gọn một dòng tóm tắt khi không verbose
                echo "=>  Database: $db_name (đã phục hồi $actual_tables tables)"
            fi
            # Xóa file backup sau khi phục hồi thành công
            rm -f "$backup_file"
            return 0
        fi
    else
        echo "==> Cảnh báo: File backup không có pattern X_tables_database.sql.gz"
        return 1
    fi
}

# Function to write database info to DBinfo.txt
write_database_info() {
    local db_name="$1"
    local username="$2"
    local password="$3"
    
    {
        echo "========================================================================="
        echo "Database: $db_name - Duoc tao vao: $(date +%d/%m/%Y)"
        echo "========================================================================="
        echo "Data name: $db_name"
        echo "Username: $username"
        echo "password: $password"
        echo ""
    } >> /root/DBinfo.txt
}

# Function to get database info from DBinfo.txt (theo logic DSNVPS)
get_database_info() {
    local databasename="$1"
    
    if [ ! -f /root/DBinfo.txt ]; then
        echo "ERROR: /root/DBinfo.txt not found"
        return 1
    fi
    
    # Extract username/password info theo logic DSNVPS
    rm -f /etc/dsnvps/.tmp/datanamecheck
    awk -v db="Data name: ${databasename}" '
        $0 ~ db {
            getline user_line
            getline pass_line
            print user_line
            print pass_line
            exit
        }
    ' /root/DBinfo.txt > /etc/dsnvps/.tmp/datanamecheck
    
    if [ ! -s /etc/dsnvps/.tmp/datanamecheck ]; then
        echo "ERROR: Database $databasename not found in DBinfo.txt"
        rm -f /etc/dsnvps/.tmp/datanamecheck
        return 1
    fi
    
    # Xử lý cả hai format: "Username : value" hoặc "Username: value", "Password : value" hoặc "password: value"
    databaseuser=$(awk 'NR==1 {gsub(/^[^:]*:[ ]*/, ""); print}' /etc/dsnvps/.tmp/datanamecheck | sed 's/^ *//;s/ *$//')
    databasepass=$(awk 'NR==2 {gsub(/^[^:]*:[ ]*/, ""); print}' /etc/dsnvps/.tmp/datanamecheck | sed 's/^ *//;s/ *$//')
    
    # Clean up
    rm -f /etc/dsnvps/.tmp/datanamecheck
    
    if [ -z "$databaseuser" ] || [ -z "$databasepass" ]; then
        echo "ERROR: Invalid database info format for $databasename"
        return 1
    fi
    
    echo "$databaseuser|$databasepass"
    return 0
}

# Function to write database mapping
write_database_mapping() {
    local old_db="$1"
    local new_db="$2"
    local username="$3"
    local password="$4"
    
    # Tạo thư mục dsnvps_restore nếu chưa tồn tại
    mkdir -p /home/dsnvps_restore
    
    {
        echo "-------------------------------------------------------------------------"
        echo "Database VPS cũ: $old_db"
        echo "=> Trên VPS mới:"
        echo "Database_name: $new_db"
        echo "Username: $username"
        echo "password: $password"
        echo "-------------------------------------------------------------------------"
    } >> /home/dsnvps_restore/database_mapping.txt
}

# Function to sync website files
sync_website_files() {
    local domain="$1"
    local source_path="$2"
    local sshport="$3"
    local vpsipcu="$4"
    
    echo "Đồng bộ website: $domain"
    mkdir -p "/home/$domain/public_html"
    
    # Kiểm tra nếu là WPTT thì đổi tên từ html thành public_html
    if echo "$source_path" | grep -q "/usr/local/lsws"; then
        # WPTT: Copy từ html và đổi tên thành public_html
        if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$source_path/html" "/home/$domain/public_html/" 2>/dev/null; then
            echo "==> Cảnh báo: Không thể copy website $domain"
            return 1
        else
            echo "=>  Hoàn thành chuyển website: $domain"
            return 0
        fi
    else
        # Các panel khác: Copy từ public_html
        if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$source_path/public_html" "/home/$domain/public_html/" 2>/dev/null; then
            echo "==> Cảnh báo: Không thể copy website $domain"
            return 1
        else
            echo "=>  Hoàn thành copy website: $domain"
            return 0
        fi
    fi
}

# Function to cleanup temporary files
cleanup_temp_files() {
    rm -f /tmp/dsnvps.txt
    rm -f /tmp/valid_websites.txt
    rm -f /tmp/valid_databases.txt
    rm -f /tmp/database_table_count.txt
    rm -f /tmp/DBinfo_old.txt
    rm -f /tmp/datanamecheck_*
    rm -f /tmp/dsnvps-prepare-data.sh
    
    # Xóa thư mục backup database nếu còn file nào
    if [ -d "/home/dsnvps_restore/sql" ]; then
        remaining_files=$(find /home/dsnvps_restore/sql/ -name "*.sql.gz" 2>/dev/null | wc -l)
        if [ $remaining_files -gt 0 ]; then
            rm -f /home/dsnvps_restore/sql/*.sql.gz
        fi
    fi
}

# Function to perform migration from dsnvps.txt file (supports any VPS)
perform_migration_with_dsnvps_txt() {
    echo "Bắt đầu migration từ VPS cũ (sử dụng file dsnvps.txt)..."
    echo "==> Đã tạo file cấu hình từ dsnvps.txt"
    echo "• MySQL User: $mysql_user"
    echo "• MySQL Password: [Ẩn]"
    echo "• Home Folder: $home_folder"
    echo "• Nginx Config: $nginx_conf"
    
    echo "Đang tìm kiếm vhost config trong thư mục: $nginx_conf"
    
    # Tạo thư mục dsnvps_restore nếu chưa tồn tại
    mkdir -p /home/dsnvps_restore
    
    # Kiểm tra home_folder trước
    echo "Đang kiểm tra thư mục home_folder: $home_folder"
    
    # Tạo file tạm để lưu danh sách website hợp lệ
    true > /tmp/valid_websites.txt
    
    # Tìm tất cả domain trong home_folder (trừ LarVPS)
    if ! echo "$home_folder" | grep -q "/home/domaincom"; then
        domains=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb find $home_folder -maxdepth 1 -type d -name '*.com' -o -name '*.net' -o -name '*.org' -o -name '*.vn' 2>/dev/null | xargs -I {} basename {}")
        
        if [ -n "$domains" ]; then
            echo "Đang kiểm tra từng domain trong home_folder..."
            for domain in $domains; do
                # Kiểm tra WPTT (có /usr/local/lsws)
                if echo "$home_folder" | grep -q "/usr/local/lsws"; then
                    # WPTT: kiểm tra thư mục html
                    html_path="$home_folder/$domain/html"
                    dir_exists=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d '$html_path' 2>/dev/null && echo 'yes' || echo 'no'")
                    
                    if [ "$dir_exists" = "yes" ]; then
                        echo "$domain|$home_folder/$domain" >> /tmp/valid_websites.txt
                        echo "==> Tìm thấy website: $domain -> $html_path"
                    fi
                else
                    # Các panel khác: kiểm tra thư mục public_html
                    public_html_path="$home_folder/$domain/public_html"
                    dir_exists=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d '$public_html_path' 2>/dev/null && echo 'yes' || echo 'no'")
                    
                    if [ "$dir_exists" = "yes" ]; then
                        echo "$domain|$home_folder/$domain" >> /tmp/valid_websites.txt
                        echo "===> Tìm thấy website: $domain -> $public_html_path"
                    fi
                fi
            done
        fi
    else
        echo "LarVPS detected"
    fi
    
    # Nếu không tìm thấy domain nào trong home_folder, mới kiểm tra vhost
    if [ ! -s /tmp/valid_websites.txt ]; then
        echo "Không tìm thấy domain trong home_folder, kiểm tra vhost..."
        
        # Tìm tất cả file .conf trong thư mục nginx_conf
        vhost_files=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb find $nginx_conf -name '*.conf' -type f 2>/dev/null")
        
        if [ -z "$vhost_files" ]; then
            handle_error "Không tìm thấy file vhost nào trong thư mục $nginx_conf"
        fi
        
        echo "Đang kiểm tra từng file vhost..."
        
        # Kiểm tra từng file vhost
        for vhost_file in $vhost_files; do
            # Lấy domain name từ tên file
            domain=$(basename "$vhost_file" .conf)
            
            # Bỏ qua file không phải domain (không có dấu chấm)
            if ! echo "$domain" | grep -q '\.'; then
                continue
            fi
            
            # Kiểm tra file có server_name không
            has_server_name=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -q 'server_name' '$vhost_file' 2>/dev/null && echo 'yes' || echo 'no'")
            
            if [ "$has_server_name" = "yes" ]; then
                # Lấy root path từ vhost (hỗ trợ cả root và DocumentRoot)
                root_path=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -E '^\s*(root|DocumentRoot)\s+' '$vhost_file' 2>/dev/null | awk '{print \$2}' | sed 's/;//' | head -1")
                
                # Kiểm tra root path có tồn tại không
                if [ -n "$root_path" ]; then
                    # Kiểm tra thư mục có tồn tại không
                    dir_exists=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d '$root_path' 2>/dev/null && echo 'yes' || echo 'no'")
                    
                    if [ "$dir_exists" = "yes" ]; then
                        # Ghi thông tin vào file tạm
                        echo "$domain|$root_path" >> /tmp/valid_websites.txt
                        echo "===> Tìm thấy website hợp lệ: $domain -> $root_path"
                    fi
                fi
            fi
        done
    fi
    
    # Kiểm tra có website nào hợp lệ không
    if [ ! -s /tmp/valid_websites.txt ]; then
        handle_error "Không tìm thấy website nào có vhost hợp lệ
(vhost phải có server_name và thư mục root tồn tại)"
    fi
    
    # Đếm số website
    website_count=$(wc -l < /tmp/valid_websites.txt)
    echo "===> Tìm thấy $website_count website hợp lệ:"
    while IFS='|' read -r domain root_path; do
        echo "• $domain -> $root_path"
    done < /tmp/valid_websites.txt
    
    echo ""
    echo "Đang tìm kiếm database trên VPS cũ..."
    
    # Lấy danh sách database (trừ system databases)
    all_databases=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '(Database|information_schema|mysql|performance_schema|sys)'")
    
    if [ -z "$all_databases" ]; then
        echo "==> Không tìm thấy database nào trên VPS cũ"
        database_count=0
    else
        echo "Đang chuẩn bị backup tất cả database..."
        
        # Lưu tất cả database vào file để backup
        echo "$all_databases" > /tmp/valid_databases.txt
        
        # Đếm số database
        database_count=$(echo "$all_databases" | wc -l)
        
        echo "==> Tìm thấy $database_count database để backup:"
        while read -r database; do
            if [ -n "$database" ]; then
                echo "• $database"
            fi
        done < <(cat /tmp/valid_databases.txt)
    fi
    
    echo ""
    echo "========================================================================="
    echo "BẮT ĐẦU MIGRATION"
    echo "========================================================================="
    
    # Tạo thư mục lưu trữ
    mkdir -p /home/dsnvps_restore
    mkdir -p /home/dsnvps_restore/websites
    
    # Backup database nếu có
    if [ $database_count -gt 0 ]; then
        echo "Đang backup database từ VPS cũ..."
        echo "Đang lấy danh sách database từ VPS cũ..."
        current_db=0
        
        # Backup database từ danh sách đã lọc
        if [ -f "/tmp/valid_databases.txt" ]; then
            while read -r database; do
                current_db=$((current_db + 1))
                echo "========================================================================="
                echo "Backup database ($current_db/$database_count): $database"; sleep 2
                
                # Đếm số tables trong database
                table_count=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$database';\" 2>/dev/null" | tail -1)
                
                # Đảm bảo table_count là số hợp lệ
                if [[ "$table_count" =~ ^[0-9]+$ ]] && [ "$table_count" -ge 0 ]; then
                echo "========================================================================="
                    echo "==> Database $database - Tiến hành backup (Tables: $table_count)"; sleep 2
                    
                    # Backup database với tên file chứa số tables theo đường dẫn thống nhất trong thư mục theo tên DB
                    mkdir -p "/home/dsnvps.demo/private_html/backup/${database}"
                    if ! timeout 300 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysqldump -u$mysql_user -p$mysql_pass $database 2>/dev/null | gzip" > "/home/dsnvps.demo/private_html/backup/${database}/${table_count}_tables_${database}.sql.gz" 2>/dev/null; then
                        echo "==> Cảnh báo: Không thể backup database $database"
                    else
                        echo "=>  Hoàn thành backup database: $database -> ${table_count}_tables_${database}.sql.gz"; sleep 2
                        echo "========================================================================="
                    fi
                else
                    echo "==> Cảnh báo: Không thể đếm tables cho database $database (table_count: '$table_count')"
                fi
            done < <(cat /tmp/valid_databases.txt)
        fi
    fi
    
    # Copy mã nguồn website
    echo ""
    echo "Đang copy mã nguồn website..."; sleep 2
    current_website=0
    
    while IFS='|' read -r domain root_path; do
        current_website=$((current_website + 1))
        echo "-------------------------------------------------------------------------"
        echo "Copy website ($current_website/$website_count): $domain" ; sleep 2
        echo "Từ: $root_path"
        
        # Tạo thư mục đích
        mkdir -p "/home/$domain/public_html"
        
        # Kiểm tra nếu là WPTT thì đổi tên từ html thành public_html
        if echo "$root_path" | grep -q "/usr/local/lsws"; then
            # WPTT: Copy từ html và đổi tên thành public_html
            if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$root_path/html" "/home/$domain/public_html/" 2>/dev/null; then
                echo "-------------------------------------------------------------------------"
                echo "==> Cảnh báo: Không thể copy website $domain"
            else
                echo "-------------------------------------------------------------------------"
                echo "==> Hoàn thành chuyển website: $domain"
            fi
        else
            # Các panel khác: Copy từ public_html
            if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$root_path/public_html" "/home/$domain/public_html/" 2>/dev/null; then
                echo "-------------------------------------------------------------------------"
                echo "==> Cảnh báo: Không thể copy website $domain"
            else
                echo "-------------------------------------------------------------------------"
                echo "==> Hoàn thành copy website: $domain"; sleep 2
            fi
        fi
    done < /tmp/valid_websites.txt
    
    # Tạo database mới trên VPS mới
    if [ $database_count -gt 0 ]; then
        echo "-------------------------------------------------------------------------"
        echo ""
        echo "Đang tạo database mới trên VPS mới..."; sleep 2
        
        # Lấy mật khẩu MariaDB của VPS mới
        mariadbpass=$(get_mariadb_password)
        
        if [ -n "$mariadbpass" ]; then
            current_db=0
            
            # Tạo database từ danh sách đã lọc
            if [ -f "/tmp/valid_databases.txt" ]; then
                while read -r old_database; do
                    current_db=$((current_db + 1))
                    
                    # Giữ nguyên tên database cũ
                    db_name="$old_database"
                    
                    echo "-------------------------------------------------------------------------"
                    echo "Xử lý database ($current_db/$database_count): $db_name"; sleep 2
                    
                    # Kiểm tra database có trong /root/DBinfo.txt chưa
                    existing_info=$(get_existing_db_info "$db_name")
                    if [ $? -eq 0 ] && [ -n "$existing_info" ]; then
                        # Database đã có trong DBinfo.txt - dùng thông tin cũ, chỉ phục hồi
                        new_username=$(echo "$existing_info" | cut -d'|' -f1)
                        new_password=$(echo "$existing_info" | cut -d'|' -f2)
                        #echo "==> Database $db_name đã có trong DBinfo.txt - sử dụng thông tin cũ: user=$new_username"
                    else
                        # Database chưa có trong DBinfo.txt - tạo mới
                        #echo "==> Database $db_name chưa có trong DBinfo.txt - tạo mới"
                        new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
                        new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
                        
                        # Tạo database và user
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
                        echo "==> Tìm thấy file backup: $(basename "$best_file") (tables=$best_count)"; sleep 2
                        restore_database_from_backup "$best_file" "$db_name" "$mariadbpass"
                    else
                        echo "==> Cảnh báo: Không tìm thấy file backup cho database $db_name"
                        echo "==> Debug: Tìm kiếm pattern *_tables_${db_name}.sql.gz trong /home/dsnvps.demo/private_html/backup/"
                        ls -la /home/dsnvps.demo/private_html/backup/ 2>/dev/null | grep -i "${db_name}" || echo "==> Không tìm thấy file nào chứa tên database $db_name"
                    fi
                    
                    # Luôn ghi vào file mapping
                    {
                        echo "-------------------------------------------------------------------------"
                        echo "Database VPS cũ: $old_database"
                        echo "=> Trên VPS mới:"
                        echo "Database_name: $db_name"
                        echo "Username: $new_username"
                        echo "password: $new_password"
                        echo "-------------------------------------------------------------------------"
                    } >> /home/dsnvps_restore/database_mapping.txt
                    
                    # Chỉ ghi vào DBinfo.txt khi database mới được tạo (chưa có trong DBinfo.txt)
                    existing_info=$(get_existing_db_info "$db_name")
                    if [ $? -ne 0 ] || [ -z "$existing_info" ]; then
                        # Database chưa có trong DBinfo.txt - ghi thông tin mới
                        write_database_info "$db_name" "$new_username" "$new_password"
                        #echo "==> Đã ghi thông tin database mới vào DBinfo.txt"
                    fi
                    
                    sleep 2
                done < /tmp/valid_databases.txt
            fi
        else
            echo "==> Cảnh báo: Không có mật khẩu MariaDB để tạo database"
        fi
    fi
    
    # Dọn dẹp
    cleanup_temp_files
    
    echo ""
    echo "========================================================================="
    echo "==> HOÀN THÀNH MIGRATION"
    echo "========================================================================="
    echo "==> Đã migration thành công:"
    echo "• $website_count website"
    echo "• $database_count database"
    echo "-------------------------------------------------------------------------"
    echo "==> Thông tin chi tiết:"
    echo "• Thông tin database: /root/DBinfo.txt"
    echo "• File mapping database: /home/dsnvps_restore/database_mapping.txt"
    echo "• Mã nguồn website: /home/<domain>/public_html"
    echo "-------------------------------------------------------------------------"
    echo "Lưu ý: Bạn cần tự cấu hình lại vhost cho các website"
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
}

# Function to show migration summary
show_migration_summary() {
    local website_count="$1"
    local database_count="$2"
    local migration_type="$3"
    
    echo ""
    echo "========================================================================="
    if [ "$migration_type" = "DSNVPS" ]; then
        echo "==>HOÀN THÀNH MIGRATION DSNVPS"
        echo "========================================================================="
        echo "==>  Đã migration thành công từ DSNVPS:"
        echo "• $website_count website"
        echo "• $database_count database (giữ nguyên tên và thông tin)"
        echo "-------------------------------------------------------------------------"
        echo "==> Thông tin chi tiết:"
        echo "• Thông tin database: /root/DBinfo.txt"
        echo "• File mapping database: /home/dsnvps_restore/database_mapping.txt"
        echo "• Mã nguồn website: /home/<domain>/public_html"
        echo "-------------------------------------------------------------------------"
        echo "Lưu ý: Database đã được phục hồi giống hệt VPS cũ"
    else
        echo "==> HOÀN THÀNH MIGRATION"
        echo "========================================================================="
        echo "==> Đã migration thành công:"
        echo "• $website_count website"
        echo "• $database_count database"
        echo "-------------------------------------------------------------------------"
        echo "==>  Thông tin chi tiết:"
        echo "• Thông tin database: /root/DBinfo.txt"
        echo "• File mapping database: /home/dsnvps_restore/database_mapping.txt"
        echo "• Mã nguồn website: /home/<domain>/public_html"
        echo "-------------------------------------------------------------------------"
        echo "Lưu ý: Bạn cần tự cấu hình lại vhost cho các website"
    fi
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
}

# Function: Validate DBinfo.txt có đầy đủ thông tin không
validate_dbinfo() {
    local dbinfo_file="/root/DBinfo.txt"
    
    # Kiểm tra file tồn tại và không rỗng
    if [ ! -f "$dbinfo_file" ] || [ ! -s "$dbinfo_file" ]; then
        echo "DBinfo.txt không tồn tại hoặc rỗng"
        return 1
    fi
    
    # Kiểm tra có chứa thông tin database không (ít nhất 1 database)
    local db_count=$(grep -c "^Data_name:" "$dbinfo_file" 2>/dev/null)
    if [ "$db_count" -eq 0 ]; then
        echo "DBinfo.txt không chứa thông tin database nào"
        return 1
    fi
    
    # Kiểm tra format cơ bản (có Data_name, Username, Password)
    local has_data_name=$(grep -c "^Data_name:" "$dbinfo_file" 2>/dev/null)
    local has_username=$(grep -c "^Username:" "$dbinfo_file" 2>/dev/null)
    local has_password=$(grep -c "^Password:" "$dbinfo_file" 2>/dev/null)
    
    if [ "$has_data_name" -eq 0 ] || [ "$has_username" -eq 0 ] || [ "$has_password" -eq 0 ]; then
        echo "DBinfo.txt thiếu thông tin cần thiết (Data_name, Username, Password)"
        return 1
    fi
    
    echo "DBinfo.txt hợp lệ với $db_count database"
    return 0
}

# Function: Restore database với DBinfo.txt (DSNVPS logic)
restore_with_dbinfo() {
    local mariadbpass="$1"
    local backup_dir="$2"
    
    echo "-------------------------------------------------------------------------"
    echo "==> Sử dụng DBinfo.txt để phục hồi database (DSNVPS logic)"
    
    # Lấy danh sách database từ DBinfo.txt
    local db_names=$(grep "^Data_name:" /root/DBinfo.txt | cut -d':' -f2 | tr -d ' ')
    
    if [ -z "$db_names" ]; then
        echo "==> Cảnh báo: Không tìm thấy database nào trong DBinfo.txt"
        return 1
    fi
    
    local db_count=$(echo "$db_names" | wc -l)
    echo "==> Tìm thấy $db_count database trong DBinfo.txt"
    
    local current_db=0
    for db_name in $db_names; do
        current_db=$((current_db + 1))
        echo "Phục hồi database ($current_db/$db_count): $db_name"
        
        # Tìm file backup tương ứng
        local backup_file=$(find "$backup_dir" -name "*_tables_${db_name}.sql.gz" 2>/dev/null | head -1)
        
        if [ -n "$backup_file" ]; then
            # Sử dụng function restore_database_from_backup
            restore_database_from_backup "$backup_file" "$db_name" "$mariadbpass"
        else
            echo "==> Cảnh báo: Không tìm thấy file backup cho database $db_name"
        fi
    done
    
    echo "==> Hoàn thành phục hồi database với DBinfo.txt"
}

# Function: Restore database với fallback logic (LarVPS/WPTT logic)
restore_with_fallback() {
    local mariadbpass="$1"
    local backup_dir="$2"
    local vpsipcu="$3"
    local sshport="$4"
    local mysql_user="$5"
    local mysql_pass="$6"
    
    echo "-------------------------------------------------------------------------"
    echo "==> Sử dụng fallback logic để phục hồi database (LarVPS/WPTT logic)"
    
    # Lấy danh sách database từ VPS cũ
    local all_databases=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '(Database|information_schema|mysql|performance_schema|sys)'")
    
    if [ -z "$all_databases" ]; then
        echo "==> Cảnh báo: Không tìm thấy database nào trên VPS cũ"
        return 1
    fi
    
    local database_count=$(echo "$all_databases" | wc -l)
    echo "==> Tìm thấy $database_count database trên VPS cũ"
    
    # Tạo thư mục dsnvps_restore nếu chưa tồn tại
    mkdir -p /home/dsnvps_restore/sql
    
    # Tạo file mapping database cũ -> mới (giữ nguyên tên)
    echo "# Mapping database cũ -> mới (Fallback mode)" > /home/dsnvps_restore/list-database.txt
    echo "# Format: old_db_name|username|password" >> /home/dsnvps_restore/list-database.txt
    echo "" >> /home/dsnvps_restore/list-database.txt
    
    # Tạo file danh sách database mới (để phân biệt với database cũ)
    echo "# Danh sách database mới tạo (Fallback mode)" > /home/dsnvps_restore/new-databases.txt
    echo "# Các database này cần cập nhật thông tin trong config website" >> /home/dsnvps_restore/new-databases.txt
    echo "" >> /home/dsnvps_restore/new-databases.txt
    
    local current_db=0
    for old_db_name in $all_databases; do
        current_db=$((current_db + 1))
        
        # Giữ nguyên tên database cũ trên VPS mới
        local db_name="$old_db_name"
        local new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
        local new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
        
        echo "Tạo database ($current_db/$database_count): $db_name"
        
        # Tạo database và user mới
        if create_database_and_user "$db_name" "$new_username" "$new_password" "$mariadbpass"; then
            # Tìm file backup tương ứng
            local backup_file=$(find "$backup_dir" -name "*_tables_${old_db_name}.sql.gz" 2>/dev/null | head -1)
            
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
        
        # Ghi vào file danh sách database mới
        echo "Database cũ: $old_db_name" >> /home/dsnvps_restore/new-databases.txt
        echo "Database mới: $db_name" >> /home/dsnvps_restore/new-databases.txt
        echo "Username: $new_username" >> /home/dsnvps_restore/new-databases.txt
        echo "Password: $new_password" >> /home/dsnvps_restore/new-databases.txt
        echo "-------------------------------------------------------------------------" >> /home/dsnvps_restore/new-databases.txt
        
        # Ghi vào DBinfo.txt theo chuẩn DSNVPS
        write_database_info "$db_name" "$new_username" "$new_password"
        
        sleep 2
    done
    
    echo "==> Hoàn thành phục hồi database với fallback logic"
    echo "==> File danh sách database mới: /home/dsnvps_restore/new-databases.txt"
}
