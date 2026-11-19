import asyncio
import os
import sys
import configparser
import re
import time
import random
import string
from datetime import datetime, timezone, timedelta
from telethon import TelegramClient
from collections import defaultdict

# Hàm tạo random 9 ký tự từ 0-9, a-z, A-Z
def generate_random_string(length=9):
    """Tạo chuỗi ngẫu nhiên với độ dài chỉ định từ 0-9, a-z, A-Z"""
    characters = string.ascii_letters + string.digits  # a-z, A-Z, 0-9
    return ''.join(random.choice(characters) for _ in range(length))

# Hàm lấy giờ GMT+7
def get_vn_time():
    utc_now = datetime.now(timezone.utc)
    vn_now = utc_now + timedelta(hours=7)
    return vn_now.strftime("%Y-%m-%d %H:%M:%S")

# Đọc file cấu hình Telegram
def read_config(config_file='/etc/dsnvps/telegram_group.conf'):
    config = configparser.ConfigParser()
    if not os.path.exists(config_file):
        print("Lỗi: Không tìm thấy file cấu hình {}.".format(config_file))
        sys.exit(1)
    config.read(config_file)
    if 'Telegram' not in config:
        print("Lỗi: File cấu hình {} không đúng định dạng.".format(config_file))
        sys.exit(1)
    try:
        return {
            'api_id': int(config['Telegram']['api_id']),
            'api_hash': config['Telegram']['api_hash'],
            'phone_number': config['Telegram']['phone_number'],
            'group_id': int(config['Telegram']['group_id'])
        }
    except KeyError as e:
        print("Lỗi: Thiếu key {} trong file cấu hình {}.".format(e, config_file))
        sys.exit(1)

# Đọc file dsnvps.conf
def read_dsnvps_conf(config_file='/root/dsnvps.conf'):
    if not os.path.exists(config_file):
        print("Lỗi: Không tìm thấy file cấu hình {}.".format(config_file))
        sys.exit(1)
    try:
        exec(open(config_file).read(), globals())
        return globals().get('mainsite', 'dsnvps.demo')
    except Exception as e:
        print(f"Lỗi khi đọc file {config_file}: {e}")
        sys.exit(1)

# Hàm hiển thị progress bar
def show_progress(current, total, prefix="Progress", bar_length=50):
    """
    Hiển thị thanh tiến trình
    """
    if total == 0:
        return
    
    percent = current / total
    filled_length = int(bar_length * percent)
    bar = '█' * filled_length + '-' * (bar_length - filled_length)
    
    # Tính toán tốc độ và thời gian còn lại
    percent_str = f"{percent:.1%}"
    
    print(f"\r{prefix}: |{bar}| {percent_str} ({current}/{total})", end="", flush=True)

# Callback function cho download progress
def download_progress_callback(current, total):
    """
    Callback để hiển thị tiến trình download
    """
    show_progress(current, total, "Đang tải", 40)

# Hàm nối các file đã chia
def reassemble_split_files(subfolder_path, original_filename, part_files):
    """
    Nối các file đã chia thành file gốc
    """
    try:
        output_path = os.path.join(subfolder_path, original_filename)
        print(f" → Đang nối {len(part_files)} phần thành file: {original_filename}")
        
        # Tính tổng kích thước để hiển thị progress
        total_size = 0
        for part_file in sorted(part_files):
            part_path = os.path.join(subfolder_path, part_file)
            if os.path.exists(part_path):
                total_size += os.path.getsize(part_path)
        
        current_size = 0
        with open(output_path, 'wb') as output_file:
            for i, part_file in enumerate(sorted(part_files)):
                part_path = os.path.join(subfolder_path, part_file)
                if os.path.exists(part_path):
                    with open(part_path, 'rb') as part:
                        while True:
                            chunk = part.read(8192)  # 8KB chunks
                            if not chunk:
                                break
                            output_file.write(chunk)
                            current_size += len(chunk)
                            # Hiển thị progress
                            show_progress(current_size, total_size, f"   Nối phần {i+1}/{len(part_files)}", 30)
                    print(f"\n    ==> Đã nối: {part_file}")
                else:
                    print(f"    ==> Không tìm thấy: {part_file}")
                    return False
        
        # Xóa các file phần sau khi nối xong
        print(f" → Đang xóa {len(part_files)} file phần...")
        for i, part_file in enumerate(part_files):
            part_path = os.path.join(subfolder_path, part_file)
            if os.path.exists(part_path):
                os.remove(part_path)
                show_progress(i+1, len(part_files), "   Xóa file phần", 30)
        print(f"\n ==> Nối file thành công: {original_filename}")
        return True
    except Exception as e:
        print(f" ==> Lỗi nối file {original_filename}: {e}")
        return False

