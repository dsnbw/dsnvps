#!/bin/bash
# DSNVPS Migration từ DSNVPS
# Migration từ VPS cũ chạy DSNVPS về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Hàm parse DBinfo (bản backup từ VPS cũ) theo định dạng DSNVPS
# Input: tên database
# Output: in ra "username|password" nếu tìm thấy, ngược lại exit 1
get_old_database_info() {
    local target_db="$1"
    local info_file="/root/DBinfo.txt.backup"

    # Chuẩn hoá tên DB
    target_db=$(printf "%s" "$target_db" | tr -d '\r' | sed -E 's/^[ \t]+|[ \t]+$//g')
    [ -z "$target_db" ] && return 1
    [ ! -f "$info_file" ] && return 1

    # Sử dụng logic giống như trong file DSNVPS gốc
    local temp_file="/tmp/datanamecheck_$$"
    awk -v db="Data name: ${target_db}" '
        $0 ~ db {
            getline user_line
            getline pass_line
            print user_line
            print pass_line
            exit
        }
    ' "$info_file" > "$temp_file"

    if [ -s "$temp_file" ]; then
        # Xử lý cả hai format: 
        # - Format mới: "Username : value" hoặc "Password : value" (có dấu cách trước dấu hai chấm, Password viết hoa)
        # - Format cũ: "Username: value" hoặc "password: value" (không có dấu cách, password viết thường)
        local username
        local password
        # Sử dụng pattern linh hoạt để bắt cả hai trường hợp
        username=$(awk 'NR==1 {gsub(/^[^:]*:[ ]*/, ""); print}' "$temp_file" | sed 's/^ *//;s/ *$//')
        password=$(awk 'NR==2 {gsub(/^[^:]*:[ ]*/, ""); print}' "$temp_file" | sed 's/^ *//;s/ *$//')
        
        rm -f "$temp_file"
        
        if [ -n "$username" ] && [ -n "$password" ]; then
            echo "$username|$password"
            return 0
        fi
    fi
    rm -f "$temp_file"
    return 1
}

