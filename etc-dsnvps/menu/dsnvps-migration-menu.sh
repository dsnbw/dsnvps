#!/bin/bash
. /root/dsnvps.conf

# Source common functions
. /etc/dsnvps/menu/dsnvps-migration-common.sh

# Source migration scripts
. "/etc/dsnvps/menu/dsnvps-migration-dsnvps.sh"
. "/etc/dsnvps/menu/dsnvps-migration-echbay-dsnvps.sh"
. "/etc/dsnvps/menu/dsnvps-migration-larvps.sh"
. "/etc/dsnvps/menu/dsnvps-migration-wptt.sh"
. "/etc/dsnvps/menu/dsnvps-migration-flashpanel.sh"
. "/etc/dsnvps/menu/dsnvps-migration-centminmod.sh"
. "/etc/dsnvps/menu/dsnvps-migration-hostvn.sh"
. "/etc/dsnvps/menu/dsnvps-migration-dlemp.sh"
. "/etc/dsnvps/menu/dsnvps-migration-hocvps.sh"

# Cấu hình server IP và port (các biến được source từ dsnvps.conf)
# domainquanly, serverip, priport được định nghĩa trong các file cấu hình DSNVPS
if [ -f /etc/dsnvps/domainquanly/domainquanly.conf ]; then
    serverip_priport=$domainquanly  # domainquanly từ domainquanly.conf
else
    serverip_priport="${serverip}:${priport}"  # serverip, priport từ dsnvps.conf
fi

# Anti-debug removed