async def main():
    # Đọc cấu hình
    config = read_config()
    api_id = config['api_id']
    api_hash = config['api_hash']
    phone_number = config['phone_number']
    group_id = config['group_id']
    
    # Lấy mainsite từ dsnvps.conf
    mainsite = read_dsnvps_conf()
    
    # Khởi tạo client Telethon
    client = TelegramClient('/etc/dsnvps/telegram.session', api_id, api_hash)
    
    try:
        # Kết nối (tái sử dụng session file)
        await client.connect()
        if not await client.is_user_authorized():
            print(f"==> Session không hợp lệ. Xóa /etc/dsnvps/telegram.session và chạy lại dsnvps-create-telegram-config.py.")
            sys.exit(1)
        
        # Liệt kê subfolder từ message
        subfolders = {}
        split_files = defaultdict(lambda: defaultdict(list))  # {item_name: {original_filename: [part_files]}}
        
        async for message in client.iter_messages(group_id, limit=5000):
            if message.document and message.text:
                filename = message.document.attributes[0].file_name
                match = re.search(r'Subfolder: ([^/]+)/', message.text)
                if match:
                    subfolder_name = match.group(1)
                    
                    # Kiểm tra xem có phải file chia không
                    split_match = re.search(r'Split: (.+)', message.text)
                    if split_match:
                        # Đây là file đã chia
                        part_filename = split_match.group(1)
                        # Tìm tên file gốc từ caption
                        original_match = re.search(r'Subfolder: [^/]+/(.+)', message.text.split('\n')[0])
                        if original_match:
                            original_filename = original_match.group(1)
                            split_files[subfolder_name][original_filename].append((message.date, message.id, part_filename))
                        continue
                    
                    # File thông thường (không chia)
                    if filename.endswith('.zip'):
                        file_type = 'website'
                        item_name = re.sub(r'-[0-9a-f]+\.zip$', '', filename)
                    elif filename.endswith('.sql.gz'):
                        file_type = 'database'
                        item_name = re.sub(r'-[0-9a-f]+\.sql\.gz$', '', filename)
                    else:
                        continue
                    if item_name not in subfolders:
                        subfolders[item_name] = []
                    subfolders[item_name].append((message.date, message.id, filename, file_type))
        
        # Thêm các file chia vào subfolders
        for item_name, files_dict in split_files.items():
            if item_name not in subfolders:
                subfolders[item_name] = []
            for original_filename, parts in files_dict.items():
                if original_filename.endswith('.zip'):
                    file_type = 'website'
                elif original_filename.endswith('.sql.gz'):
                    file_type = 'database'
                else:
                    continue
                # Sử dụng thời gian của phần đầu tiên
                if parts:
                    parts.sort(reverse=True)  # Sắp xếp theo thời gian
                    date, _, _ = parts[0]
                    subfolders[item_name].append((date, 'SPLIT:' + original_filename, original_filename, file_type))
        
        if not subfolders:
            print("=========================================================================")
            print("Không tìm thấy file backup nào trên Telegram!")
            return
        
        # Hiển thị danh sách subfolder
        print("=========================================================================")
        print("Danh sách folder backup trên Telegram:")
        print("-------------------------------------------------------------------------")
        for subfolder in sorted(subfolders.keys()):
            print(subfolder)
        print("=========================================================================")
        print("Chọn cách tải về backup:")
        print("-------------------------------------------------------------------------")
        print("1. Tải bản backup gần nhất của tất cả website/database")
        print("2. Tải số phiên bản gần nhất của tất cả website/database")
        print("-------------------------------------------------------------------------")
        
        while True:
            choice = input("Nhập lựa chọn của bạn [1-2, 0-Thoát]: ").strip()
            if choice == "0":
                print("Cancel !")
                sys.exit(0)
            if choice not in ['1', '2']:
                print("Vui lòng chọn 1, 2 hoặc 0 để thoát.")
                continue
            max_versions = 1 if choice == '1' else None
            if choice == '2':
                print("-------------------------------------------------------------------------")
                while True:
                    try:
                        max_versions = int(input("Nhập số phiên bản gần nhất muốn tải (ví dụ: 2): "))
                        if max_versions < 1:
                            print("Số phiên bản phải lớn hơn 0.")
                            continue
                        break
                    except ValueError:
                        print("Vui lòng nhập số nguyên hợp lệ.")
            break
        
        print("=========================================================================")
        response = input("Bạn chắc chắn download file backup? [y/N] ").strip().lower()
        if response not in ['y', 'yes']:
            print("Cancel !")
            sys.exit(0)
        
        # Tạo thư mục backup local
        backup_base_dir = f"/home/{mainsite}/private_html/backup"
        if not os.path.exists(backup_base_dir):
            try:
                os.makedirs(backup_base_dir, exist_ok=True)
            except PermissionError:
                print(f"Lỗi: Không có quyền tạo thư mục {backup_base_dir}. Chạy với sudo hoặc kiểm tra quyền.")
                sys.exit(1)
        
        # Tải file
        downloaded_files = []
        for subfolder_name, files in sorted(subfolders.items()):
            print(f"=========================================================================")
            print(f"Đang tải backup của: {subfolder_name}")
            
            # Tạo thư mục cho subfolder
            subfolder_path = os.path.join(backup_base_dir, subfolder_name)
            try:
                os.makedirs(subfolder_path, exist_ok=True)
            except PermissionError:
                print(f"Lỗi: Không có quyền tạo thư mục {subfolder_path}. Chạy với sudo hoặc kiểm tra quyền.")
                sys.exit(1)
            
            print(f"-------------------------------------------------------------------------")
            print(f"To: {subfolder_path}")
            
            # Sắp xếp file theo thời gian (mới nhất trước)
            files.sort(reverse=True)
            files_to_download = files[:max_versions]
            
            for _, message_id, filename, file_type in files_to_download:
                print(f"-------------------------------------------------------------------------")
                print(f"File backup: {filename}")
                try:
                    if isinstance(message_id, str) and message_id.startswith('SPLIT:'):
                        # Đây là file chia, cần tải tất cả các phần
                        original_filename = message_id[6:]  # Bỏ prefix 'SPLIT:'
                        if subfolder_name in split_files and original_filename in split_files[subfolder_name]:
                            parts = split_files[subfolder_name][original_filename]
                            parts.sort(key=lambda x: x[2])  # Sắp xếp theo tên file part
                            
                            part_files = []
                            print(f" → Tải {len(parts)} phần của file chia...")
                            
                            for part_idx, (_, part_msg_id, part_filename) in enumerate(parts):
                                try:
                                    print(f"   Đang tải phần {part_idx+1}/{len(parts)}: {part_filename}")
                                    async for message in client.iter_messages(group_id, ids=part_msg_id):
                                        await client.download_media(
                                            message,
                                            file=os.path.join(subfolder_path, part_filename),
                                            progress_callback=download_progress_callback
                                        )
                                        print(f"\n    ==> Tải thành công phần: {part_filename}")
                                        part_files.append(part_filename)
                                except Exception as e:
                                    print(f"\n    ==> Lỗi tải phần {part_filename}: {e}")
                            
                            # Nối các file lại
                            if len(part_files) == len(parts):
                                if reassemble_split_files(subfolder_path, original_filename, part_files):
                                    downloaded_files.append(f"{subfolder_name}/{original_filename} ({file_type}) - Đã nối từ {len(parts)} phần")
                                else:
                                    print(f" ==> Lỗi nối file: {original_filename}")
                            else:
                                print(f" ==> Không tải đủ các phần của file: {original_filename}")
                    else:
                        # File thông thường
                        file_size = 0
                        async for message in client.iter_messages(group_id, ids=message_id):
                            if message.document:
                                file_size = message.document.size
                                file_size_mb = file_size / (1024 * 1024)
                                print(f" → Đang tải: {filename} ({file_size_mb:.2f}MB)")
                            
                            await client.download_media(
                                message,
                                file=os.path.join(subfolder_path, filename),
                                progress_callback=download_progress_callback
                            )
                            print(f"\n ==> Tải thành công: {filename}")
                            downloaded_files.append(f"{subfolder_name}/{filename} ({file_type})")
                except Exception as e:
                    print(f" → Lỗi tải {filename}: {e}")
        
        # Hiển thị kết quả
        print("=========================================================================")
        print(f"Download {'bản mới nhất' if choice == '1' else f'{max_versions} phiên bản gần nhất'} hoàn thành.")
        print("-------------------------------------------------------------------------")
        print("Folder chứa backup:")
        print("-------------------------------------------------------------------------")
        print(backup_base_dir)
        print("-------------------------------------------------------------------------")
        print("File đã tải về:")
        for file in downloaded_files:
            print(f"• {file}")
        print("-------------------------------------------------------------------------")
        print("Bây giờ bạn có thể sử dụng các chức năng có sẵn của DSNVPS để phục hồi")
        print("-------------------------------------------------------------------------")
        print("DSNVPS Menu => Sao Lưu & Phục Hồi Website => Phục Hồi 1 Website")
        print("-------------------------------------------------------------------------")
        print("DSNVPS Menu => Sao Lưu & Phục Hồi Database => Phục Hồi 1 Database")
        print("=========================================================================")
    
    except Exception as e:
        print(f"Lỗi: {e}")
        await client.send_message(group_id, f"Lỗi tổng thể: {e}")
    
    finally:
        await client.disconnect()
       # print("Đã ngắt kết nối.")

if __name__ == '__main__':
    # Tương thích với Python cũ (3.6 và trước đó)
    try:
        # Python 3.7+
        asyncio.run(main())
    except AttributeError:
        # Python 3.6 và cũ hơn
        loop = asyncio.get_event_loop()
        try:
            loop.run_until_complete(main())
        finally:
            loop.close()