#!/bin/bash
# DSNVPS Migration từ ECHBAY-DSNVPS
# Migration từ VPS cũ chạy ECHBAY-DSNVPS về VPS mới chạy DSNVPS

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Mức log: đặt VERBOSE=1 để xem chi tiết
: "${VERBOSE:=0}"

# Tự kiểm tra: in toàn bộ mapping từ /root/DBinfo.txt.backup
run_test_dbinfo() {
	local info_file="/root/DBinfo.txt.backup"
	if [ ! -f "$info_file" ]; then
		echo "Không tìm thấy $info_file"
		return 1
	fi
	awk '
		BEGIN{print "# old_database_name|username|password"}
		/^Database:/ {
			split($0, a, / - Created on:/);
			split(a[1], t, /[[:space:]]+/);
			# t[1]=Database:, t[2]=db, t[3]=user, t[4]=pass
			if (t[2] && t[3] && t[4]) {
				print t[2] "|" t[3] "|" t[4]
			}
		}
	' "$info_file"
}

# Hàm parse DBinfo theo định dạng ECHBAY-DSNVPS (đọc từ /root/DBinfo.txt.backup)
# Input: tên database
# Output: in ra "username|password" nếu tìm thấy, exit 0; ngược lại exit 1
get_old_database_info() {
    local target_db="$1"
    local info_file="/root/DBinfo.txt.backup"

    # Chuẩn hóa tên database (loại bỏ CR, trim khoảng trắng)
    target_db=$(printf "%s" "$target_db" | tr -d '\r' | sed -E 's/^[ \t]+|[ \t]+$//g')

    [ -z "$target_db" ] && return 1
    [ ! -f "$info_file" ] && return 1

    # Dùng awk: xoá phần " - Created on:...", so khớp: $1=Database:, $2=db, $3=user, $4=pass
    # Bền vững với khoảng trắng và tab
    local result
    result=$(tr -d '\r' < "$info_file" | tr '\302\240' ' ' | awk -v db="$target_db" '
        {
            line=$0
            sub(/ - Created on:.*/, "", line)
            # Chuẩn hoá khoảng trắng: chuyển tab thành space và nén nhiều space
            gsub(/[\t]+/, " ", line)
            gsub(/  +/, " ", line)
            sub(/^ +/, "", line)
            # Trích xuất theo regex mạnh để bắt 3 trường đầu sau "Database:"
            if (match(line, /^Database:[ ]+([^ ]+)[ ]+([^ ]+)[ ]+([^ ]+)/, m)) {
                if (m[1]==db && m[2]!="" && m[3] != "") { print m[2] "|" m[3]; exit }
            }
        }
    ')

    if [ -n "$result" ]; then
        printf "%s\n" "$result"
        return 0
    fi

    return 1
}

# Function: Migration từ ECHBAY-DSNVPS (giữ nguyên DB info)
migrate_from_echbay_dsnvps() {
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

    # ECHBAY-DSNVPS đã được xác nhận trong smart_migration, không cần kiểm tra lại
    echo "-------------------------------------------------------------------------"
    echo "Bắt đầu chuyển dữ liệu từ ECHBAY-DSNVPS..."; sleep 2
    
    # Copy DBinfo.txt từ VPS cũ
    echo "Đang copy thông tin database từ VPS cũ..."
    if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:/home/DBinfo.txt /root/DBinfo.txt.backup 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không thể copy DBinfo.txt từ VPS cũ"
    fi

    if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /home/dsnvps.conf" 2>/dev/null; then
        handle_error "File /home/dsnvps.conf không tồn tại trên VPS cũ $vpsipcu"
    fi

    if ! scp -P "$sshport" root@$vpsipcu:/home/dsnvps.conf /tmp/dsnvps.txt 2>/dev/null; then
        handle_error "Không thể copy file /home/dsnvps.conf từ VPS cũ $vpsipcu"
    fi

    # Debug: In nội dung file /tmp/dsnvps.txt
    #echo "-------------------------------------------------------------------------"
    #echo "Nội dung file /tmp/dsnvps.txt:"
    #z  cat /tmp/dsnvps.txt || echo "Không thể đọc file /tmp/dsnvps.txt"
    #echo "-------------------------------------------------------------------------"

    # Lấy mật khẩu MariaDB từ VPS cũ
    if [ -f /tmp/dsnvps.txt ]; then
        mysql_user="root"
        mysql_pass=$(awk -F'=' '/mariadbpass=/ {gsub(/"/, "", $2); print $2}' /tmp/dsnvps.txt)
        if [ -z "$mysql_pass" ]; then
            handle_error "Không thể lấy mật khẩu MySQL từ file /tmp/dsnvps.txt. Vui lòng kiểm tra dòng mariadbpass= trong /home/dsnvps.conf trên VPS cũ."
        fi
     #   echo "==> Đã lấy thông tin MySQL: user=$mysql_user, password=[Ẩn]"
    else
        handle_error "Không tìm thấy file /tmp/dsnvps.txt. Vui lòng kiểm tra file /home/dsnvps.conf trên VPS cũ."
    fi
    
    # Kiểm tra kết nối MySQL trên VPS cũ
    #echo "-------------------------------------------------------------------------"
    #echo "Đang kiểm tra kết nối MySQL trên VPS cũ..."
    mysql_check=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e 'SELECT 1;' 2>&1" 2>/dev/null)
    mysql_exit_code=$?
    
    if [ $mysql_exit_code -eq 124 ]; then
        handle_error "Kết nối MySQL bị timeout (quá 60 giây). Vui lòng kiểm tra MySQL trên VPS cũ."
    elif [ $mysql_exit_code -ne 0 ]; then
        handle_error "Không thể kết nối MySQL trên VPS cũ. Vui lòng kiểm tra user root và mật khẩu trong /home/dsnvps.conf. Lỗi: $mysql_check"
    fi
    echo "==> Kết nối MySQL thành công"; sleep 2

    # Lấy danh sách database từ VPS cũ
    echo "-------------------------------------------------------------------------"
    echo "Đang lấy danh sách database từ VPS cũ..."; sleep 2
    all_databases=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e 'SHOW DATABASES;' 2>/dev/null | grep -Ev '(Database|information_schema|mysql|performance_schema|sys)'")
    
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
            echo "==> Backup database ($current_db/$database_count): $database"; sleep 2
            
            # Đếm số tables trong database
            table_count=$(timeout 60 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p'$mysql_pass' -e \"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$database';\" 2>/dev/null" | tail -1)
            
            if [ -z "$table_count" ]; then
                echo "----> Lỗi"
                continue
            fi
            echo "-------------------------------------------------------------------------"
            echo "Database $database - Tiến hành backup"
            
            # Backup database trực tiếp vào thư mục backup trên VPS CŨ theo cấu trúc /backup/<db>/<file>
            backup_dir="/home/dsnvps.demo/private_html/backup/$database"
            ssh -p "$sshport" root@$vpsipcu "TERM=dumb mkdir -p '$backup_dir'" 2>/dev/null || true
            backup_filename="${table_count}_tables_${database}.sql.gz"
            if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysqldump -u$mysql_user -p'$mysql_pass' $database 2>/dev/null | gzip > '$backup_dir/$backup_filename'" 2>/dev/null; then
                echo "-------------------------------------------------------------------------"
                echo "==> Cảnh báo: Không thể backup database $database"
                echo "========================================================================="
            else
                echo "-------------------------------------------------------------------------"
                echo "==> Hoàn thành backup database: $database -> $backup_filename"; sleep 2
                echo "========================================================================="
            fi
        done
        
        echo "==> Đã backup $database_count database trên VPS cũ"

        # Đồng bộ toàn bộ backup tree từ VPS cũ sang VPS mới, giữ nguyên cấu trúc /backup/<db>/<file>
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

    # Phục hồi database theo logic mới
    echo "-------------------------------------------------------------------------"
    echo "Đang phục hồi database từ VPS cũ..."
    
    # Lấy mật khẩu MariaDB của VPS mới
    mariadbpass=$(get_mariadb_password)
    
    if [ -z "$mariadbpass" ]; then
        handle_error "Không có mật khẩu MariaDB để phục hồi database"
    fi
    
    #echo "=> Đã lấy mật khẩu MariaDB"
    
    # Tạo danh sách database từ VPS cũ (đã có từ phần backup)
    if [ -n "$all_databases" ]; then
        database_count=$(echo "$all_databases" | wc -l)
        echo "-------------------------------------------------------------------------"
        echo "==> Tìm thấy $database_count database để phục hồi"; sleep 2
        
        # Khởi tạo biến theo dõi database tạo mới
        new_databases=""
        existing_databases=""

        # Chuẩn bị file mapping đầy đủ (cũ và mới)
        list_file="/home/dsnvps_restore/list-database.txt"
        mkdir -p "/home/dsnvps_restore"
        {
            echo "# Danh sách database tạo (cũ hoặc mới) - cần cập nhật trong config"
            echo "-------------------------------------------------------------------------"
            echo "  website nếu cần"
            echo ""
        } > "$list_file"
        
        current_db=0
        for database in $all_databases; do
            # Chuẩn hóa tên database trước khi xử lý
            database=$(printf "%s" "$database" | tr -d '\r' | sed -E 's/^[ \t]+|[ \t]+$//g')
            current_db=$((current_db + 1))
            echo "-------------------------------------------------------------------------"
            echo "Phục hồi database ($current_db/$database_count): $database"
            
            # Kiểm tra database đã tồn tại chưa
            if database_exists "$database" "$mariadbpass"; then
                echo "==> Database $database đã tồn tại - chỉ phục hồi dữ liệu"
                # Phục hồi dữ liệu từ thư mục /backup/<db>/
                backup_dir="/home/dsnvps.demo/private_html/backup/$database"
                backup_file=$(ls -1 "$backup_dir"/*_tables_"${database}".sql.gz 2>/dev/null | head -n 1)
                if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
                    restore_database_from_backup "$backup_file" "$database" "$mariadbpass"
                else
                    echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
                fi
            else
                # Database chưa tồn tại - kiểm tra có trong DBinfo.txt.backup không
                db_info=$(get_old_database_info "$database" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$db_info" ]; then
                    # Database có trong DBinfo.txt.backup - sử dụng thông tin cũ
                    [ "$VERBOSE" = "1" ] && echo "==> Database $database có trong DBinfo.txt.backup - sử dụng thông tin cũ"
                    username=$(echo "$db_info" | cut -d'|' -f1)
                    password=$(echo "$db_info" | cut -d'|' -f2)
                    
                    # Tạo database với thông tin cũ
                    if create_database_and_user "$database" "$username" "$password" "$mariadbpass"; then
                        [ "$VERBOSE" = "1" ] && echo "==> Đã tạo database $database với thông tin cũ"
                        existing_databases="$existing_databases $database"
                        
                        # Phục hồi dữ liệu từ thư mục /backup/<db>/
                        backup_dir="/home/dsnvps.demo/private_html/backup/$database"
                        backup_file=$(ls -1 "$backup_dir"/*_tables_"${database}".sql.gz 2>/dev/null | head -n 1)
                        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
                            restore_database_from_backup "$backup_file" "$database" "$mariadbpass"
                        else
                            echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
                        fi
                        # Ghi vào mapping (giữ nguyên)
                        
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
            
                        
                     #   printf "%s|%s|%s|%s\n" "$database" "$database" "$username" "$password" >> "$list_file"
                    else
                        echo "==> Cảnh báo: Không thể tạo database $database"
                    fi
                else
                    # Database không có trong DBinfo.txt.backup - tạo mới username/password nhưng giữ nguyên tên
                    #echo "==> Database $database không có trong DBinfo.txt.backup - tạo mới username/password"
                    # Debug: xác nhận không có trong file backup
                    if ! grep -q "^Database: \s*${database}[[:space:]]" /root/DBinfo.txt.backup 2>/dev/null; then
                        echo "    (Debug) Không tìm thấy dòng bắt đầu bằng: Database: ${database} ... trong /root/DBinfo.txt.backup"
                    fi
                    
                    # Tạo username và password mới (giữ nguyên tên database)
                    new_username=$(tr -dc a-z0-9 </dev/urandom | head -c 10)
                    new_password=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 32)
                    
                    # Tạo database với tên cũ nhưng username/password mới
                    if create_database_and_user "$database" "$new_username" "$new_password" "$mariadbpass"; then
                        [ "$VERBOSE" = "1" ] && echo "==> Đã tạo database $database với username/password mới"
                        new_databases="$new_databases $database"
                        
                        # Phục hồi dữ liệu từ thư mục /backup/<db>/
                        backup_dir="/home/dsnvps.demo/private_html/backup/$database"
                        backup_file=$(ls -1 "$backup_dir"/*_tables_"${database}".sql.gz 2>/dev/null | head -n 1)
                        if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
                            restore_database_from_backup "$backup_file" "$database" "$mariadbpass"
                        else
                            echo "==> Cảnh báo: Không tìm thấy file backup cho database $database"
                        fi
                        
                        # Ghi thông tin database mới vào DBinfo.txt theo format DSNVPS
                        write_database_info "$database" "$new_username" "$new_password"
                        
                        #echo "==> Đã ghi thông tin database mới vào DBinfo.txt"
                        # Ghi vào mapping (mới)
                       # printf "%s|%s|%s|%s\n" "$database" "$database" "$new_username" "$new_password" >> "$list_file"
                    else
                        echo "==> Cảnh báo: Không thể tạo database mới cho $database"
                    fi
                fi
            fi
            
            sleep 2
        done
        
        echo "-------------------------------------------------------------------------"
        echo "==> Hoàn thành phục hồi $database_count database"; sleep 2
        
        # Đã tạo file danh sách đầy đủ tại $list_file
        echo "==> Đã tạo file danh sách database: $list_file"
    else
        echo "-------------------------------------------------------------------------"
        echo "==> Cảnh báo: Không tìm thấy database nào để phục hồi"
    fi

    # Copy website files
    echo "-------------------------------------------------------------------------"
    echo "==> Đang copy mã nguồn website từ VPS cũ..."; sleep 2
    
    # Tìm các domain có vhost trong /etc/nginx/conf.d/
    vhost_files=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb find /etc/nginx/conf.d -name '*.conf' -type f 2>/dev/null")
    
    if [ -n "$vhost_files" ]; then
        for vhost_file in $vhost_files; do
            # Lấy domain name từ tên file
            domain=$(basename "$vhost_file" .conf)
            
            # Bỏ qua file không phải domain (không có dấu chấm) và dsnvps.demo
            if ! echo "$domain" | grep -q '\.' || [ "$domain" = "dsnvps.demo" ]; then
                continue
            fi
            
            # Kiểm tra file có server_name không
            has_server_name=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -q 'server_name' '$vhost_file' 2>/dev/null && echo 'yes' || echo 'no'")
            
            if [ "$has_server_name" = "yes" ]; then
                # Lấy root path từ vhost
                root_path=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb grep -E '^\s*root\s+' '$vhost_file' 2>/dev/null | awk '{print \$2}' | sed 's/;//' | head -1")
                
                # Kiểm tra root path có tồn tại không
                if [ -n "$root_path" ]; then
                    # Kiểm tra thư mục có tồn tại không
                    dir_exists=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d '$root_path' 2>/dev/null && echo 'yes' || echo 'no'")
                    
                    if [ "$dir_exists" = "yes" ]; then
                        echo "Copy website: $domain"
                        
                        # Tạo thư mục đích
                        mkdir -p "/home/$domain/public_html"
                        
                        # Copy từ root_path (ECHBAY-DSNVPS: root_path đã là /home/domain/public_html)
                        if ! rsync -avz --no-owner --no-group --info=name1 -e "ssh -p $sshport" root@$vpsipcu:"$root_path/" "/home/$domain/public_html/" 2>/dev/null; then
                            echo "==> Cảnh báo: Không thể copy website $domain"
                        else
                        ## Thiet lap phan quyen ####           
find /home/$domain/public_html -type d -exec chmod 755 {} \;
find /home/$domain/public_html -type f -exec chmod 644 {} \;
chown -R nginx:nginx /home/$domain/public_html
##################
                            echo "==> Hoàn thành copy website: $domain"
                        fi
                    fi
                fi
            fi
        done
    else
        echo "⚠️ Cảnh báo: Không tìm thấy file vhost nào trong /etc/nginx/conf.d/"
    fi

    clear
    echo "========================================================================="
    echo "HOÀN THÀNH CHUYỂN DỮ LIỆU TỪ VPS CŨ ECHBAY-DSNVPS"
    echo "========================================================================="
    echo "==> Đã chuyển dữ liệu thành công:"
    echo "• Database: Đã phục hồi"
    echo "• Backup Database: /home/dsnvps.demo/private_html/backup/"
    echo "• Mã nguồn Website: /home/<domain>/public_html"
    echo "-------------------------------------------------------------------------"
    
    # Hiển thị thông tin database chi tiết
    if [ -n "$existing_databases" ] || [ -n "$new_databases" ]; then
        echo "==> Thông tin chi tiết:"
        
        if [ -n "$existing_databases" ]; then
            echo "Database giữ nguyên thông tin:"
            for db in $existing_databases; do
                db_info=$(get_old_database_info "$db" 2>/dev/null)
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
        
        if [ -n "$new_databases" ]; then
            echo "Database tạo mới (cần cập nhật thông tin trong config website):"
            for db in $new_databases; do
                db_info=$(get_old_database_info "$db" 2>/dev/null)
                if [ $? -eq 0 ] && [ -n "$db_info" ]; then
                    username=$(echo "$db_info" | cut -d'|' -f1)
                    password=$(echo "$db_info" | cut -d'|' -f2)
                    echo "==> Database cũ: $db"
                    echo "Database mới: $db"
                    echo "Username: $username"
                    echo "Password: $password"
                    echo ""
                fi
            done
        fi
        
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
    echo "2. Nếu VPS cũ dùng ECHBAY-DSNVPS thì không cần cấu hình lại Database."
    echo "-------------------------------------------------------------------------"
    echo "3. Nếu Zend Opcache BẬT nên sau khi edit php xong, cần clear Zend Opcache"
    echo "-------------------------------------------------------------------------"
    echo "để file php được cập nhật."
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
}

# Chế độ chạy test theo flag

case "$1" in
    --test-dbinfo)
        run_test_dbinfo
        exit $?
    ;;
    --test-dbinfo-db)
        shift
        dbtest="$1"
        if [ -z "$dbtest" ]; then
            echo "Usage: $0 --test-dbinfo-db <database_name>"
            exit 2
        fi
        if out=$(get_old_database_info "$dbtest"); then
            echo "$dbtest|$out"
            exit 0
        else
            echo "Not found: $dbtest"
            exit 1
        fi
    ;;
esac