# Function 1: Kết nối VPS cũ
connect_to_old_vps() {
    echo "========================================================================="
    
    if [ -f /etc/dsnvps/vps_cu.info ]; then
        if [ ! "$(grep "thanhcong" /etc/dsnvps/vps_cu.info | awk '{print $3}')" == "" ]; then
            clear
            echo "========================================================================="
            echo "ĐÃ KẾT NỐI THÀNH CÔNG VỚI VPS CŨ"
            echo "========================================================================="
            echo "==> Thông tin kết nối hiện tại:"
            echo "• IP Server cũ: $(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')"
            echo "• SSH Port: $(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')"
            echo "• Trạng thái: $(grep "ketnoistatus" /etc/dsnvps/vps_cu.info | awk '{print $3}')"
            echo "-------------------------------------------------------------------------"
            echo "==> Bạn có thể thực hiện chức năng sau:"
            echo "• [2] [ Chuyển Dữ Liệu Về VPS Này ]"
            echo "-------------------------------------------------------------------------"
            echo "=> Nếu cần thay đổi VPS cũ, hãy chạy [3] Xóa cấu hình hiện tại"
            echo "========================================================================="
            echo "Nhấn Enter để quay về menu chính..."
            read -r
            main_menu
            return
        fi
    fi
    
    echo "========================================================================="
    echo "Sử dụng chức năng này để kết nối server hiện tại với server cũ. Sau khi "
    echo "-------------------------------------------------------------------------"
    echo "kết nối xong, chạy [ Chuyển Dữ Liệu Về VPS Này ] để bắt đầu quá trình "
    echo "-------------------------------------------------------------------------"
    echo "copy dữ liệu."
    echo "-------------------------------------------------------------------------"
    echo "Panel VPS cũ hỗ trợ tự động cấu hình: DSNVPS, LarVPS, TangTocOLS, HostVN, "
    echo "-------------------------------------------------------------------------"
    echo "DLEMP, HocVPS, Centminmod,ECHBAY-DSNVPS...."
    #echo "-------------------------------------------------------------------------"
   # echo "Nếu Panel chưa hỗ trợ tự động, bạn tự tạo file cấu hình theo hướng dẫn"
    echo "-------------------------------------------------------------------------"
    echo "Hướng dẫn: "
    echo "-------------------------------------------------------------------------"
    echo "Thông tin Server cũ cần nhập: IP và Mật khẩu tài khoản Root và SSH Port."
    echo "========================================================================="
    
    # Nhập IP
    while true; do
        echo -n "Nhập IP Server Cũ [0 -Thoát]: "
        read ipvpscu

        if [ "$ipvpscu" = "0" ]; then
            clear
            main_menu
            exit
        fi

        if [[ ! "$ipvpscu" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "========================================================================="
            echo "$ipvpscu không phải là IP hợp lệ!"
            echo "-------------------------------------------------------------------------"
            echo "Vui lòng nhập lại."
            sleep 4  
            clear
            continue
        fi

        echo "-------------------------------------------------------------------------"
        echo "Đang kiểm tra IP $ipvpscu..."
        if ! ping -c 1 -W 3 "$ipvpscu" > /dev/null 2>&1; then
            echo "========================================================================="
            echo "$ipvpscu không phản hồi."
            echo "-------------------------------------------------------------------------"
            echo "IP này có thể không tồn tại hoặc không truy cập được! Vui lòng nhập lại."
            sleep 3  
            clear
            continue
        fi
        echo "-------------------------------------------------------------------------"
        echo "$ipvpscu có tồn tại"; sleep 2
        sleep 1 && tput cuu 4 && tput ed  
        break
    done

    # Nhập SSH Port
    while true; do
        echo "-------------------------------------------------------------------------"
        echo -n "Nhập SSH Port (Mặc định: 22): "
        read sshport

        if [ -z "$sshport" ]; then
            echo "-------------------------------------------------------------------------"
            echo -n "Port SSH là 22 đúng không? (Y/N): "
            read confirm
            case "$confirm" in
                [Yy]*) 
                    sshport=22
                    break
                    ;;
                [Nn]*)
                    echo "-------------------------------------------------------------------------"
                    echo "Vui lòng nhập lại port SSH."
                    sleep 4; clear
                    ;;
                *) 
                    echo "-------------------------------------------------------------------------"
                    echo "Lựa chọn không hợp lệ, vui lòng nhập Y hoặc N."
                    sleep 4; clear
                    ;;
            esac
        elif [[ "$sshport" =~ ^[0-9]+$ ]] && [ "$sshport" -ge 1 ] && [ "$sshport" -le 65535 ]; then
            break
        else
            echo "-------------------------------------------------------------------------"
            echo "Port không hợp lệ, vui lòng nhập lại (1-65535)."
            sleep 4; clear
        fi
    done
    
    echo "-------------------------------------------------------------------------"
    echo "Port SSH server mới: $sshport"   

    # Nhập password
    while true; do
        echo "-------------------------------------------------------------------------"
        echo -n "Nhập password tài khoản root [0 -Thoát]: "
        read -s passrootvpscu
        echo

        if [ "$passrootvpscu" = "0" ]; then
            clear
            main_menu
            exit
        elif [ -z "$passrootvpscu" ]; then
            echo "-------------------------------------------------------------------------"
            echo "Password không được để trống, vui lòng nhập lại!"
            sleep 4  
            clear
        elif [ ${#passrootvpscu} -lt 6 ]; then
            echo "-------------------------------------------------------------------------"
            echo "Password quá ngắn (tối thiểu 6 ký tự), vui lòng nhập lại!"
            sleep 4  
            clear
        else
            echo "-------------------------------------------------------------------------"
            echo "Đang kiểm tra password..."
            break
        fi
    done

    # Test kết nối
    echo "-------------------------------------------------------------------------"
    echo "Đang kiểm tra kết nối với server cũ..."
    if ! sshpass -p "$passrootvpscu" ssh -p $sshport -o ConnectTimeout=10 -o StrictHostKeyChecking=no root@$ipvpscu "echo 'Kết nối thành công'" 2>/dev/null; then
        clear
        echo "========================================================================="
        echo "Không thể kết nối tới server cũ"
        echo "-------------------------------------------------------------------------"
        echo "Vui lòng kiểm tra lại:"
        echo "- IP address: $ipvpscu"
        echo "- SSH Port: $sshport" 
        echo "- Password root"
        echo "-------------------------------------------------------------------------"
        main_menu
        exit 1
    fi
    echo "-------------------------------------------------------------------------"
    echo "Kết nối thành công! Tiếp tục thiết lập..."

    # Thiết lập SSH key
    if [ -f ~/.ssh/known_hosts ]; then
        grep -q "$ipvpscu" ~/.ssh/known_hosts && sed -i "/$ipvpscu/d" ~/.ssh/known_hosts
    fi
    
    if [ ! -f ~/.ssh/id_rsa.pub ]; then
        if ! ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa -C "dsnvps-$(date +%Y%m%d)" >/dev/null 2>&1; then
            clear
            echo "========================================================================="
            echo "Không thể tạo SSH key"
            echo "-------------------------------------------------------------------------"
            echo "Vui lòng kiểm tra quyền ghi trong thư mục ~/.ssh/"
            main_menu
            exit 1
        fi
    fi
    
    echo "-------------------------------------------------------------------------"
    echo "Đang thiết lập kết nối với $ipvpscu..."
       
    if ! sshpass -p "$passrootvpscu" scp -P $sshport -o StrictHostKeyChecking=no ~/.ssh/id_rsa.pub root@$ipvpscu:/root/temp_key 2>/dev/null; then
        clear
        echo "========================================================================="
        echo "Không thể copy SSH key tới server cũ"
        echo "-------------------------------------------------------------------------"
        echo "Vui lòng kiểm tra lại thông tin kết nối (IP, Port, Password)"
        main_menu
        exit 1
    fi


    if ! sshpass -p "$passrootvpscu" ssh -p $sshport root@$ipvpscu "
        mkdir -p ~/.ssh &&
        touch ~/.ssh/authorized_keys &&
        cat /root/temp_key >> ~/.ssh/authorized_keys &&
        chmod 700 ~/.ssh &&
        chmod 600 ~/.ssh/authorized_keys &&
        rm -f /root/temp_key" 2>/dev/null; then
        clear
        echo "========================================================================="
        echo "Không thể thiết lập SSH key trên server cũ"
        echo "-------------------------------------------------------------------------"
        echo "Vui lòng kiểm tra lại thông tin kết nối"
        main_menu
        exit 1
    fi
    
    checkconnect=$(ssh -p "$sshport" -o BatchMode=yes -o ConnectTimeout=9 root@"$ipvpscu" echo connected 2>/dev/null)

    if [[ "${checkconnect//[$'\t\r\n ']}" != "connected" ]]; then
        clear
        echo "========================================================================="
        echo "Kết nối thất bại"
        echo "-------------------------------------------------------------------------"
        echo "Bạn vui lòng kiểm tra lại thông tin server cũ"
        main_menu
        exit
    fi

    cat > "/etc/dsnvps/vps_cu.info" <<END
ipaddress = $ipvpscu
sshport = $sshport
ketnoistatus = thanhcong
END
        echo "-------------------------------------------------------------------------"
    echo "==> Kết nối thành công tới $ipvpscu:$sshport"
    echo "========================================================================="
    echo "Kết nối thành công!"; sleep 5
    echo "-------------------------------------------------------------------------"
    echo "Đang cài đặt các gói cần thiết trên server cũ: rsync wget tar"
    echo "-------------------------------------------------------------------------"
    # Kiểm tra loại hệ điều hành và cài đặt gói phù hợp
    if ssh root@$ipvpscu "command -v dnf >/dev/null 2>&1" 2>/dev/null; then
        # AlmaLinux/CentOS/RHEL/Fedora
        echo "-------------------------------------------------------------------------"
        echo "Phát hiện hệ điều hành: AlmaLinux/CentOS/RHEL/Fedora"
    if ! ssh root@$ipvpscu "dnf -y install rsync wget tar" 2>/dev/null; then
    echo "-------------------------------------------------------------------------"
            echo "==>  Cảnh báo: Không thể cài đặt gói"
        else
        echo "-------------------------------------------------------------------------"
            echo "==> Đã cài đặt gói thành công"; sleep 3
        fi
    elif ssh root@$ipvpscu "command -v apt >/dev/null 2>&1" 2>/dev/null; then
        # Ubuntu/Debian
        echo "-------------------------------------------------------------------------"
        echo "Phát hiện hệ điều hành: Ubuntu/Debian"
        if ! ssh root@$ipvpscu "apt update && apt -y install rsync wget tar" 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
            echo "==> Cảnh báo: Không thể cài đặt gói"
        else
        echo "-------------------------------------------------------------------------"
            echo "==> Đã cài đặt gói thành công"; sleep 3
        fi
    elif ssh root@$ipvpscu "command -v yum >/dev/null 2>&1" 2>/dev/null; then
        # CentOS 7 hoặc RHEL cũ
        echo "-------------------------------------------------------------------------"
        echo "Phát hiện hệ điều hành: CentOS 7/RHEL cũ"
        if ! ssh root@$ipvpscu "yum -y install rsync wget tar" 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
            echo "==> Cảnh báo: Không thể cài đặt gói"
        else
        echo "-------------------------------------------------------------------------"
            echo "==> Đã cài đặt gói thành công"; sleep 3
        fi
    else
    echo "-------------------------------------------------------------------------"
        echo "==>  Cảnh báo: Không thể xác định loại hệ điều hành"
        echo "Bạn có thể cần cài đặt thủ công: rsync wget tar"
    fi
   clear 
    echo ""
    echo "========================================================================="
    echo "KẾT NỐI THÀNH CÔNG!"
    echo "========================================================================="
    echo "==> Đã kết nối tới server cũ: $ipvpscu:$sshport"
    echo "==> Đã cài đặt các gói cần thiết"
    echo "==> Thông tin kết nối đã được lưu"
    echo "-------------------------------------------------------------------------"
    echo "Bây giờ bạn có thể chạy chức năng [2] [ Chuyển Dữ Liệu Về VPS Này ]"
    echo "-------------------------------------------------------------------------"
    echo "để tự động nhận biết và chuyển dữ liệu từ VPS cũ."
    echo "-------------------------------------------------------------------------"
    echo "Nếu cần thay đổi VPS cũ, hãy chạy chức năng [3] Xóa cấu hình hiện tại"
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
    return
}

# Function 2: Migration thông minh - Tự động nhận biết panel và gọi migration tương ứng
smart_migration() {
    clear
    echo "========================================================================="
    echo "                    CHUYỂN DỮ LIỆU VỀ VPS NÀY"
    echo "========================================================================="
    
    # Tạm thời vô hiệu hóa để test
    if [ -f /home/dsnvps_restore/list-database.txt ]; then
        echo "==> Bạn đã thực hiện download thành công dữ liệu từ VPS cũ!"
        echo ""
        echo "Nếu muốn download lại thì:"
        echo "1. Chọn [3] Xóa Cấu Hình Hiện Tại"
        echo "2. Chọn [1] Kết Nối VPS Cũ"
        echo "3. Chọn [2] Chuyển Dữ Liệu Về VPS Này"
        echo ""
        echo "========================================================================="
        echo "Nhấn Enter để quay về menu chính..."
        read -r
        main_menu
        return
    fi
    
    # Xác nhận đồng ý
    echo "Bạn có chắc chắn muốn chuyển dữ liệu từ VPS cũ về VPS này không?"
    echo ""
    echo "==> Lưu ý: Quá trình này sẽ:"
    echo "• Backup tất cả database trên VPS cũ"
    echo "• Tải tất cả Backup Database từ VPS cũ về VPS này"
    echo "• Tạo database mới trên VPS này nếu VPS cũ không dùng DSNVPS"
    echo "• Phục hồi dữ liệu vào database mới"
    echo "• Nếu VPS cũ sử dụng DSNVPS thì mọi thông tin database trên VPS này"
    echo "  sẽ giống VPS cũ."
    echo "• Copy mã nguồn (code) website từ VPS cũ về VPS này"
    echo "-------------------------------------------------------------------------"
    echo "===> Nếu DSNVPS tạo database và phục hồi thì bạn cần edit file cấu hình"
    echo "-------------------------------------------------------------------------"
    echo "database của website theo thông tin database tương ứng."
    echo "-------------------------------------------------------------------------"
    echo "Sau khi phục hồi database mới thành công, lấy thông tin database để edit" 
    echo "-------------------------------------------------------------------------"
    echo "file cấu hình bằng chức năng số 4 [ Xem Thông Tin Database Mới ]."
    echo "========================================================================="
    read -p "Bạn có đồng ý? (y/N): " confirm
    
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Bạn đã hủy bỏ quá trình chuyển dữ liệu về VPS."
            echo "=========================================================================" 
        echo "Nhấn Enter để quay về menu chính..."
        read -r
        main_menu
        return
    fi
    
    echo "========================================================================="  
    # Kiểm tra file cấu hình VPS cũ
    if [ ! -f /etc/dsnvps/vps_cu.info ]; then
        handle_error "Bạn chưa kết nối VPS hiện tại tới VPS cũ.
-------------------------------------------------------------------------
Hãy chạy chức năng [Kết Nối Tới VPS Cũ] trước."
    fi

    # Lấy thông tin VPS cũ
    vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')

    if [ -z "$vpsipcu" ] || [ -z "$sshport" ]; then
        handle_error "Thông tin VPS cũ không hợp lệ. Hãy kết nối lại."
    fi

    # Kiểm tra kết nối
    if ! ssh -p "$sshport" -o ConnectTimeout=10 root@$vpsipcu "TERM=dumb echo 'Kết nối thành công'" 2>/dev/null; then
        handle_error "Không thể kết nối tới VPS cũ $vpsipcu:$sshport"
    fi
        echo "-------------------------------------------------------------------------"
    echo "Đang kiểm tra loại panel trên VPS cũ..."

    # Kiểm tra DSNVPS trước
    if ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /root/dsnvps.conf" 2>/dev/null; then
            echo "-------------------------------------------------------------------------"
        echo "==> Phát hiện VPS cũ chạy DSNVPS";sleep 4
        
        # Đọc thông tin từ file DSNVPS config
        dsnvps_config=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb cat /root/dsnvps.conf" 2>/dev/null)
        
        if [ -z "$dsnvps_config" ]; then
            handle_error "Không thể đọc file cấu hình DSNVPS từ VPS cũ"
        fi
        
        # Lấy thông tin từ DSNVPS config
        mariadbpass=$(echo "$dsnvps_config" | grep "mariadbpass=" | cut -d'=' -f2 | tr -d '"')
        
        if [ -z "$mariadbpass" ]; then
            handle_error "Không thể lấy thông tin MariaDB password từ file DSNVPS config"
        fi
        
        # Tạo file dsnvps.txt cho DSNVPS
        cat > /tmp/dsnvps.txt << EOF
home_folder=/home
nginx_conf=/etc/nginx/conf.d
user_admin_mysql=root
pass_admin_mysql=$mariadbpass
EOF
   echo "------------------------------------------------------------------------- "    
    #    echo "==> Đã tạo file cấu hình cho DSNVPS"
    #    echo "• MySQL User: root"
    #    echo "• MySQL Password: [Ẩn]"
    #    echo "• Home Folder: /home"
    #    echo "• Nginx Config: /etc/nginx/conf.d"
        
    migrate_from_dsnvps
        
    # Kiểm tra ECHBAY-DSNVPS
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /home/dsnvps.conf" 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
        echo "==> Phát hiện VPS cũ chạy ECHBAY-DSNVPS";sleep 4
        
        # Đọc thông tin từ file ECHBAY-DSNVPS config
        echbay_config=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb cat /home/dsnvps.conf" 2>/dev/null)
        
        if [ -z "$echbay_config" ]; then
            handle_error "Không thể đọc file cấu hình ECHBAY-DSNVPS từ VPS cũ"
        fi
        
        # Lấy thông tin từ ECHBAY-DSNVPS config
        mariadbpass=$(echo "$echbay_config" | grep "mariadbpass=" | cut -d'=' -f2 | tr -d '"')
        
        if [ -z "$mariadbpass" ]; then
            handle_error "Không thể lấy thông tin MariaDB password từ file ECHBAY-DSNVPS config"
        fi
        
        # Tạo file dsnvps.txt cho ECHBAY-DSNVPS
        cat > /tmp/dsnvps.txt << EOF
home_folder=/home
nginx_conf=/etc/nginx/conf.d
user_admin_mysql=root
pass_admin_mysql=$mariadbpass
EOF
        echo "-------------------------------------------------------------------------"
        echo "==> Đã tạo file cấu hình cho ECHBAY-DSNVPS"
        #echo "• MySQL User: root"
        #echo "• MySQL Password: [Ẩn]"
        #echo "• Home Folder: /home"
       # echo "• Nginx Config: /etc/nginx/conf.d"
        
        migrate_from_echbay_dsnvps
        
    # Kiểm tra DLEMP
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /home/dlemp.conf" 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
        echo "==> Phát hiện VPS cũ chạy DLEMP";sleep 4
        migrate_from_dlemp
        
    # Kiểm tra HocVPS
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /etc/hocvps/scripts.conf" 2>/dev/null; then
        echo "-------------------------------------------------------------------------"
        echo "==> Phát hiện VPS cũ chạy HocVPS";sleep 4
        migrate_from_hocvps
        
    # Kiểm tra HostVN
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /var/hostvn/.hostvn.conf" 2>/dev/null; then
echo "------------------------------------------------------------------------- " 
        echo "==> Phát hiện VPS cũ chạy HostVN";sleep 4
        migrate_from_hostvn
        
    # Kiểm tra LarVPS
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /etc/larvps/.larvps" 2>/dev/null; then
echo "------------------------------------------------------------------------- " 
        echo "==> Phát hiện VPS cũ chạy LarVPS";sleep 4
        
        # Đọc thông tin từ file LarVPS config
        larvps_config=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb cat /etc/larvps/.larvps" 2>/dev/null)
        
        if [ -z "$larvps_config" ]; then
            handle_error "Không thể đọc file cấu hình LarVPS từ VPS cũ"
        fi
        
        # Lấy thông tin từ LarVPS config
        mysql_user=$(echo "$larvps_config" | grep "DB_ADMIN_USERNAME=" | cut -d'=' -f2)
        mysql_pass=$(echo "$larvps_config" | grep "DB_ADMIN_PASSWORD=" | cut -d'=' -f2)
        
        if [ -z "$mysql_user" ] || [ -z "$mysql_pass" ]; then
            handle_error "Không thể lấy thông tin MySQL từ file LarVPS config"
        fi
        
        # Tạo file dsnvps.txt cho LarVPS
        cat > /tmp/dsnvps.txt << EOF
home_folder=/home/domaincom
nginx_conf=/etc/nginx/conf.d
user_admin_mysql=$mysql_user
pass_admin_mysql=$mysql_pass
EOF
        migrate_from_larvps
        
    # Kiểm tra WPTT
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /etc/wptt/.wptt.conf" 2>/dev/null; then
    echo "------------------------------------------------------------------------- " 
        echo "==> Phát hiện VPS cũ chạy WPTT";sleep 4

        # Lấy thông tin từ file WPTT config
        wptt_config=$(ssh -p "$sshport" root@$vpsipcu "TERM=dumb cat /etc/wptt/.wptt.conf" 2>/dev/null)
        
        if [ -z "$wptt_config" ]; then
            handle_error "Không thể đọc file cấu hình WPTT từ VPS cũ"
        fi
        
        # Lấy thông tin từ WPTT config
        mysql_user=$(echo "$wptt_config" | grep "database_admin_username=" | cut -d'=' -f2)
        mysql_pass=$(echo "$wptt_config" | grep "database_admin_password=" | cut -d'=' -f2)
        
        if [ -z "$mysql_user" ] || [ -z "$mysql_pass" ]; then
            handle_error "Không thể lấy thông tin MySQL từ file WPTT config"
        fi
        
        # Tạo file dsnvps.txt cho WPTT
        cat > /tmp/dsnvps.txt << EOF
home_folder=/usr/local/lsws
nginx_conf=/usr/local/lsws/conf/vhosts
user_admin_mysql=$mysql_user
pass_admin_mysql=$mysql_pass
EOF
        echo "------------------------------------------------------------------------- "    
        echo "==> Đã tạo file cấu hình cho WPTT";sleep 3
        #echo "• MySQL User: $mysql_user"
        #echo "• MySQL Password: [Ẩn]"
        #echo "• Home Folder: /usr/local/lsws"
        #echo "• Nginx Config: /usr/local/lsws/conf/vhosts"
        
        migrate_from_wptt
        
    # Kiểm tra Flashpanel
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d /root/.flashpanel" 2>/dev/null; then
    echo "------------------------------------------------------------------------- " 
        echo "==> Phát hiện VPS cũ chạy Flashpanel";sleep 4
        
        # Yêu cầu nhập mật khẩu MySQL root
        echo "-------------------------------------------------------------------------"
        echo "VPS cũ sử dụng Flashpanel"
        echo "Cần nhập mật khẩu MySQL root (user: flashpanel)"
        echo "-------------------------------------------------------------------------"
        
        while true; do
            echo -n "Nhập mật khẩu MySQL root (hoặc nhấn 0 để thoát): "
            read -s mysql_password
            echo ""
            
            if [ "$mysql_password" = "0" ]; then
                echo "Đã hủy migration"
                main_menu
                return
            fi
            
            # Test kết nối MySQL
            echo "Đang kiểm tra kết nối MySQL..."
            if ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u flashpanel -p'$mysql_password' -e 'SELECT 1;' 2>/dev/null" 2>/dev/null; then
                echo "==> Kết nối MySQL thành công"
                break
            else
                echo "==> Mật khẩu không chính xác. Vui lòng nhập lại."
            fi
        done
        
        # Tạo file dsnvps.txt cho Flashpanel
        cat > /tmp/dsnvps.txt << EOF
home_folder=/home/flashpanel
nginx_conf=/etc/nginx/conf.d
user_admin_mysql=flashpanel
pass_admin_mysql=$mysql_password
EOF
        echo "------------------------------------------------------------------------- "    
        echo "==> Đã tạo file cấu hình cho Flashpanel";sleep 3
        #echo "• MySQL User: flashpanel"
        #echo "• MySQL Password: [Ẩn]"
        #echo "• Home Folder: /home/flashpanel"
        #echo "• Nginx Config: /etc/nginx/conf.d"
        
        migrate_from_flashpanel
        
    # Kiểm tra Centminmod
    elif ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -d /usr/local/src/centminmod" 2>/dev/null; then
    echo "------------------------------------------------------------------------- " 
        echo "==> Phát hiện VPS cũ chạy Centminmod";sleep 4
        migrate_from_centminmod
        
    else
    echo "------------------------------------------------------------------------- " 
       # echo "==> Kiểm tra file /home/dsnvps.txt..."
        
        # Kiểm tra và đọc file dsnvps.txt từ VPS cũ
        if ! ssh -p "$sshport" root@$vpsipcu "TERM=dumb test -f /home/dsnvps.txt" 2>/dev/null; then
            handle_error "File /home/dsnvps.txt không tồn tại trên VPS cũ.\n-------------------------------------------------------------------------\nBạn cần tạo file này trước khi chạy migration."
        fi
echo "------------------------------------------------------------------------- " 
        #echo "==> Tìm thấy file dsnvps.txt trên VPS cũ"
        #echo "Đang tải file cấu hình..."

        # Tải file dsnvps.txt từ VPS cũ
        if ! scp -P "$sshport" root@$vpsipcu:/home/dsnvps.txt /tmp/dsnvps.txt 2>/dev/null; then
            handle_error "Không thể tải file dsnvps.txt từ VPS cũ"
        fi
#echo "------------------------------------------------------------------------- " 
  #      echo "==> Đã tải file cấu hình thành công"
   #     echo "------------------------------------------------------------------------- " 
    echo "Đang phân tích thông tin cấu hình..."

    # Parse thông tin từ file dsnvps.txt
    if [ ! -f /tmp/dsnvps.txt ]; then
        handle_error "File cấu hình không hợp lệ"
    fi

    # Đọc thông tin cấu hình
    home_folder=$(grep "home_folder=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
    nginx_conf=$(grep "nginx_conf=" /tmp/dsnvps.txt | cut -d'=' -f2 | sed 's|/$||')
    mysql_user=$(grep "user_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)
    mysql_pass=$(grep "pass_admin_mysql=" /tmp/dsnvps.txt | cut -d'=' -f2)

    # Kiểm tra thông tin cấu hình
    if [ -z "$home_folder" ] || [ -z "$nginx_conf" ] || [ -z "$mysql_user" ] || [ -z "$mysql_pass" ]; then
        handle_error "File dsnvps.txt không đầy đủ thông tin.
        -------------------------------------------------------------------------
Vui lòng kiểm tra lại file cấu hình."
    fi
#echo "------------------------------------------------------------------------- " 
 ##   echo "==> Thông tin cấu hình:"
 #   echo "• Thư mục website: $home_folder"
 #   echo "• Thư mục vhost: $nginx_conf"
 #   echo "• MySQL User: $mysql_user"
 #   echo "• MySQL Password: [ẨN]"

    # Kiểm tra kết nối MySQL trên VPS cũ
    echo "------------------------------------------------------------------------- " 
    echo "Đang kiểm tra kết nối MySQL trên VPS cũ..."
    echo "------------------------------------------------------------------------- " 
    echo "Vui lòng chờ trong giây lát..."; sleep 3
    
    # Kiểm tra MySQL với timeout
    mysql_check=$(timeout 30 ssh -p "$sshport" root@$vpsipcu "TERM=dumb mysql -u$mysql_user -p$mysql_pass -e 'SELECT 1;' 2>&1" 2>/dev/null)
    mysql_exit_code=$?
    
    if [ $mysql_exit_code -eq 124 ]; then
        handle_error "Kết nối MySQL bị timeout (quá 30 giây).
        -------------------------------------------------------------------------
Vui lòng kiểm tra lại thông tin MySQL trong file dsnvps.txt"
    elif [ $mysql_exit_code -ne 0 ]; then
        handle_error "Không thể kết nối MySQL trên VPS cũ.
        -------------------------------------------------------------------------
Vui lòng kiểm tra lại thông tin MySQL trong file dsnvps.txt"
    fi
    echo "------------------------------------------------------------------------- " 
    echo "==> Kết nối MySQL thành công"; sleep 3
    echo "========================================================================="
    echo "BẮT ĐẦU CHUYỂN DỮ LIỆU VỀ TỪ VPS CŨ"
    echo "========================================================================="

        # Thực hiện migration với file dsnvps.txt
        perform_migration_with_dsnvps_txt
    fi
}

# Function 3: Xóa cấu hình hiện tại
delete_current_config() {
    if [ ! -f /etc/dsnvps/vps_cu.info ]; then
        clear
        echo "========================================================================="
        echo "Server hiện tại chưa được kết nối với server cũ"
        echo "-------------------------------------------------------------------------"
        echo "Bạn không cần chạy chức năng này."
        main_menu
        return
    fi

    vpsimmoiip=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
    echo "========================================================================="
    echo "Chức năng này sẽ xóa mọi cấu hình trong [ Chuyển Về DSNVPS ]. Sau "
    echo "-------------------------------------------------------------------------"
    echo "khi thực hiện xong, bạn có thể cấu hình lại để kết nối VPS khác."
    echo "========================================================================="
    read -r -p "Bạn muốn thực hiện chức năng này? [y/N] " response
    case $response in
        [yY][eE][sS]|[yY])
        echo "------------------------------------------------------------------------- "  
            echo "Bắt đầu xóa cấu hình kết nối VPS cũ"
            echo "-------------------------------------------------------------------------"
            echo "Vui lòng chờ ... "
            sleep 3
            
            # Dừng các tiến trình rsync
            pkill rsync 2>/dev/null || true
            
            # Xóa SSH key cũ khỏi known_hosts
            if [ -n "$vpsimmoiip" ]; then
                echo "sed -i '/$vpsimmoiip/d' ~/.ssh/known_hosts" > /etc/dsnvps/.tmp/knownhost_sedit22
                chmod +x /etc/dsnvps/.tmp/knownhost_sedit22
                /etc/dsnvps/.tmp/knownhost_sedit22
                rm -rf /etc/dsnvps/.tmp/knownhost_sedit22
            fi
            rm -rf /home/dsnvps_restore
            # Xóa file cấu hình
            rm -rf /etc/dsnvps/vps_cu.info
            rm -rf /etc/dsnvps/.tmp/0klsa
            
            # Khởi động lại cron
            systemctl restart crond 2>/dev/null || true
            echo "------------------------------------------------------------------------- " 
            echo "Hoàn thành xóa cấu hình kết nối VPS cũ"
            clear
            echo "========================================================================="
            echo "Ngắt kết nối với server cũ thành công!"
            echo "-------------------------------------------------------------------------"
            main_menu
            ;;
        *)
        echo "------------------------------------------------------------------------- " 
            echo "Hủy bỏ xóa cấu hình"
            clear
            echo "========================================================================="
            echo "Hủy bỏ!"
            main_menu
            ;;
    esac
}

# Function 4: Xem thông tin database mới
view_database_info() {
    clear
    echo "========================================================================="
    echo "                    THÔNG TIN DATABASE MỚI"
    echo "========================================================================="
    
    if [ -f /home/dsnvps_restore/list-database.txt ]; then
        echo "MAPPING DATABASE CŨ -> MỚI:"
        echo "========================================================================="
        echo "Nếu thông tin database không có trong đây, bạn xem trong: DSNVPS menu =>"
        echo "-------------------------------------------------------------------------"
        echo "=> Quản Lý & Kiểm Tra Database => Xem User/Password/Dung Lượng Data"
        echo "-------------------------------------------------------------------------"
        cat /home/dsnvps_restore/list-database.txt
                echo ""
        echo "========================================================================="
        
        # Nếu list-database.txt chưa có dòng Data_name, fallback đọc từ /root/DBinfo.txt
        if ! grep -q "Data_name:" /home/dsnvps_restore/list-database.txt 2>/dev/null; then
            if [ -f /root/DBinfo.txt ]; then
                echo "==> Không có mapping chi tiết trong list-database.txt"
                echo "==> Đang hiển thị thông tin từ /root/DBinfo.txt"
                echo "========================================================================="
                awk '
                    /^Data name:/ {
                        db=$0; sub(/^Data name:[ ]*/, "", db);
                        getline; usr=$0; gsub(/^[^:]*:[ ]*/, "", usr);
                        getline; pwd=$0; gsub(/^[^:]*:[ ]*/, "", pwd);
                        print "=========================================================================";
                        print "Database cũ: " db;
                        print "";
                        print "=> Database mới:";
                        print "";
                        print "Data_name: " db;
                        print "Username: " usr;
                        print "Password: " pwd;
                        print "";
                        print "=========================================================================";
                    }
                ' /root/DBinfo.txt
                echo "========================================================================="
            fi
        fi
        
        # Kiểm tra nếu có file danh sách database mới
        if [ -f /home/dsnvps_restore/new-databases.txt ]; then
            echo "==> DANH SÁCH DATABASE MỚI (CẦN CẬP NHẬT CONFIG WEBSITE):"
            echo "========================================================================="
            cat /home/dsnvps_restore/new-databases.txt
            echo ""
            echo "========================================================================="
            echo "==> HƯỚNG DẪN:"
            echo "-------------------------------------------------------------------------"
            echo "Các database trong danh sách trên cần cập nhật thông tin trong:"
            echo "• File config website (wp-config.php, config.php, etc.)"
            echo "• Database name, Username, Password"
            echo "-------------------------------------------------------------------------"
        fi
    else
        echo "Không tìm thấy file thông tin database!"
        echo "------------------------------------------------------------------------- " 
        echo "File: /home/dsnvps_restore/list-database.txt"
        
        # Fallback hiển thị từ /root/DBinfo.txt nếu có
        if [ -f /root/DBinfo.txt ]; then
            echo "========================================================================="
            echo "==> Đang hiển thị thông tin từ /root/DBinfo.txt"
            echo "========================================================================="
            awk '
                /^Data name:/ {
                    db=$0; sub(/^Data name:[ ]*/, "", db);
                    getline; usr=$0; gsub(/^[^:]*:[ ]*/, "", usr);
                    getline; pwd=$0; gsub(/^[^:]*:[ ]*/, "", pwd);
                    print "=========================================================================";
                    print "Database cũ: " db;
                    print "";
                    print "=> Database mới:";
                    print "";
                    print "Data_name: " db;
                    print "Username: " usr;
                    print "Password: " pwd;
                    print "";
                    print "=========================================================================";
                }
            ' /root/DBinfo.txt
        fi
    fi
    
    echo ""
    echo "========================================================================="
    echo "Nhấn Enter để quay về menu chính..."
    read -r
    main_menu
}

# Function 5: Menu chính
main_menu() {
    clear
    /etc/dsnvps/menu/dsnvps-menu-all-function  
    echo "========================================================================="
    echo "          Chuyển Code Website & Database Từ VPS Cũ Về VPS Này"
    echo "========================================================================="
    
    # Kiểm tra cấu hình kết nối VPS cũ
    if [ -f /etc/dsnvps/vps_cu.info ]; then
        if [ "$(grep "ketnoistatus" /etc/dsnvps/vps_cu.info | awk '{print $3}')" == "thanhcong" ]; then
            vpsipcu=$(grep "ipaddress" /etc/dsnvps/vps_cu.info | awk '{print $3}')
            sshport=$(grep "sshport" /etc/dsnvps/vps_cu.info | awk '{print $3}')
            echo "==> ĐÃ KẾT NỐI VỚI VPS CŨ"
            echo "-------------------------------------------------------------------------"
            echo "• IP VPS cũ: $vpsipcu"
            echo "• SSH Port: $sshport"
            echo "• Trạng thái: Kết nối thành công"
            echo "========================================================================="
        fi

else
         echo "========================================================================="
echo "Chức năng này để chuyển dữ liệu từ VPS cũ về VPS đang dùng DSNVPS."
echo "-------------------------------------------------------------------------"
echo "Việc chuyển dữ liệu rất đơn giản nhanh chóng, giúp bạn chuyển Database &"
echo "-------------------------------------------------------------------------"
echo "Code từ VPS cũ sang VPS mới sử dụng DSNVPS trong vài phút."
   echo "-------------------------------------------------------------------------"
      #      echo "========================================================================="
    fi
    
    echo "Thứ Tự Thực Hiện => Lần Lượt Thực Hiện Các Bước: 1 => 2"
    echo "========================================================================="
    echo "Hướng dẫn sử dụng: "
    
    while true; do
        echo "========================================================================="
        echo "TIỆN ÍCH CHUYỂN DỮ LIỆU VỀ DSNVPS"
        echo "========================================================================="
        echo "Chọn chức năng migration:"
        echo ""
        echo "1. Kết nối VPS cũ"
        echo "2. Chuyển Dữ Liệu Về VPS Này"
        
        # Kiểm tra nếu có file cấu hình VPS cũ thì hiển thị menu 3
        if [ -f /etc/dsnvps/vps_cu.info ]; then
            echo "3. Xóa cấu hình hiện tại"
        fi
        
        # Kiểm tra nếu có file database info thì hiển thị menu 4
        if [ -f /home/dsnvps_restore/list-database.txt ]; then
            echo "4. Xem Thông Tin Database"
        fi
        
        echo "0. Thoát"
        echo "========================================================================="
        
        # Xác định range menu dựa trên các file có sẵn
        if [ -f /etc/dsnvps/vps_cu.info ] && [ -f /home/dsnvps_restore/list-database.txt ]; then
            read -p "Nhập lựa chọn [0-4]: " choice
        elif [ -f /etc/dsnvps/vps_cu.info ]; then
            read -p "Nhập lựa chọn [0-3]: " choice
        elif [ -f /home/dsnvps_restore/list-database.txt ]; then
            read -p "Nhập lựa chọn [0-4]: " choice
        else
            read -p "Nhập lựa chọn [0-2]: " choice
        fi
        
        case $choice in
            1) connect_to_old_vps ;;
            2) smart_migration ;;
            3) 
                if [ -f /etc/dsnvps/vps_cu.info ]; then
                    delete_current_config
                else
                    echo "========================================================================="
                    echo "Menu không khả dụng!"
                    echo "Chỉ hiển thị khi đã kết nối VPS cũ"
                    sleep 3
                fi
                ;;
            4) 
                if [ -f /home/dsnvps_restore/list-database.txt ]; then
                    view_database_info
                else
                    echo "========================================================================="
                    echo "Menu không khả dụng!"
                    echo "Chỉ hiển thị khi có file /home/dsnvps_restore/list-database.txt"
                    sleep 3
                fi
                ;;
0) clear; exit 0;;
            *)
                echo "========================================================================="
                echo "Bạn nhập sai, vui lòng nhập theo số thứ tự trên menu!"
                sleep 3
                ;;
        esac
    done
}

# Khởi động menu chính
main_menu