# Function: Migration từ DSNVPS (giữ nguyên DB info)
migrate_from_dsnvps() {
    # Tạo thư mục dsnvps_restore nếu chưa tồn tại
    mkdir -p /home/dsnvps_restore
    
    # Kiểm tra file cấu hình VPS cũ
    if [ ! -f /etc/dsnvps/vps_cu.info ]; then
        handle_error "Bạn chưa kết nối server hiện tại tới server cũ"
    fi

    # Kiểm tra trạng thái kết nối
    if [ "$(grep "thanhcong" /etc/dsnvps/vps_cu.info | awk '{print $3}')" == "" ]; then
        handle_error "Bạn chưa hoàn thành cấu hình kết nối server hiện tại với server cũ"
    fi

    vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

    # Kiểm tra kết nối
    if ! ssh -p $sshport -o BatchMode=yes -o ConnectTimeout=9 root@$vpsipcu "TERM=dumb echo connected" 2>/dev/null; then
        handle_error "Không thể kết nối tới VPS cũ $vpsipcu:$sshport"
    fi

    # DSNVPS đã được xác nhận trong smart_migration, không cần kiểm tra lại
        echo "-------------------------------------------------------------------------"
    echo "Bắt đầu chuyển dữ liệu từ DSNVPS..."; sleep 2
    
    # Copy DBinfo.txt từ VPS cũ để có thể tái sử dụng Username/password cũ
    #echo "Đang copy thông tin database từ VPS cũ..."
    if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/root/DBinfo.txt /root/DBinfo.txt.backup 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
        #echo "==> Cảnh báo: Không thể copy DBinfo.txt từ VPS cũ"
    else
        echo "-------------------------------------------------------------------------"
       # echo "==> Đã copy DBinfo.txt từ VPS cũ"
    fi


    # Backup database từ VPS cũ trước khi migration
        echo "-------------------------------------------------------------------------"
    echo "Đang backup database từ VPS cũ..."; sleep 2
    
    # Lấy mật khẩu MariaDB từ VPS cũ (từ file dsnvps.conf đã được parse)
    if [ -f /tmp/dsnvps.txt ]; then
        mysql_user=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
        mysql_pass=$(grep "pass_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    else
        handle_error "Không tìm thấy thông tin MySQL từ file dsnvps.txt"
    fi
    
    # Lấy danh sách database từ VPS cũ
  #          echo "-------------------------------------------------------------------------"
 #   echo "Đang lấy danh sách database từ VPS cũ..."
    all_databases=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '(Database|information_schema|mysql|performance_schema|sys)'")
    
    if [ -n "$all_databases" ]; then
        database_count=$(echo "$all_databases" | wc -l)
            echo "-------------------------------------------------------------------------"
        echo "Tìm thấy $database_count database để backup"; sleep 2
        
        # Tạo thư mục backup trên VPS mới
        mkdir -p /home/dsnvps.demo/private_html/backup
        
        current_db=0
        for database in $all_databases; do
            current_db=$((current_db + 1))
            echo "========================================================================="
            echo "Backup database ($current_db/$database_count): $database"
            
            # Đếm số tables trong database
            table_count=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$database';\" 2>/dev/null" | tail -1)
            
            if [ -z "$table_count" ]; then
                echo "⚠️ Cảnh báo: Không thể đếm tables của database $database"
                continue
            fi
                echo "-------------------------------------------------------------------------"
            echo "Database $database - Tiến hành backup";sleep 2    
            
            # Backup database vào thư mục theo tên database
            mkdir -p "/home/dsnvps.demo/private_html/backup/$database"
            backup_filename="${table_count}_tables_${database}.sql.gz"
            if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysqldump -u$mysql_user -p$mysql_pass $database 2>/dev/null | gzip" > "/home/dsnvps.demo/private_html/backup/$database/$backup_filename" 2>/dev/null; then
                echo "-------------------------------------------------------------------------"
                echo "==> Cảnh báo: Không thể backup database $database"
                                echo "========================================================================="
            else
            echo "-------------------------------------------------------------------------"
                echo "==> Hoàn thành backup database: $database -> $backup_filename"; sleep 2
                echo "========================================================================="
            fi
        done
        
        echo "==> Đã backup $database_count database từ VPS cũ"; sleep 2
    else
        echo "==> Cảnh báo: Không tìm thấy database nào trên VPS cũ"
    fi

    # Phục hồi database theo logic mới
    echo "-------------------------------------------------------------------------"
    echo "Đang phục hồi database từ VPS cũ..."; sleep 2
    
    # Lấy mật khẩu MariaDB của VPS mới
    mariadbpass=$(get_mariadb_password)
    
    if [ -z "$mariadbpass" ]; then
        handle_error "Không có mật khẩu MariaDB để phục hồi database"
    fi
    
  #  echo "=> Đã lấy mật khẩu MariaDB"
    
        # Tạo danh sách database từ VPS cũ (đã có từ phần backup)
        if [ -n "$all_databases" ]; then
            database_count=$(echo "$all_databases" | wc -l)
            echo "-------------------------------------------------------------------------"
            echo "==> Tìm thấy $database_count database để phục hồi"; sleep 2
            
            # Tạo file list-database.txt
            list_file="/home/dsnvps_restore/list-database.txt"
            mkdir -p "/home/dsnvps_restore"
            {
                echo "# Danh sách database tạo (giữ nguyên tên)"
                echo "-------------------------------------------------------------------------"
            } > "$list_file"
            
            # Khởi tạo biến theo dõi database
            existing_databases=""
            
            current_db=0
        for database in $all_databases; do
            current_db=$((current_db + 1))
            echo "-------------------------------------------------------------------------"
            echo "Phục hồi database ($current_db/$database_count): $database"; sleep 2
            
            # Kiểm tra database đã tồn tại chưa
            if database_exists "$database" "$mariadbpass"; then
                echo "==> Database $database đã tồn tại - chỉ phục hồi dữ liệu"
                # Phục hồi dữ liệu - tìm file backup có số tables lớn nhất
                backup_dir="/home/dsnvps.demo/private_html/backup/$database"
                best_file=""
                best_count=-1
                for f in "$backup_dir"/*_tables_${database}.sql.gz; do
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
                    restore_database_from_backup "$best_file" "$database" "$mariadbpass"
                else
                    echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
                fi
            else
                # Database chưa tồn tại - tạo mới với logic ưu tiên
                echo "==> Database $database chưa tồn tại - tạo mới"
                
                # Logic ưu tiên: 1) DBinfo.txt hiện tại, 2) DBinfo.txt VPS cũ, 3) Tạo mới
                existing_info=$(get_existing_db_info "$database")
                if [ $? -eq 0 ] && [ -n "$existing_info" ]; then
                    # Có trong DBinfo.txt hiện tại
                    username=$(echo "$existing_info" | cut -d'|' -f1)
                    password=$(echo "$existing_info" | cut -d'|' -f2)
                    echo "==> Sử dụng thông tin từ DBinfo.txt hiện tại"
                else
                    # Thử lấy thông tin từ DBinfo.txt của VPS cũ
                   # echo "==> Đang tìm thông tin database $database trong DBinfo.txt VPS cũ..."
                    if [ -f "/root/DBinfo.txt.backup" ]; then
                        echo "==> Đang tìm kiếm..."
                        db_info=$(get_old_database_info "$database" 2>/dev/null)
                        if [ $? -eq 0 ] && [ -n "$db_info" ]; then
                            username=$(echo "$db_info" | cut -d'|' -f1)
                            password=$(echo "$db_info" | cut -d'|' -f2)
                            echo "==> Tìm thấy thông tin từ DB từ VPS cũ: $username"
                        else
                            echo "==> Không tìm thấy thông tin database $database trong DBinfo.txt VPS cũ"
                            # Fallback: tạo user/pass ngẫu nhiên
                            username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
                            password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
                            echo "==> Tạo username/password mới"
                        fi
                    else
                        echo "==> File DBinfo.txt.backup không tồn tại"
                        # Fallback: tạo user/pass ngẫu nhiên
                        username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
                        password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
                        echo "==> Tạo username/password mới"
                    fi
                fi
                
                # Tạo database với username/password đã xác định
                if create_database_and_user "$database" "$username" "$password" "$mariadbpass"; then
                    echo "==> Đã tạo database $database với username: $username"
                    existing_databases="$existing_databases $database"
                    
                    # Phục hồi dữ liệu - tìm file backup có số tables lớn nhất
                    backup_dir="/home/dsnvps.demo/private_html/backup/$database"
                    best_file=""
                    best_count=-1
                    for f in "$backup_dir"/*_tables_${database}.sql.gz; do
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
                        restore_database_from_backup "$best_file" "$database" "$mariadbpass"
                        
                        # Ghi DBinfo.txt chỉ khi chưa có
                        existing_info=$(get_existing_db_info "$database")
                        if [ $? -ne 0 ] || [ -z "$existing_info" ]; then
                            write_database_info "$database" "$username" "$password"
                            echo "==> Đã ghi thông tin database vào DBinfo.txt"
                        fi
                        
                        # Ghi vào file list-database.txt
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
                        echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
                    fi
                else
                    echo "==> Cảnh báo: Không thể tạo database $database"
                fi
            fi
            
            sleep 2
        done
        
        echo "-------------------------------------------------------------------------"
        echo "==> Hoàn thành phục hồi $database_count database"; sleep 2
        
        # Tất cả database đều sử dụng thông tin từ DBinfo.txt của VPS cũ
    else
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy database nào để phục hồi"
    fi

    # Copy website files - sync toàn bộ /home, loại trừ dsnvps.demo nhưng vẫn sync backup
                echo "-------------------------------------------------------------------------"
    echo "==> Đang sync toàn bộ dữ liệu /home từ VPS cũ..."
    echo "==> Loại trừ /home/dsnvps.demo (trừ /home/dsnvps.demo/private_html/backup)..."
    
    # Sync toàn bộ /home, loại trừ dsnvps.demo
    if ! rsync -avz --exclude='dsnvps.demo' --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/ /home/ 2>/dev/null; then
        echo "⚠️ Cảnh báo: Không thể sync dữ liệu từ /home"
    else
        echo "-------------------------------------------------------------------------"
        echo "==> Đã sync toàn bộ dữ liệu /home từ VPS cũ (trừ dsnvps.demo)"
        
        # Sync riêng /home/dsnvps.demo/private_html/backup
        echo "==> Đang sync /home/dsnvps.demo/private_html/backup..."
        mkdir -p /home/dsnvps.demo/private_html/backup
        if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/dsnvps.demo/private_html/backup/ /home/dsnvps.demo/private_html/backup/ 2>/dev/null; then
            echo "⚠️ Cảnh báo: Không thể sync /home/dsnvps.demo/private_html/backup"
        else
            echo "==> Đã sync /home/dsnvps.demo/private_html/backup"
        fi
        
        # Thiết lập phân quyền cho tất cả các domain (trừ dsnvps.demo)
        echo "==> Đang thiết lập phân quyền..."
        for domain_dir in /home/*/; do
            domain=$(basename "$domain_dir")
            # Bỏ qua dsnvps.demo
            if [ "$domain" = "dsnvps.demo" ]; then
                continue
            fi
            
            # Chỉ thiết lập phân quyền nếu có public_html
            if [ -d "$domain_dir/public_html" ]; then
                find "$domain_dir/public_html" -type d -exec chmod 755 {} \;
                find "$domain_dir/public_html" -type f -exec chmod 644 {} \;
                chown -R nginx:nginx "$domain_dir/public_html"
            fi
        done
        echo "==> Hoàn thành thiết lập phân quyền"; sleep 2
    fi

    clear
    echo "========================================================================="
    echo "HOÀN THÀNH CHUYỂN DỮ LIỆU TỪ VPS CŨ DSNVPS"
    echo "========================================================================="
    echo "==> Đã chuyển dữ liệu thành công:"
    echo "• Database: Đã phục hồi"
    echo "• Backup Database: /home/dsnvps.demo/private_html/backup/"
    echo "• Mã nguồn Website: /home/<domain>/public_html"
    echo "• File danh sách database: /home/dsnvps_restore/list-database.txt"
    echo "-------------------------------------------------------------------------"
    
    # Hiển thị thông tin database chi tiết
    if [ -n "$existing_databases" ]; then
        echo "==> Thông tin chi tiết:"
        
        if [ -n "$existing_databases" ]; then
            echo "Database đã xử lý:"
            for db in $existing_databases; do
                db_info=$(get_database_info "$db" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$db_info" ]; then
                    username=$(echo "$db_info" | cut -d'|' -f1)
                    password=$(echo "$db_info" | cut -d'|' -f2)
                    echo "Database: $db"
                    echo "Username: $username"
                    echo "Password: $password"
                    echo ""
                fi
            done
        fi
        
        
        echo "-------------------------------------------------------------------------"
        echo "==> Thông tin chi tiết:"
        echo "• Thông tin database: /root/DBinfo.txt"
        echo "• File danh sách database: /home/dsnvps_restore/list-database.txt"
        echo "• Mã nguồn website: /home/<domain>/public_html"
        echo "-------------------------------------------------------------------------"
    fi
    echo "Lưu ý: "
    echo "-------------------------------------------------------------------------"
    echo "1. Bạn cần thêm lần lượt các web vào VPS bằng chức năng [ Thêm Website ]"
    echo "-------------------------------------------------------------------------"
    echo "hoặc [Add Website + Config Vhost For Wordpress Cache] để tạo Vhost cho"
    echo "-------------------------------------------------------------------------"
    echo "tất cả website đã được đưa sang."
    echo "-------------------------------------------------------------------------"
    echo "2. Database đã được tạo với thông tin từ DBinfo.txt VPS cũ (nếu có)."
    echo "-------------------------------------------------------------------------"
    echo "3. Nếu Zend Opcache BẬT nên sau khi edit php xong, cần clear Zend Opcache"
    echo "-------------------------------------------------------------------------"
    echo "để file php được cập nhật."
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
}