import asyncio
import os
import sys
import configparser
import re
import socket
import math
import subprocess
import signal
import time
from datetime import datetime, timezone, timedelta
from telethon import TelegramClient
from telethon.errors import PeerIdInvalidError, ChatIdInvalidError, UserNotParticipantError, SessionPasswordNeededError
import sqlite3


def get_vn_time():
    utc_now = datetime.now(timezone.utc)
    vn_now = utc_now + timedelta(hours=7)
    return vn_now.strftime("%Y-%m-%d %H:%M:%S")

async def fix_session_lock(session_file='/etc/dsnvps/telegram.session'):
    """Check and handle lock on the session file"""
    try:
        print("Processing database lock...")
        
        try:
            try:
                result = subprocess.run(['which', 'lsof'], capture_output=True, text=True)
                lsof_available = result.returncode == 0
            except TypeError:
                result = subprocess.Popen(['which', 'lsof'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                stdout, stderr = result.communicate()
                lsof_available = result.returncode == 0
            except:
                lsof_available = False
            
            if lsof_available:
                cmd = ['lsof', session_file]
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True)
                    stdout = result.stdout
                    returncode = result.returncode
                except TypeError:
                    result = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                    stdout, stderr = result.communicate()
                    stdout = stdout.decode('utf-8')
                    returncode = result.returncode
                
                if returncode == 0:
                    current_pid = str(os.getpid())  # PID của script hiện tại
                    pids = []
                    for line in stdout.splitlines()[1:]:  # Bỏ header
                        parts = line.split()
                        if len(parts) > 1:
                            pid = parts[1]  # Cột PID
                            if pid != current_pid:
                                pids.append(pid)
                    
                    if pids:
                        for pid in pids:
                            try:
                                os.kill(int(pid), 0)  # Signal 0 chỉ kiểm tra, không kill
                                os.kill(int(pid), signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            except PermissionError:
                                pass
                            except Exception as e:
                                pass
                        
                        await asyncio.sleep(3)
                    else:
                        pass
                else:
                    print("No process is using the session file")
            else:
                print("WARNING: lsof is not available, trying to kill old telegram process")
                current_pid = str(os.getpid())
                try:
                    result = subprocess.run(['pgrep', '-f', 'dsnvps-upload-telegram.py'], capture_output=True, text=True)
                    if result.returncode == 0:
                        for pid in result.stdout.strip().split('\n'):
                            if pid and pid != current_pid:
                                try:
                                    os.kill(int(pid), signal.SIGKILL)
                                    print("Killed old telegram process PID: {}".format(pid))
                                except:
                                    pass
                        await asyncio.sleep(3)
                except:
                    pass
                    
        except Exception as e:
            print("WARNING: Error when killing process: {}".format(str(e)))

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

        try:
            import sqlite3
            conn = sqlite3.connect(session_file, timeout=15)
            conn.execute("PRAGMA journal_mode=DELETE")  # Tắt WAL mode
            conn.execute("PRAGMA synchronous=NORMAL")   # Giảm sync overhead
            conn.execute("PRAGMA wal_checkpoint(FULL)")
            conn.close()
        except Exception as e:
            pass

        try:
            import sqlite3
            conn = sqlite3.connect(session_file, timeout=10)
            conn.execute("PRAGMA quick_check")
            conn.close()
            return True
        except sqlite3.OperationalError as e:
            if "database is locked" in str(e).lower():
                print("WARNING: Database is still locked after handling. Trying final method...")
                
                try:
                    result = subprocess.run(['lsof', session_file], capture_output=True, text=True)
                    if result.returncode == 0:
                        current_pid = str(os.getpid())  # PID của script hiện tại
                        for line in result.stdout.splitlines()[1:]:
                            parts = line.split()
                            if len(parts) > 1:
                                pid = parts[1]
                                if pid != current_pid:
                                    try:
                                        subprocess.run(['kill', '-9', pid], check=True)
                                        print("Force kill PID: {}".format(pid))
                                    except:
                                        pass
                        await asyncio.sleep(2)
                except:
                    pass
                
                backup_file = "{}.backup.{}".format(session_file, int(time.time()))
                try:
                    import shutil
                    if os.path.exists(session_file):
                        shutil.copy2(session_file, backup_file)
                        os.remove(session_file)
                        print("Backed up session file to {} and removed original".format(backup_file))
                    return True
                except Exception as backup_error:
                    pass
            else:
                print("ERROR: Database error: {}".format(str(e)))
                return False

    except Exception as e:
        print("ERROR while handling lock: {}".format(str(e)))
        return False

async def auto_fix_telegram_connection():
    """Automatically check and fix Telegram connection"""
    max_retries = 4
    retry_count = 0
    base_delay = 3
    session_file = '/etc/dsnvps/telegram.session'
    
    while retry_count < max_retries:
        try:
            if os.path.exists(session_file):
                try:
                    conn = sqlite3.connect(session_file, timeout=15)
                    conn.execute("PRAGMA quick_check")
                    conn.close()
                except sqlite3.OperationalError as e:
                    if "database is locked" in str(e).lower():
                        print("WARNING: Session file is locked. Attempting to fix...")
                        if not await fix_session_lock(session_file):
                            print("ERROR: Unable to handle session lock.")
                            retry_count += 1
                            delay = base_delay * (2 ** retry_count)
                            print("Retry {}/{} after {}s...".format(retry_count, max_retries, delay))
                            await asyncio.sleep(delay)
                            continue
                        print("Lock fixed successfully. Continue checking connection...")
                    else:
                        print("ERROR: Session file error: {}".format(str(e)))
                        return False

            config = configparser.ConfigParser()
            config.read('/etc/dsnvps/telegram_group.conf')
            if 'Telegram' not in config:
                print("ERROR: Config file /etc/dsnvps/telegram_group.conf has no [Telegram] section")
                return False
            
            try:
                api_id = int(config['Telegram']['api_id'])
                api_hash = config['Telegram']['api_hash']
            except (KeyError, ValueError) as e:
                print("ERROR: Invalid Telegram configuration: {}".format(str(e)))
                return False

            try:
                client = TelegramClient(
                    session_file,
                    api_id,
                    api_hash,
                    connection_retries=3,
                    retry_delay=5,
                    auto_reconnect=True
                )
                await client.connect()
                
                if await client.is_user_authorized():
                    await client.disconnect()
                    return True
                else:
                    print("ERROR: Session is invalid or expired")
                    await client.disconnect()
                    return False
                    
            except Exception as telegram_error:
                error_msg = str(telegram_error).lower()
                if "database is locked" in error_msg:
                    print("ERROR: Telegram connection error: {}".format(str(telegram_error)))
                    print("Detected database lock during connection. Handling...")
                    
                    if await fix_session_lock(session_file):
                        print("Successfully handled lock. Retrying connection...")
                        retry_count += 1
                        delay = base_delay * (2 ** retry_count)
                        print("Retry {}/{} after {}s...".format(retry_count, max_retries, delay))
                        await asyncio.sleep(delay)
                        continue
                    else:
                        print("ERROR: Unable to handle database lock")
                        retry_count += 1
                        delay = base_delay * (2 ** retry_count)
                        print("Retry {}/{} after {}s...".format(retry_count, max_retries, delay))
                        await asyncio.sleep(delay)
                        continue
                else:
                    print("ERROR: Telegram connection error: {}".format(str(telegram_error)))
                    if "disk I/O error" in str(telegram_error).lower():
                        print("Detected disk I/O error. Backing up old session and creating a new one...")
                        try:
                            import shutil
                            backup_file = "{}.backup.{}".format(session_file, int(time.time()))
                            if os.path.exists(session_file):
                                shutil.copy2(session_file, backup_file)
                                os.remove(session_file)
                                print("Backed up old session and created a new one")
                        except Exception as backup_error:
                            print("WARNING: Cannot backup session: {}".format(str(backup_error)))
                    
                    retry_count += 1
                    delay = base_delay * (2 ** retry_count)
                    print("Retry {}/{} after {}s...".format(retry_count, max_retries, delay))
                    await asyncio.sleep(delay)
                    continue
                    
        except Exception as e:
            print("ERROR: {}".format(str(e)))
            retry_count += 1
            delay = base_delay * (2 ** retry_count)
            print("Retry {}/{} after {}s...".format(retry_count, max_retries, delay))
            await asyncio.sleep(delay)
            continue
        
        break

def check_session_lock(session_path):
    try:
        conn = sqlite3.connect(session_path, timeout=15)
        conn.execute("PRAGMA quick_check")
        conn.close()
        return True
    except sqlite3.OperationalError as e:
        if "database is locked" in str(e).lower():
            print("Error: Session file is locked - {}".format(e))
            print("-------------------------------------------------------------------------")
            print("TROUBLESHOOTING STEPS:")
            print("1. Check if any telegram process is running:")
            print("   ps aux | grep telegram")
            print("2. Kill running processes:")
            print("   pkill -f 'dsnvps-upload-telegram'")
            print("3. Remove session files and recreate:")
            print("   rm -f /etc/dsnvps/telegram.session*")
            print("   Run Telegram configuration again")
            print("-------------------------------------------------------------------------")
            return False
        else:
            print("Session file error: {}".format(e))
            return False
    except Exception as e:
        print("Unknown error when checking session: {}".format(e))
        return False

def read_config(config_file='/etc/dsnvps/telegram_group.conf'):
    config = configparser.ConfigParser()
    if not os.path.exists(config_file):
        print("Error: Config file {} not found.".format(config_file))
        sys.exit(1)
    config.read(config_file)
    if 'Telegram' not in config:
        print("Error: Config file {} has invalid format.".format(config_file))
        sys.exit(1)
    try:
        return {
            'api_id': int(config['Telegram']['api_id']),
            'api_hash': config['Telegram']['api_hash'],
            'phone_number': config['Telegram']['phone_number'],
            'group_id': int(config['Telegram']['group_id']),
            'group_name': config['Telegram'].get('group_name', "Group_{}".format(abs(int(config['Telegram']['group_id'])))).strip('"')
        }
    except KeyError as e:
        print("Error: Missing key {} in config file {}.".format(e, config_file))
        sys.exit(1)

def read_backup_config(config_file='/etc/dsnvps/backup.telegram.conf'):
    if not os.path.exists(config_file):
        print("Error: Config file {} not found.".format(config_file))
        sys.exit(1)

    try:
        raw = {}
        with open(config_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or line.startswith(';'):
                    continue
                if '=' in line:
                    k, v = line.split('=', 1)
                    raw[k.strip().lower()] = v.strip()

        sobanbackup_str = raw.get('sobanbackup')
        if sobanbackup_str is None:
            raise ValueError('Thiếu khóa sobanbackup')
        sobanbackup = int(sobanbackup_str)

        action = raw.get('action', 'keep').lower()
        if action not in ['keep', 'move']:
            action = 'keep'

        return {
            'sobanbackup': sobanbackup,
            'action': action
        }
    except Exception as e:
        print("Error: Config file {} is not in key=value format: {}".format(config_file, e))
        sys.exit(1)

def read_dsnvps_conf(config_file='/root/dsnvps.conf'):
    if not os.path.exists(config_file):
        print("Error: Config file {} not found. Dùng IP mặc định.".format(config_file))
        return socket.gethostbyname(socket.gethostname())
    try:
        with open(config_file, 'r') as f:
            content = f.read()
        
        serverip = None
        mainsite = None
        for line in content.split('\n'):
            line = line.strip()
            if line.startswith('serverip='):
                serverip = line.split('=', 1)[1].strip('"\'')
            elif line.startswith('mainsite='):
                mainsite = line.split('=', 1)[1].strip('"\'')
        
        return serverip or socket.gethostbyname(socket.gethostname())
    except Exception as e:
        print("Error reading file {}: {}. Using default IP.".format(config_file, e))
        return socket.gethostbyname(socket.gethostname())

def get_mainsite_from_dsnvps_conf(config_file='/root/dsnvps.conf'):
    if not os.path.exists(config_file):
        return None
    try:
        with open(config_file, 'r') as f:
            content = f.read()
        
        for line in content.split('\n'):
            line = line.strip()
            if line.startswith('mainsite='):
                return line.split('=', 1)[1].strip('"\'')
        
        return None
    except Exception as e:
        print("Error reading mainsite from {}: {}".format(config_file, e))
        return None

async def validate_group_id(client, group_id):
    try:
        entity = await client.get_entity(group_id)
        return True
    except (PeerIdInvalidError, ChatIdInvalidError, ValueError) as e:
        print("Error: Group ID {} is invalid - {}".format(group_id, e))
        return False
    except UserNotParticipantError:
        print("Error: Bot does not have access to group {}".format(group_id))
        return False
    except Exception as e:
        print("Unknown error when checking group {}: {}".format(group_id, e))
        return False

async def test_connection_and_permissions(client, group_id):
    try:
        test_msg = await client.send_message(group_id, "🔄 Test connection...")
        await asyncio.sleep(1)
        await client.delete_messages(group_id, test_msg.id)
        return True
    except Exception as e:
        print("Error: Cannot send message to group - {}".format(e))
        print("-------------------------------------------------------------------------")
        print("POSSIBLE REASONS:")
        print("• Bot lacks permission to send messages")
        print("• Group ID is incorrect")
        print("• Session has expired")
        print("• Bot was removed from the group")
        print("-------------------------------------------------------------------------")
        return False

def split_file(file_path, max_size_mb=1900):
    """
    Split a file into parts if its size exceeds max_size_mb
    Return the list of split files or the original file if no split is needed
    """
    file_size = os.path.getsize(file_path)
    max_size_bytes = max_size_mb * 1024 * 1024
    
    if file_size <= max_size_bytes:
        return [file_path], False  # No split needed, False = not a split file
    
    num_parts = math.ceil(file_size / max_size_bytes)
    part_files = []
    
    base_name = os.path.splitext(file_path)[0]
    extension = os.path.splitext(file_path)[1]
    
    print(" → Large file ({:.2f}MB), split into {} parts...".format(file_size / (1024*1024), num_parts))
    
    try:
        with open(file_path, 'rb') as source_file:
            for i in range(num_parts):
                part_filename = "{}.part{:03d}{}".format(base_name, i+1, extension)
                part_files.append(part_filename)
                
                with open(part_filename, 'wb') as part_file:
                    remaining = max_size_bytes
                    while remaining > 0:
                        chunk_size = min(8192, remaining)  # 8KB chunks
                        chunk = source_file.read(chunk_size)
                        if not chunk:
                            break
                        part_file.write(chunk)
                        remaining -= len(chunk)
                
                print("   Created part {}/{}: {}".format(i+1, num_parts, os.path.basename(part_filename)))
        
        return part_files, True  # True = file đã được chia
    except Exception as e:
        for part_file in part_files:
            if os.path.exists(part_file):
                os.remove(part_file)
        raise e

async def upload_file(client, group_id, local_file, item_name, file_type, total_uploaded, total_failed, uploaded_websites, uploaded_databases, failed_items, sobanbackup, action):
    filename = os.path.basename(local_file)
    upload_time = get_vn_time()
    file_size_mb = os.path.getsize(local_file) / (1024 * 1024)
    
    if file_type == "website":
        item_name = re.sub(r'-[0-9a-f]+\.zip$', '', filename)
    else:
        item_name = re.sub(r'-[0-9a-f]+\.sql\.gz$', '', filename)
    
    print("-------------------------------------------------------------------------")
    print("\033[31mProcessing {}: {}\033[0m".format(file_type, item_name))
    print(" → File: {}".format(filename))
    print(" → Backup time: {}".format(upload_time))
    
    try:
        files_to_upload, is_split = split_file(local_file)
        
        uploaded_parts = []
        for file_part in files_to_upload:
            part_filename = os.path.basename(file_part)
            part_size_mb = os.path.getsize(file_part) / (1024 * 1024)
            
            print(" → Uploading: {} ({:.2f}MB)".format(part_filename, part_size_mb))
            
            if is_split:
                caption = "Subfolder: {}/{}\nSplit: {}".format(item_name, filename, part_filename)
            else:
                caption = "Subfolder: {}/{}".format(item_name, filename)
            
            message = await client.send_file(
                group_id,
                file_part,
                caption=caption,
                progress_callback=lambda sent, total: print("\r   Progress: {}%".format(sent*100//total), end="", flush=True)
            )
            print("\n ==> Upload successful: {}".format(part_filename))
            uploaded_parts.append(part_filename)
        
        total_uploaded[0] += len(uploaded_parts) if is_split else 1
        if file_type == "website":
            uploaded_websites.append(item_name)
        else:
            uploaded_databases.append(item_name)
        
        if not is_split:
            messages_to_delete = []
            async for msg in client.iter_messages(group_id, limit=5000):
                if msg.document and msg.text:
                    match = re.search(r'Subfolder: ([^/]+)/', msg.text)
                    if match and match.group(1) == item_name and "Split:" not in msg.text:
                        messages_to_delete.append((msg.date, msg.id, msg.document.attributes[0].file_name))
            
            messages_to_delete.sort(reverse=True)
            if len(messages_to_delete) > sobanbackup:
                for _, msg_id, old_filename in messages_to_delete[sobanbackup:]:
                    await client.delete_messages(group_id, msg_id)
                    print(" → Deleted old backup: {}".format(old_filename))
        
        if action == "move":
            try:
                if is_split:
                    for file_part in files_to_upload:
                        if os.path.exists(file_part):
                            os.remove(file_part)
                            print(" → Deleted part file: {}".format(os.path.basename(file_part)))
                
                if os.path.exists(local_file):
                    os.remove(local_file)
                    print(" → Deleted local file: {}".format(filename))
            except Exception as e:
                print(" ==> File deletion error: {}".format(e))
        else:
            if is_split:
                try:
                    for file_part in files_to_upload:
                        if file_part != local_file and os.path.exists(file_part):
                            os.remove(file_part)
                            print(" → Deleted temporary part file: {}".format(os.path.basename(file_part)))
                except Exception as e:
                    print(" ==> Lỗi xóa file phần tạm: {}".format(e))
    
    except Exception as e:
        print("\n Upload error {}: {}".format(filename, e))
        failed_items.append("{}/{}".format(item_name, filename))
        total_failed[0] += 1
        return False
    
    return True

async def main():
    
    if not await auto_fix_telegram_connection():
        print("ERROR: Cannot connect to Telegram after attempting fixes")
        sys.exit(1)
    
    session_path = '/etc/dsnvps/telegram.session'
    if not os.path.exists(session_path):
        print("Error: Session file {} does not exist.".format(session_path))
        print("Please rerun [Connect VPS to Telegram] to create a new session.")
        sys.exit(1)
    
    if not check_session_lock(session_path):
        sys.exit(1)
    
    try:
        config = read_config()
        backup_config = read_backup_config()
    except SystemExit:
        sys.exit(1)
    
    api_id = config['api_id']
    api_hash = config['api_hash']
    phone_number = config['phone_number']
    group_id = config['group_id']
    group_name = config['group_name']
    sobanbackup = backup_config['sobanbackup']
    action = backup_config['action']
    server_ip = read_dsnvps_conf()
    mainsite = get_mainsite_from_dsnvps_conf()
    
    client = TelegramClient(
        session_path,
        api_id,
        api_hash,
        connection_retries=3,
        retry_delay=5,
        auto_reconnect=True
    )
    
    try:
        await client.connect()
        
        if not await client.is_user_authorized():
            print("Error: Session is invalid or expired.")
            print("Delete the session file and rerun Telegram setup:")
            print("rm -f {}".format(session_path))
            await client.disconnect()
            sys.exit(1)
        
        if not await validate_group_id(client, group_id):
            await client.disconnect()
            sys.exit(1)
        
        if not await test_connection_and_permissions(client, group_id):
            await client.disconnect()
            sys.exit(1)
        
        upload_time = get_vn_time()
        await client.send_message(group_id, "Upload backup VPS {} - Group_id: {} lúc {}".format(group_name, group_id, upload_time))
        
        total_uploaded = [0]
        total_failed = [0]
        uploaded_websites = []
        uploaded_databases = []
        failed_items = []
        
        if mainsite:
            backup_base_dir = "/home/{}/private_html/backup".format(mainsite)
        else:
            backup_base_dir = "/home/{}/private_html/backup".format(server_ip.replace('.', '_'))
            
        if not os.path.exists(backup_base_dir):
            print("==> Error: Thư mục backup {} không tồn tại.".format(backup_base_dir))
            await client.send_message(group_id, "==> Error: Backup directory not found")
            await client.disconnect()
            sys.exit(1)
        
        print("=> Scanning backup files to upload...")
        
        total_files = 0
        for backup_subfolder in os.listdir(backup_base_dir):
            subfolder_path = os.path.join(backup_base_dir, backup_subfolder)
            if os.path.isdir(subfolder_path):
                total_files += len([f for f in os.listdir(subfolder_path) if f.endswith('.zip') or f.endswith('.gz')])
        
        if total_files == 0:
            print("⚠️  No backup files found!")
            await client.send_message(group_id, "⚠️  No backup files found to upload")
            await client.disconnect()
            sys.exit(0)
        
        print("=> Found {} files to upload".format(total_files))
        
        upload_success = True
        for backup_subfolder in sorted(os.listdir(backup_base_dir)):
            subfolder_path = os.path.join(backup_base_dir, backup_subfolder)
            if not os.path.isdir(subfolder_path):
                continue
            
            for zip_file in sorted(os.listdir(subfolder_path)):
                if zip_file.endswith('.zip'):
                    zip_path = os.path.join(subfolder_path, zip_file)
                    result = await upload_file(client, group_id, zip_path, None, "website", total_uploaded, total_failed, uploaded_websites, uploaded_databases, failed_items, sobanbackup, action)
                    if not result:
                        upload_success = False
            
            for gz_file in sorted(os.listdir(subfolder_path)):
                if gz_file.endswith('.gz'):
                    gz_path = os.path.join(subfolder_path, gz_file)
                    result = await upload_file(client, group_id, gz_path, None, "database", total_uploaded, total_failed, uploaded_websites, uploaded_databases, failed_items, sobanbackup, action)
                    if not result:
                        upload_success = False
        
        if upload_success and total_failed[0] == 0:
            status_icon = "==>"
            status_text = "Backup completed successfully"
        else:
            status_icon = "==>"
            status_text = "Backup completed with {} errors".format(total_failed[0])
        
        MESSAGE = "{} **Statistics**\n\n".format(status_icon)
        MESSAGE += "• Upload successful: **{}** file(s)\n".format(total_uploaded[0])
        MESSAGE += "• Upload thất bại: **{}** file(s)\n".format(total_failed[0])
        
        if uploaded_websites:
            MESSAGE += "\n==> **Backed up websites:**\n"
            for website in uploaded_websites:
                MESSAGE += "• {}\n".format(website)
        
        if uploaded_databases:
            MESSAGE += "\n==> **Backed up databases:**\n"
            for database in uploaded_databases:
                MESSAGE += "• {}\n".format(database)
        
        if failed_items:
            MESSAGE += "\n **Failed backups:**\n"
            for failed_item in failed_items:
                MESSAGE += "• {}\n".format(failed_item)
        
        MESSAGE += "\n==> **Status:** {}\n".format(status_text)
        MESSAGE += "==> **Group ID:** {}\n".format(group_id)
        MESSAGE += "==> **Time:** {}".format(get_vn_time())
        
        await client.send_message(group_id, MESSAGE)
        
        print("=" * 70)
        if upload_success and total_failed[0] == 0:
            print("==> COMPLETED BACKUP UPLOAD TO TELEGRAM!")
        else:
            print("UPLOAD COMPLETED WITH {} ERRORS!".format(total_failed[0]))
        print("Tổng file đã upload: {}".format(total_uploaded[0]))
        print("Tổng file thất bại: {}".format(total_failed[0]))
        print("=" * 70)
        
        if total_failed[0] > 0:
            sys.exit(1)
    
    except SessionPasswordNeededError:
        print("==> Error: Telegram account requires 2FA. Please disable 2FA or reconfigure.")
        await client.disconnect()
        sys.exit(1)
    except Exception as e:
        print("==> Critical error: {}".format(e))
        try:
            await client.send_message(group_id, "==> Critical error khi backup: {}".format(e))
        except:
            print("Cannot send error notification to the group.")
        await client.disconnect()
        sys.exit(1)
    
    finally:
        await client.disconnect()

if __name__ == '__main__':
    try:
        asyncio.run(main())
    except AttributeError:
        loop = asyncio.get_event_loop()
        try:
            loop.run_until_complete(main())
        finally:
            loop.close()