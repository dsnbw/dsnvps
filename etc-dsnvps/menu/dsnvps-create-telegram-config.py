import asyncio
import os
import re
import random
import string
import sqlite3
import subprocess
import signal
import time
import sys
from telethon import TelegramClient
from telethon.tl.functions.channels import CreateChannelRequest
from telethon.tl.functions.messages import GetFullChatRequest

# Hàm fix database lock - Tương thích Python 3.6 và 3.7+
def fix_session_lock_compatible(session_file='/etc/dsnvps/telegram.session'):
    """Kiểm tra và xử lý lock trên file session - Tương thích cả Python 3.6 và 3.7+"""
    try:
        print("Đang xử lý database lock...")
        
        # Bước 1: Sử dụng lsof để tìm và kill các process đang lock file
        try:
            # Kiểm tra lsof có sẵn không - Tương thích cả Python 3.6 và 3.7+
            try:
                # Thử Python 3.7+ trước
                result = subprocess.run(['which', 'lsof'], capture_output=True, text=True)
                lsof_available = result.returncode == 0
            except TypeError:
                # Fallback về Python 3.6
                result = subprocess.Popen(['which', 'lsof'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                stdout, stderr = result.communicate()
                lsof_available = result.returncode == 0
            except:
                lsof_available = False
            
            if lsof_available:
                # Sử dụng lsof để tìm process lock file session
                try:
                    cmd = ['lsof', session_file]
                    
                    # Tương thích cả Python 3.6 và 3.7+
                    try:
                        # Thử Python 3.7+ trước
                        result = subprocess.run(cmd, capture_output=True, text=True)
                        stdout = result.stdout
                        returncode = result.returncode
                    except TypeError:
                        # Fallback về Python 3.6
                        result = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        stdout, stderr = result.communicate()
                        stdout = stdout.decode('utf-8')
                        returncode = result.returncode
                    
                    if returncode == 0:
                        current_pid = str(os.getpid())
                        pids = []
                        lines = stdout.splitlines()
                        for line in lines[1:]:  # Bỏ header
                            parts = line.split()
                            if len(parts) > 1:
                                pid = parts[1]  # Cột PID
                                if pid != current_pid:
                                    pids.append(pid)
                        
                        # Kill các process lock
                        if pids:
                            for pid in pids:
                                try:
                                    os.kill(int(pid), 0)
                                    os.kill(int(pid), signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                except PermissionError:
                                    pass
                                except Exception as e:
                                    pass
                            
                            time.sleep(3)
                        else:
                            pass
                    else:
                        print("Không có process nào đang sử dụng session file")
                except Exception as e:
                    print("WARNING: Lỗi khi sử dụng lsof: {}".format(str(e)))
            else:
                print("WARNING: lsof không có sẵn, thử kill process telegram cũ")
                # Fallback: kill các process telegram cũ
                try:
                    try:
                        # Python 3.7+
                        result = subprocess.run(['ps', 'aux'], capture_output=True, text=True)
                        stdout = result.stdout
                        returncode = result.returncode
                    except TypeError:
                        # Python 3.6
                        result = subprocess.Popen(['ps', 'aux'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        stdout, stderr = result.communicate()
                        stdout = stdout.decode('utf-8')
                        returncode = result.returncode
                    
                    if returncode == 0:
                        current_pid = str(os.getpid())
                        lines = stdout.splitlines()
                        telegram_pids = []
                        
                        for line in lines:
                            if 'telegram' in line.lower() and 'python' in line.lower():
                                parts = line.split()
                                if len(parts) > 1:
                                    pid = parts[1]
                                    if pid != current_pid:
                                        telegram_pids.append(pid)
                        
                        if telegram_pids:
                            print("Tìm thấy {} process telegram cũ: {}".format(len(telegram_pids), ', '.join(telegram_pids)))
                            for pid in telegram_pids:
                                try:
                                    os.kill(int(pid), 0)
                                    os.kill(int(pid), signal.SIGKILL)
                                    print("Đã kill process telegram cũ PID: {}".format(pid))
                                except ProcessLookupError:
                                    pass
                                except PermissionError:
                                    print("WARNING: Không có quyền kill PID {}".format(pid))
                                except Exception as e:
                                    print("WARNING: Lỗi khi kill PID {}: {}".format(pid, str(e)))
                            
                            time.sleep(2)
                        else:
                            print("Không tìm thấy process telegram cũ nào")
                except Exception as e:
                    print("WARNING: Lỗi khi kill process telegram cũ: {}".format(str(e)))
        
        except Exception as e:
            print("WARNING: Lỗi khi kill process: {}".format(str(e)))
        
        # Bước 2: Xóa các file lock của SQLite
        lock_files = [
            "{}-wal".format(session_file),
            "{}-shm".format(session_file),
            "{}.lock".format(session_file),
            "{}-journal".format(session_file)
        ]
        
        for lock_file in lock_files:
            if os.path.exists(lock_file):
                try:
                    os.remove(lock_file)
                except Exception as e:
                    pass
        
        # Bước 3: Reset database mode
        try:
            conn = sqlite3.connect(session_file, timeout=10)
            conn.execute("PRAGMA journal_mode=WAL")
            conn.execute("PRAGMA synchronous=NORMAL")
            conn.close()
        except Exception as e:
            pass
        
        # Bước 4: Kiểm tra lại database
        try:
            conn = sqlite3.connect(session_file, timeout=10)
            conn.execute("PRAGMA quick_check")
            conn.close()
            return True
        except sqlite3.OperationalError as e:
            if "database is locked" in str(e).lower():
                print("WARNING: Database vẫn bị lock sau khi xử lý. Thử phương pháp cuối cùng...")
                
                # Thử lần cuối với lsof và kill -9
                try:
                    try:
                        # Python 3.7+
                        result = subprocess.run(['lsof', session_file], capture_output=True, text=True)
                        stdout = result.stdout
                        returncode = result.returncode
                    except TypeError:
                        # Python 3.6
                        result = subprocess.Popen(['lsof', session_file], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        stdout, stderr = result.communicate()
                        stdout = stdout.decode('utf-8')
                        returncode = result.returncode
                    
                    if returncode == 0:
                        current_pid = str(os.getpid())
                        lines = stdout.splitlines()
                        for line in lines[1:]:
                            parts = line.split()
                            if len(parts) > 1:
                                pid = parts[1]
                                if pid != current_pid:
                                    try:
                                        os.kill(int(pid), signal.SIGKILL)
                                        print("Force kill PID: {}".format(pid))
                                    except:
                                        pass
                        time.sleep(2)
                        
                        # Backup session cũ và tạo mới
                        try:
                            backup_file = "{}.backup.{}".format(session_file, int(time.time()))
                            os.rename(session_file, backup_file)
                        except Exception as backup_error:
                            pass
                    else:
                        print("ERROR: Database error: {}".format(str(e)))
                except Exception as e:
                    print("ERROR: Lỗi khi xử lý lock: {}".format(str(e)))
                return False
            else:
                print("ERROR: Database error: {}".format(str(e)))
                return False
        except Exception as e:
            print("ERROR: Lỗi khi kiểm tra database: {}".format(str(e)))
            return False
            
    except Exception as e:
        print("ERROR khi xử lý lock: {}".format(str(e)))
        return False

# Async wrapper
async def fix_session_lock_async(session_file='/etc/dsnvps/telegram.session'):
    """Async wrapper cho fix_session_lock_compatible"""
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, fix_session_lock_compatible, session_file)
def generate_random_string(length=9):
    """Tạo chuỗi ngẫu nhiên với độ dài chỉ định từ 0-9, a-z, A-Z"""
    characters = string.ascii_letters + string.digits  # a-z, A-Z, 0-9
    return ''.join(random.choice(characters) for _ in range(length))

# Đọc file dsnvps.conf
def read_dsnvps_conf(config_file='/root/dsnvps.conf'):
    if not os.path.exists(config_file):
        print(f"Lỗi: Không tìm thấy file cấu hình {config_file}. Dùng IP mặc định.")
        return os.popen('hostname -I | awk "{print $1}"').read().strip()
    try:
        exec(open(config_file).read(), globals())
        return globals().get('serverip', os.popen('hostname -I | awk "{print $1}"').read().strip())
    except Exception as e:
        print(f"Lỗi khi đọc file {config_file}: {e}. Dùng IP mặc định.")
        return os.popen('hostname -I | awk "{print $1}"').read().strip()

def validate_group_id(group_id_str):
    """Kiểm tra định dạng group_id có hợp lệ không"""
    try:
        # Loại bỏ khoảng trắng
        group_id_str = group_id_str.strip()
        
        # Kiểm tra có phải là số không
        if not group_id_str.lstrip('-').isdigit():
            return False, "Group ID phải là số"
        
        group_id = int(group_id_str)
        
        # Kiểm tra phải là số âm (supergroup)
        if group_id >= 0:
            return False, "Group ID phải là số âm (bắt đầu bằng dấu -)"
        
        # Kiểm tra định dạng supergroup (phải bắt đầu bằng -100)
        if not str(group_id).startswith('-100'):
            return False, "Group ID không đúng định dạng supergroup (phải bắt đầu bằng -100)"
        
        return True, group_id
    except ValueError:
        return False, "Group ID không hợp lệ"

def validate_api_id(api_id_str):
    """Kiểm tra api_id: bắt buộc là số nguyên dương"""
    try:
        api_id_str = api_id_str.strip()
        if not api_id_str:
            return False, "api_id không được để trống"
        if not api_id_str.isdigit():
            return False, "api_id chỉ được chứa chữ số"
        api_id = int(api_id_str)
        if api_id <= 0:
            return False, "api_id phải là số nguyên dương"
        return True, api_id
    except Exception:
        return False, "api_id không hợp lệ"

def validate_api_hash(api_hash_str):
    """Kiểm tra api_hash: 32 ký tự hex [0-9a-fA-F]"""
    try:
        api_hash_str = api_hash_str.strip()
        if not api_hash_str:
            return False, "api_hash không được để trống"
        if re.fullmatch(r"[0-9a-fA-F]{32}", api_hash_str) is None:
            return False, "api_hash phải gồm đúng 32 ký tự hex (0-9, a-f)"
        return True, api_hash_str
    except Exception:
        return False, "api_hash không hợp lệ"

def show_temporary_error(message, retry_hint="Vui lòng thử lại...", display_seconds=4, lines=None, clear_previous_input=False, previous_lines=1):
    """Hiển thị lỗi trong một khoảng thời gian rồi xóa và trả lại vị trí nhập"""
    try:
        print(f"==> Lỗi: {message}")
        if retry_hint:
            print(retry_hint)
        time.sleep(display_seconds)

        # Xác định số dòng cần xóa (1 nếu không có retry_hint)
        base_lines = 2 if retry_hint else 1
        lines_to_clear = lines if lines is not None else base_lines
        if clear_previous_input:
            lines_to_clear += previous_lines
        if lines_to_clear > 0:
            # Di chuyển lên lines_to_clear dòng (về đầu khối cần xóa)
            sys.stdout.write(f"\033[{lines_to_clear}A")
            # Xóa từng dòng mà không chèn dòng trống
            for idx in range(lines_to_clear):
                sys.stdout.write("\033[2K")
                if idx < lines_to_clear - 1:
                    sys.stdout.write("\033[1B")
            # Đưa con trỏ về lại dòng trên cùng của khu vực vừa xóa
            if lines_to_clear > 1:
                sys.stdout.write(f"\033[{lines_to_clear - 1}A")
        sys.stdout.flush()
    except Exception:
        # Fallback: nếu terminal không hỗ trợ ANSI, chỉ in bình thường
        pass

def validate_phone_number(phone_number_str):
    """Kiểm tra số điện thoại: bắt đầu bằng + theo sau là 8-15 chữ số"""
    try:
        phone_number_str = phone_number_str.strip()
        if not phone_number_str:
            return False, "Số điện thoại không được để trống"
        if re.fullmatch(r"\+[0-9]{8,15}", phone_number_str) is None:
            return False, "Số điện thoại phải bắt đầu bằng + ví dụ: +84913456789"
        return True, phone_number_str
    except Exception:
        return False, "Số điện thoại không hợp lệ"

def input_api_id():
    """Nhập api_id: nhập mãi đến khi đúng; nhập 0 để thoát"""
    print("-------------------------------------------------------------------------")
    while True:
        try:
            value = input("Nhập api_id [0 -Thoát]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Đã hủy nhập liệu.")
            exit(1)
        if value == '0':
            print("==> Thoát.")
            exit(0)
        ok, result = validate_api_id(value)
        if ok:
            return result
        show_temporary_error(result, clear_previous_input=True, previous_lines=1)

def input_api_hash():
    """Nhập api_hash: nhập mãi đến khi đúng; nhập 0 để thoát (không che ký tự)"""
    print("-------------------------------------------------------------------------")
    while True:
        try:
            value = input("Nhập api_hash [0 -Thoát]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Đã hủy nhập liệu.")
            exit(1)
        if value == '0':
            print("==> Thoát.")
            exit(0)
        ok, result = validate_api_hash(value)
        if ok:
            return result
        show_temporary_error(result, clear_previous_input=True, previous_lines=1)

def input_phone_number():
    """Nhập số điện thoại: nhập mãi đến khi đúng; nhập 0 để thoát"""
    print("-------------------------------------------------------------------------")
    while True:
        try:
            value = input("Nhập số điện thoại (ví dụ: +84913456789) [0 -Thoát]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Đã hủy nhập liệu.")
            exit(1)
        if value == '0':
            print("==> Thoát.")
            exit(0)
        ok, result = validate_phone_number(value)
        if ok:
            return result
        show_temporary_error(result, clear_previous_input=True, previous_lines=1)

async def check_group_exists(client, group_id):
    """Kiểm tra group có tồn tại và có quyền truy cập không"""
    try:
        # Thử lấy thông tin group
        entity = await client.get_entity(group_id)
        if entity:
            # Kiểm tra có phải là supergroup không
            if hasattr(entity, 'megagroup') and entity.megagroup:
                return True, f"Group hợp lệ: {entity.title}"
            else:
                return False, "Group không phải là supergroup"
        return False, "Không thể truy cập group"
    except Exception as e:
        return False, f"Lỗi khi kiểm tra group: {str(e)}"

def input_existing_group():
    """Nhập group cũ với validation: nhập mãi đến khi đúng; nhập 0 để thoát"""
    print(f"-------------------------------------------------------------------------")
    while True:
        try:
            group_id_str = input("Nhập Group ID cũ (ví dụ: -1001234567890) [0 -Thoát]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Đã hủy nhập liệu.")
            return None
        if group_id_str == '0':
            print("==> Thoát.")
            exit(0)
        # Kiểm tra nếu người dùng nhập rỗng hoặc chỉ có khoảng trắng
        if not group_id_str:
            show_temporary_error("Group ID không được để trống.", clear_previous_input=True, previous_lines=1)
            continue
        # Validate group_id
        is_valid, result = validate_group_id(group_id_str)
        if is_valid:
            return result  # Trả về group_id hợp lệ
        else:
            show_temporary_error(result, clear_previous_input=True, previous_lines=1)

def show_menu():
    """Hiển thị menu lựa chọn"""
    print("-------------------------------------------------------------------------")
    print("Chọn [ Tạo Group mới ] nếu bạn chưa có Group.")
    print("-------------------------------------------------------------------------")
    print("Hoặc nhập Group cũ để cấu hình, nhằm sao lưu hoặc tải dữ liệu về VPS.")
    print("-------------------------------------------------------------------------")
    print("TẠO GROUP MỚI HOẶC NHẬP GROUP CŨ:")
    print("-------------------------------------------------------------------------")
    print("1. Tạo Group (Folder) mới")
    print("2. Nhập Group cũ")
    print("-------------------------------------------------------------------------")
    
    while True:
        try:
            choice = input("Nhập lựa chọn [0 - Thoát]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Hủy.")
            return '0'
        
        if choice in ['0', '1', '2']:
            return choice
        else:
            show_temporary_error("Lựa chọn không hợp lệ. Vui lòng nhập 0, 1 hoặc 2.", clear_previous_input=True, previous_lines=1)

async def main():
    # Nhập thông tin từ người dùng (có kiểm tra và giới hạn 3 lần thử)
    api_id = input_api_id()
    api_hash = input_api_hash()
    phone_number = input_phone_number()

    # Xác nhận lại toàn bộ giá trị trước khi kết nối
    print("-------------------------------------------------------------------------")
    print("Xác nhận thông tin đã nhập:")
    print("-------------------------------------------------------------------------")
    print(f"api_id       : {api_id}")
    print(f"api_hash     : {api_hash}")
    print(f"phone_number : {phone_number}")
    print("-------------------------------------------------------------------------")
    while True:
        try:
            confirm = input("Xác nhận thông tin? [Y/n]: ").strip()
        except (EOFError, KeyboardInterrupt):
            print("\n==> Hủy.")
            exit(1)
        if confirm == '' or confirm.lower() == 'y':
            break
        if confirm.lower() == 'n':
            print("==> Đã hủy.")
            exit(0)
        show_temporary_error("Lựa chọn không hợp lệ. Vui lòng nhập Y hoặc n.", clear_previous_input=True, previous_lines=1)

    # Lấy server_ip từ dsnvps.conf
    server_ip = read_dsnvps_conf()

    # Hiển thị menu lựa chọn
    choice = show_menu()

    # Xử lý lựa chọn thoát
    if choice == '0':
        print("-------------------------------------------------------------------------")
        print("Thoát.")
        exit(0)

    group_id = None
    group_name = None

    if choice == '2':
        # Nhập group cũ TRƯỚC KHI đăng nhập
        print("Bắt đầu nhập Group cũ...")
        group_id = input_existing_group()
        if group_id is None:
            show_temporary_error("Group ID không đúng định dạng. Thoát.")
            show_temporary_error("Group ID phải là số âm bắt đầu bằng -100 (ví dụ: -1001234567890)")
            exit(1)
        
        print("==> Group ID đã nhập: {}".format(group_id))
        group_name = None  # Sẽ lấy tên thực tế từ Telegram sau khi đăng nhập

    # Khởi tạo client Telethon với session tại /etc/dsnvps/telegram.session
    session_file = '/etc/dsnvps/telegram.session'
    client = TelegramClient(session_file, api_id, api_hash)
    
    try:
        # Đăng nhập (sử dụng session file nếu có)
        print("-------------------------------------------------------------------------")
        print("Đang đăng nhập vào Telegram...")
        await client.start(phone=phone_number)
        print("-------------------------------------------------------------------------")
        print("Đăng nhập thành công.")
        print("-------------------------------------------------------------------------")

        if choice == '1':
            # Tạo supergroup mới với tên {server_ip}-{random}
            random_suffix = generate_random_string(9)
            group_name = "{}-{}".format(server_ip, random_suffix)
            result = await client(CreateChannelRequest(
                title=group_name,
                about="Save backup file backup for VPS {server_ip}",
                megagroup=True  # Tạo supergroup
            ))

            # Lấy group_id từ kết quả
            chat = result.chats[0]
            group_id = chat.id
            
            # Chuyển đổi thành ID supergroup đúng định dạng
            if chat.megagroup:
                # Supergroup ID = -1000000000000 - abs(original_id)
                group_id = -1000000000000 - abs(group_id)
            
            # Validate group_id format
            if not isinstance(group_id, int) or group_id >= 0:
                raise ValueError("Invalid group_id format: {}. Supergroup ID must be negative.".format(group_id))

            print("Đã tạo nhóm mới: {}".format(group_name))
            print("Group ID: {}".format(group_id))

        elif choice == '2':
            # Kiểm tra group có tồn tại và hợp lệ không (sau khi đã đăng nhập)
            print("Đang kiểm tra group...")
            exists, message = await check_group_exists(client, group_id)
            
            if not exists:
                print(f"==> {message}")
                print("==> Group không hợp lệ hoặc không có quyền truy cập. Thoát.")
                exit(1)
            else:
                print(f"==> {message}")
                # Lấy tên group thực tế từ Telegram
                try:
                    entity = await client.get_entity(group_id)
                    group_name = entity.title
                    print(f"==> Tên Group Telegram: {group_name}")
                except Exception as e:
                    print(f"==> Không thể lấy tên group: {e}")
                    group_name = f"Group_{abs(group_id)}"

        # Kiểm tra group_id và group_name đã được thiết lập chưa
        if group_id is None or group_name is None:
            print("==> Lỗi: Group ID hoặc Group Name chưa được thiết lập. Thoát.")
            exit(1)

        # Lưu thông tin vào file /etc/dsnvps/telegram_group.conf
        config_dir = "/etc/dsnvps"
        config_file = os.path.join(config_dir, "telegram_group.conf")
        
        # Tạo thư mục /etc/dsnvps nếu chưa tồn tại
        if not os.path.exists(config_dir):
            try:
                os.makedirs(config_dir, exist_ok=True)
            except PermissionError:
                print(f"Lỗi: Không có quyền tạo thư mục {config_dir}. Chạy với sudo hoặc kiểm tra quyền.")
                exit(1)

        # Ghi thông tin vào file với validation
        group_type = "new" if choice == '1' else "existing"
        config_content = f"""[Telegram]
api_id={api_id}
api_hash={api_hash}
phone_number={phone_number}
group_id={group_id}
group_name="{group_name}"
group_type={group_type}
"""
        try:
            with open(config_file, 'w') as f:
                f.write(config_content)
            
            # Verify the written file
            if os.path.exists(config_file):
                pass  # File đã được tạo thành công
            else:
                print("==> Cảnh báo: File cấu hình có thể chưa được tạo đúng cách.")
                
        except PermissionError:
            print(f"Lỗi: Không có quyền ghi file {config_file}. Chạy với sudo hoặc kiểm tra quyền.")
            exit(1)
        except Exception as e:
            print(f"Lỗi khi ghi file: {e}")
            exit(1)

    except ValueError as ve:
        print(f"Lỗi định dạng group_id: {ve}")
        exit(1)
    except Exception as e:
        error_msg = str(e).lower()
        if "database is locked" in error_msg:
            print(f"ERROR: Lỗi kết nối Telegram: {str(e)}")
            print("Phát hiện database lock trong quá trình kết nối. Đang xử lý...")
            
            # Gọi fix_session_lock_compatible khi gặp database lock
            if fix_session_lock_compatible(session_file):
                print("Đã xử lý lock thành công. Thử kết nối lại...")
                print("Vui lòng chạy lại script để thử kết nối.")
            else:
                print("Không thể xử lý database lock. Vui lòng:")
                print("1. Kiểm tra có tiến trình telegram nào đang chạy: ps aux | grep telegram")
                print("2. Kill các tiến trình: pkill -f 'telegram'")
                print("3. Xóa file session: rm -f /etc/dsnvps/telegram.session*")
                print("4. Chạy lại cấu hình Telegram")
        else:
            print(f"Lỗi: {e}")
            print("Kiểm tra lại api_id, api_hash, số điện thoại, kết nối mạng hoặc giới hạn tài khoản Telegram.")
        exit(1)
    
    finally:
        await client.disconnect()
        print("Đã ngắt kết nối.")

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