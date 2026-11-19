import sys
import asyncio
import os
import subprocess
import signal
import time
import sqlite3
from telethon import TelegramClient
import configparser

async def fix_session_lock(session_file='/etc/dsnvps/telegram.session'):
    """Kiểm tra và xử lý lock trên file session"""
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
                        current_pid = str(os.getpid())  # PID của script hiện tại
                        pids = []
                        lines = stdout.splitlines()
                        for line in lines[1:]:  # Bỏ header
                            parts = line.split()
                            if len(parts) > 1:
                                pid = parts[1]  # Cột PID
                                # Không kill chính script này
                                if pid != current_pid:
                                    pids.append(pid)
                        
                        # Kill các process lock (trừ chính script này)
                        if pids:
                            for pid in pids:
                                try:
                                    # Kiểm tra process có thực sự tồn tại không
                                    os.kill(int(pid), 0)  # Signal 0 chỉ kiểm tra, không kill
                                    os.kill(int(pid), signal.SIGKILL)
                                except ProcessLookupError:
                                    pass
                                except PermissionError:
                                    pass
                                except Exception as e:
                                    pass
                            
                            # Đợi 3s để đảm bảo process đã chết
                            await asyncio.sleep(3)
                        else:
                            pass
                    else:
                        print("Không có process nào đang sử dụng session file")
                except Exception as e:
                    print("WARNING: Lỗi khi sử dụng lsof: {}".format(str(e)))
            else:
                print("WARNING: lsof không có sẵn, thử kill process telegram cũ")
                # Fallback: kill các process telegram cũ (nhưng không kill script hiện tại)
                current_pid = str(os.getpid())
                try:
                    # Tìm các process python có chứa telegram (nhưng không phải script hiện tại)
                    try:
                        # Python 3.7+
                        result = subprocess.run(['pgrep', '-f', 'checktelegram.py'], capture_output=True, text=True)
                        stdout = result.stdout
                        returncode = result.returncode
                    except TypeError:
                        # Python 3.6
                        result = subprocess.Popen(['pgrep', '-f', 'checktelegram.py'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        stdout, stderr = result.communicate()
                        stdout = stdout.decode('utf-8')
                        returncode = result.returncode
                    
                    if returncode == 0:
                        for pid in stdout.strip().split('\n'):
                            if pid and pid != current_pid:
                                try:
                                    os.kill(int(pid), signal.SIGKILL)
                                    print("Đã kill process telegram cũ PID: {}".format(pid))
                                except:
                                    pass
                        await asyncio.sleep(3)
                except:
                    pass
                    
        except Exception as e:
            print(f"WARNING: Lỗi khi kill process: {str(e)}")

        # Bước 2: Xóa các file lock SQLite
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
            import sqlite3
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
                        await asyncio.sleep(2)
                        
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

async def check_telegram_connection():
    max_retries = 5
    retry_count = 0
    
    while retry_count < max_retries:
        try:
            # Kiểm tra và xử lý lock trước
            session_file = '/etc/dsnvps/telegram.session'
            if os.path.exists(session_file):
                try:
                    # Thử mở file session để kiểm tra lock với timeout dài hơn
                    import sqlite3
                    conn = sqlite3.connect(session_file, timeout=10)
                    conn.execute("PRAGMA quick_check")
                    conn.close()
                except sqlite3.OperationalError as e:
                    if "database is locked" in str(e).lower():
                        print("WARNING: File session bị khóa. Đang cố gắng fix...")
                        if not await fix_session_lock(session_file):
                            print("ERROR: Không thể xử lý lock session.")
                            if retry_count < max_retries - 1:
                                retry_count += 1
                                print(f"Thử lại lần {retry_count + 1}/{max_retries}...")
                                if retry_count <= 3:
                                    await asyncio.sleep(3)
                                else:
                                    await asyncio.sleep(5)
                                continue
                            else:
                                sys.exit(1)
                        print("Fix lock thành công. Tiếp tục kiểm tra kết nối...")
                    else:
                        print(f"ERROR: Lỗi session file: {str(e)}")
                        sys.exit(1)

            # Đọc file cấu hình
            config = configparser.ConfigParser()
            config.read('/etc/dsnvps/telegram_group.conf')
            if 'Telegram' not in config:
                print("ERROR: File cấu hình /etc/dsnvps/telegram_group.conf không có section [Telegram]")
                sys.exit(1)
            
            try:
                api_id = int(config['Telegram']['api_id'])
                api_hash = config['Telegram']['api_hash']
            except (KeyError, ValueError) as e:
                print(f"ERROR: Cấu hình Telegram không hợp lệ: {str(e)}")
                sys.exit(1)

            # Kiểm tra kết nối Telegram với timeout
            try:
                client = TelegramClient(session_file, api_id, api_hash,
                                      connection_retries=2,
                                      retry_delay=3)
                await client.connect()
                
                if await client.is_user_authorized():
                    print("OK")
                    await client.disconnect()
                    return
                else:
                    print("ERROR: Session không hợp lệ hoặc đã hết hạn")
                    await client.disconnect()
                    sys.exit(1)
                    
            except Exception as telegram_error:
                error_msg = str(telegram_error).lower()
                if "database is locked" in error_msg:
                    print("Phát hiện lỗi kết nối. Đang xử lý...")
                    
                    # Gọi fix_session_lock khi gặp database lock
                    if await fix_session_lock(session_file):
                        print("đang xử lý...")
                        print("Xử lý thành công. Hãy kết nối lại.")
                        sys.exit(0)  # Thoát thành công
                    else:
                        print("ERROR: Không thể xử lý database lock")
                        if retry_count < max_retries - 1:
                            retry_count += 1
                            print(f"Thử lại lần {retry_count + 1}/{max_retries}...")
                            if retry_count <= 3:
                                await asyncio.sleep(3)
                            else:
                                await asyncio.sleep(5)
                            continue
                        else:
                            sys.exit(1)
                else:
                    print(f"ERROR: Lỗi kết nối Telegram: {str(telegram_error)}")
                    # Xử lý disk I/O error
                    if "disk I/O error" in str(telegram_error).lower():
                        print("Phát hiện disk I/O error. Đang backup session cũ và tạo mới...")
                        try:
                            # Disconnect client hiện tại nếu có
                            if 'client' in locals():
                                try:
                                    await client.disconnect()
                                except:
                                    pass
                            
                            import shutil
                            backup_file = f"{session_file}.backup.{int(time.time())}"
                            if os.path.exists(session_file):
                                shutil.copy2(session_file, backup_file)
                                os.remove(session_file)
                                print("Đã backup session cũ và tạo session mới")
                            
                            # Tạo client mới
                            config = configparser.ConfigParser()
                            config.read('/etc/dsnvps/telegram_group.conf')
                            api_id = config.getint('Telegram', 'api_id')
                            api_hash = config.get('Telegram', 'api_hash')
                            
                            client = TelegramClient(session_file, api_id, api_hash)
                            await client.connect()
                            print("Đã tạo client mới và kết nối")
                            
                        except Exception as backup_error:
                            print(f"WARNING: Không thể backup session: {str(backup_error)}")
                    
                    if retry_count < max_retries - 1:
                        retry_count += 1
                        print(f"Thử lại lần {retry_count + 1}/{max_retries}...")
                        if retry_count <= 3:
                            await asyncio.sleep(3)
                        else:
                            await asyncio.sleep(5)
                        continue
                    else:
                        sys.exit(1)
                    
        except Exception as e:
            print(f"ERROR: {str(e)}")
            if retry_count < max_retries - 1:
                retry_count += 1
                print(f"Thử lại lần {retry_count + 1}/{max_retries}...")
                if retry_count <= 3:
                    await asyncio.sleep(3)
                else:
                    await asyncio.sleep(5)
                continue
            else:
                sys.exit(1)
        
        # Nếu đến đây thì thành công, thoát khỏi loop
        break

if __name__ == '__main__':
    # Tương thích với Python cũ (3.6 và trước đó)
    try:
        # Python 3.7+
        asyncio.run(check_telegram_connection())
    except AttributeError:
        # Python 3.6 và cũ hơn
        loop = asyncio.get_event_loop()
        try:
            loop.run_until_complete(check_telegram_connection())
        finally:
            loop.close()