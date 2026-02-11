import socket
import threading
import json
import jwt
import os
import time
from chat_history_manager import ChatHistoryManager

# Centralized JWT secret (shared with unified_server)
JWT_SECRET = os.getenv("JWT_SECRET", "jwt-secret-change-me")
JWT_ALGORITHM = "HS256"

def get_lan_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        lan_ip = s.getsockname()[0]
        s.close()
        return lan_ip
    except Exception:
        return "127.0.0.1"

IP_address = get_lan_ip()
Port = 5050
BufferSize = 8192  

server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

# Initialize chat history manager
chat_history = ChatHistoryManager(db_api_url="http://localhost:5001/api")

try:
    server_socket.bind(("0.0.0.0", Port))
    server_socket.listen()
    print("=" * 60)
    print("      SAJILO CHAT SERVER (E2EE ENABLED)")
    print("=" * 60)
    print(f"Server is listening on {IP_address}:{Port}")
    print(f"Database API: {chat_history.db_api_url}")
    print(f"Buffer Size: {BufferSize} bytes")
    print("Features: End-to-End Encryption, File Transfer, Group Chat")
    print("Waiting for connections...")
    print("=" * 60)
except OSError as e:
    print(f"Error binding to port: {e}")
    exit()

clients = {}
clients_lock = threading.Lock()


class FileTransferContext:
    """Context object for managing file transfers"""
    def __init__(self, file_id, sender, receiver, file_name, file_size):
        self.file_id = file_id
        self.sender = sender
        self.receiver = receiver
        self.file_name = file_name
        self.file_size = file_size
        self.bytes_relayed = 0
        self.start_time = time.time()
        self.receiver_socket = None
    
    def is_expired(self, timeout=60):
        """Check if transfer has timed out"""
        return time.time() - self.start_time > timeout
    
    def progress_percent(self):
        """Get transfer progress as percentage"""
        return int((self.bytes_relayed / self.file_size) * 100) if self.file_size > 0 else 0

active_transfers = {}
transfers_lock = threading.Lock()


def broadcast(message_data, exclude_user=None):
    """Send message to all connected clients except exclude_user"""
    with clients_lock:
        for username, client in clients.items():
            if username != exclude_user:
                try:
                    json_msg = json.dumps(message_data) + '\n'
                    client.send(json_msg.encode('utf-8'))
                except:
                    pass


def send_to_user(username, message_data):
    """Send message to a specific user"""
    with clients_lock:
        if username in clients:
            try:
                json_msg = json.dumps(message_data) + '\n'
                clients[username].send(json_msg.encode('utf-8'))
                return True
            except:
                return False
        return False


def send_user_list():
    """Send updated user list to all clients"""
    with clients_lock:
        user_list = list(clients.keys())
    
    message_data = {
        'type': 'user_list',
        'users': user_list
    }
    print(f"[USER_LIST] Broadcasting: {user_list}")
    broadcast(message_data)


def cleanup_transfer(transfer_id, reason="completed"):
    """Clean up transfer state with proper locking"""
    with transfers_lock:
        if transfer_id in active_transfers:
            transfer = active_transfers[transfer_id]
            print(f"[FILE_CLEANUP] Removing transfer {transfer_id} ({reason})")
            print(f"[FILE_CLEANUP]   Sender: {transfer.sender}")
            print(f"[FILE_CLEANUP]   Receiver: {transfer.receiver}")
            print(f"[FILE_CLEANUP]   Progress: {transfer.bytes_relayed}/{transfer.file_size} bytes")
            
            # Remove from both sender and receiver locks
            sender_key = f"{transfer.sender}_send"
            receiver_key = f"{transfer.receiver}_recv"
            
            if sender_key in active_transfers:
                del active_transfers[sender_key]
            if receiver_key in active_transfers:
                del active_transfers[receiver_key]
            
            del active_transfers[transfer_id]


def handle(client, username):
    """Handle messages from a client"""
    buffer = ""
    
    # File transfer state
    current_transfer = None
    in_file_transfer = False
    
    # Timeout checker thread for this client
    def check_transfer_timeout():
        """Background thread to check for transfer timeouts"""
        while True:
            time.sleep(5)  # Check every 5 seconds
            
            if current_transfer and current_transfer.is_expired():
                print(f"[FILE_TIMEOUT] Transfer {current_transfer.file_id} timed out!")
                
                # Send error to both parties
                error_msg = {
                    'type': 'error',
                    'message': 'File transfer timed out'
                }
                
                try:
                    client.send((json.dumps(error_msg) + '\n').encode('utf-8'))
                except:
                    pass
                
                if current_transfer.receiver_socket:
                    try:
                        current_transfer.receiver_socket.send(
                            (json.dumps(error_msg) + '\n').encode('utf-8')
                        )
                    except:
                        pass
                
                cleanup_transfer(current_transfer.file_id, "timeout")
                return  # Exit timeout checker
    
    while True:
        try:
            chunk = client.recv(BufferSize)
            if not chunk:
                print(f"[INFO] {username} connection closed")
                break
            
            # FILE TRANSFER MODE: Binary relay
            if in_file_transfer and current_transfer:
                try:
                    # Calculate remaining bytes needed
                    remaining = current_transfer.file_size - current_transfer.bytes_relayed
                    
                    if remaining <= 0:
                        # All file data received, this must be control frame
                        print(f"[FILE_RELAY] Transfer complete, switching to JSON mode")
                        in_file_transfer = False
                        buffer = chunk.decode('utf-8', errors='ignore')
                        continue
                    
                    # Determine how much of this chunk is file data
                    bytes_to_relay = min(len(chunk), remaining)
                    
                    if bytes_to_relay > 0:
                        # Relay file data to receiver
                        file_data = chunk[:bytes_to_relay]
                        current_transfer.receiver_socket.send(file_data)
                        current_transfer.bytes_relayed += bytes_to_relay
                        
                        # Log progress
                        progress = current_transfer.progress_percent()
                        if progress % 10 == 0 or current_transfer.bytes_relayed >= current_transfer.file_size:
                            print(f"[FILE_RELAY] {current_transfer.file_name}: "
                                  f"{current_transfer.bytes_relayed}/{current_transfer.file_size} bytes ({progress}%)")
                    
                    # Check if transfer complete
                    if current_transfer.bytes_relayed >= current_transfer.file_size:
                        print(f"[FILE_RELAY]   Complete: {current_transfer.file_name} "
                              f"({current_transfer.bytes_relayed} bytes)")
                        
                        # Switch back to JSON mode
                        in_file_transfer = False
                        
                        # Any remaining data in chunk is the end frame
                        if bytes_to_relay < len(chunk):
                            buffer = chunk[bytes_to_relay:].decode('utf-8', errors='ignore')
                        else:
                            buffer = ""

                    
                    continue
                    
                except Exception as e:
                    print(f"[ERROR] File relay failed: {e}")
                    
                    # Send error to both parties
                    error_data = {
                        'type': 'error',
                        'message': f'File transfer failed: {e}'
                    }
                    
                    try:
                        client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                    except:
                        pass
                    
                    if current_transfer and current_transfer.receiver_socket:
                        try:
                            current_transfer.receiver_socket.send(
                                (json.dumps(error_data) + '\n').encode('utf-8')
                            )
                        except:
                            pass
                    
                    if current_transfer:
                        cleanup_transfer(current_transfer.file_id, f"error: {e}")
                    
                    in_file_transfer = False
                    current_transfer = None
                    buffer = ""
                    continue
            
            # NORMAL MODE: JSON message processing
            buffer += chunk.decode('utf-8', errors='ignore')
            
            while '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                line = line.strip()
                
                if not line:
                    continue
                
                try:
                    message_data = json.loads(line)
                    message_type = message_data.get('type')
                    
                    # Handle file transfer initiation
                    if message_type == 'file_transfer_start':
                        recipient = message_data.get('receiver')
                        file_name = message_data.get('file_name')
                        file_size = message_data.get('file_size')
                        file_id = message_data.get('file_id')
                        
                        print(f"[FILE_START] {username} → {recipient}: '{file_name}' ({file_size} bytes)")
                        
                        # Check if sender already has an active transfer
                        sender_key = f"{username}_send"
                        receiver_key = f"{recipient}_recv"
                        
                        with transfers_lock:
                            if sender_key in active_transfers:
                                error = {
                                    'type': 'error',
                                    'message': 'You already have an active file transfer'
                                }
                                client.send((json.dumps(error) + '\n').encode('utf-8'))
                                print(f"[FILE_START]  {username} already sending a file")
                                continue
                            
                            if receiver_key in active_transfers:
                                error = {
                                    'type': 'error',
                                    'message': f'{recipient} is already receiving a file'
                                }
                                client.send((json.dumps(error) + '\n').encode('utf-8'))
                                print(f"[FILE_START]  {recipient} already receiving a file")
                                continue
                            
                            # Get receiver socket
                            with clients_lock:
                                if recipient not in clients:
                                    error = {
                                        'type': 'error',
                                        'message': f'{recipient} is not online'
                                    }
                                    client.send((json.dumps(error) + '\n').encode('utf-8'))
                                    print(f"[FILE_START] {recipient} not online")
                                    continue
                                
                                receiver_socket = clients[recipient]
                            
                            # Create transfer context
                            current_transfer = FileTransferContext(
                                file_id=file_id,
                                sender=username,
                                receiver=recipient,
                                file_name=file_name,
                                file_size=file_size
                            )
                            current_transfer.receiver_socket = receiver_socket
                            
                            # Lock both users
                            active_transfers[file_id] = current_transfer
                            active_transfers[sender_key] = current_transfer
                            active_transfers[receiver_key] = current_transfer
                        
                        # Forward metadata to receiver
                        metadata = {
                            'type': 'file_transfer_start',
                            'file_id': file_id,
                            'file_name': file_name,
                            'file_size': file_size,
                            'sender': username,
                            'receiver': recipient,
                            'checksum': message_data.get('checksum'),
                        }
                        
                        receiver_socket.send((json.dumps(metadata) + '\n').encode('utf-8'))
                        
                        print(f"[FILE_START] ✓ Metadata forwarded, entering relay mode")
                        print(f"[FILE_START]   Expecting {file_size} bytes")
                        
                        # Enter binary relay mode
                        in_file_transfer = True
                        
                        # Start timeout checker
                        timeout_thread = threading.Thread(
                            target=check_transfer_timeout,
                            daemon=True
                        )
                        timeout_thread.start()
                    
                    # Handle file transfer end
                    elif message_type == 'file_transfer_end':
                        file_id = message_data.get('file_id')
                        status = message_data.get('status')
                        
                        print(f"[FILE_END] End frame received for {file_id}: {status}")
                        
                        # Forward end frame to receiver if transfer exists
                        if current_transfer and current_transfer.file_id == file_id:
                            try:
                                current_transfer.receiver_socket.send(
                                    (json.dumps(message_data) + '\n').encode('utf-8')
                                )
                                print(f"[FILE_END] ✓ End frame forwarded to {current_transfer.receiver}")
                            except Exception as e:
                                print(f"[FILE_END]  Failed to forward end frame: {e}")
                            
                            # Cleanup
                            cleanup_transfer(file_id, "completed successfully")
                            current_transfer = None
                        else:
                            print(f"[FILE_END]  No matching transfer for {file_id}")
                    
                    # Handle group chat messages
                    elif message_type == 'group':
                        msg_text = message_data.get('message', '')
                        timestamp = message_data.get('timestamp', '')
                        
                        print(f"[GROUP] {username}: {msg_text}")
                        
                        # Broadcast to all except sender
                        group_msg = {
                            'type': 'group',
                            'from': username,
                            'message': msg_text,
                            'timestamp': timestamp
                        }
                        broadcast(group_msg, exclude_user=username)
                        
                        # Save to database
                        chat_history.save_encrypted_message(
                            sender=username,
                            recipient='group',
                            encrypted_data={
                                'ciphertext': msg_text,
                                'nonce': '',
                                'mac': ''
                            },
                            msg_type='group'
                        )
                    
                    # Handle direct messages (encrypted)
                    elif message_type == 'dm':
                        recipient = message_data.get('to')
                        msg_text = message_data.get('message', '')
                        encrypted_data = message_data.get('encrypted_data')
                        
                        # Forward to recipient
                        dm_data = {
                            'type': 'dm',
                            'from': username,
                            'to': recipient,
                            'message': msg_text if msg_text else '[Encrypted Message]',
                            'encrypted_data': encrypted_data,
                            'timestamp': message_data.get('timestamp', '')
                        }
                        
                        if send_to_user(recipient, dm_data):
                            # Send confirmation to sender
                            confirmation = {
                                'type': 'dm',
                                'from': username,
                                'to': recipient,
                                'message': msg_text if msg_text else '[Encrypted Message]',
                                'encrypted_data': encrypted_data,
                                'sent': True
                            }
                            client.send((json.dumps(confirmation) + '\n').encode('utf-8'))
                            
                            # Save to database
                            if encrypted_data:
                                chat_history.save_encrypted_message(
                                    sender=username,
                                    recipient=recipient,
                                    encrypted_data=encrypted_data,
                                    msg_type='dm'
                                )
                            
                            print(f"[DM] {username} → {recipient}: [Encrypted]")
                        else:
                            error_data = {
                                'type': 'error',
                                'message': f'User {recipient} not found or offline'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                    
                    # Handle user list request
                    elif message_type == 'request_users':
                        send_user_list()
                    
                    # Handle history request
                    elif message_type == 'request_history':
                        chat_with = message_data.get('chat_with')
                        
                        messages = chat_history.get_message_history(
                            username=username,
                            chat_with=chat_with,
                            limit=100
                        )
                        
                        if messages is not None:
                            history_msg = {
                                'type': 'history',
                                'chat_with': chat_with,
                                'messages': messages
                            }
                            client.send((json.dumps(history_msg) + '\n').encode('utf-8'))
                            print(f"[HISTORY] Sent {len(messages)} messages to {username}")
                        else:
                            print(f"[ERROR] Failed to fetch history for {username}")
                    
                    # Handle typing indicators
                    elif message_type == 'typing':
                        to_user = message_data.get('to')
                        
                        typing_data = {
                            'type': 'typing',
                            'from': username,
                            'to': to_user
                        }
                        
                        if to_user == 'group':
                            broadcast(typing_data, exclude_user=username)
                        else:
                            send_to_user(to_user, typing_data)
                    
                except json.JSONDecodeError as e:
                    print(f"[ERROR] JSON decode error from {username}: {e}")
                    print(f"[ERROR] Problematic line: {line[:100]}...")
                    
        except Exception as e:
            print(f"[ERROR] Error handling {username}: {e}")
            break
    
    # Cleanup on disconnect
    print(f"[CLEANUP] Cleaning up {username}")
    
    # Clean up any active transfers
    if current_transfer:
        cleanup_transfer(current_transfer.file_id, "user disconnected")
    
    with clients_lock:
        if username in clients:
            del clients[username]
            print(f"[DISCONNECT] {username} disconnected")
    
    disconnect_data = {
        'type': 'system',
        'message': f'{username} left the chat'
    }
    broadcast(disconnect_data)
    send_user_list()
    
    try:
        client.close()
    except:
        pass


def receive():
    """Accept new client connections"""
    while True:
        try:
            client, address = server_socket.accept()
            print(f"\n[CONNECTION] New connection from {address[0]}:{address[1]}")

            json_msg = json.dumps({'type': 'request_auth'}) + '\n'
            client.send(json_msg.encode('utf-8'))
            
            client.settimeout(10.0)
            
            try:
                data = b''
                while b'\n' not in data:
                    chunk = client.recv(1024)
                    if not chunk:
                        client.close()
                        break
                    data += chunk
                
                if b'\n' not in data:
                    continue
                
                message = data.decode('utf-8').strip()
                auth_data = json.loads(message)
                token = auth_data.get("token")

                if not token:
                    client.send(json.dumps({
                        "type": "error",
                        "message": "Missing token"
                    }).encode())
                    client.close()
                    continue

                try:
                    payload = jwt.decode(
                        token,
                        JWT_SECRET,
                        algorithms=[JWT_ALGORITHM]
                    )
                    username = payload["sub"]
                except jwt.ExpiredSignatureError:
                    client.send(json.dumps({
                        "type": "error",
                        "message": "Token expired"
                    }).encode())
                    client.close()
                    continue
                except jwt.InvalidTokenError:
                    client.send(json.dumps({
                        "type": "error",
                        "message": "Invalid token"
                    }).encode())
                    client.close()
                    continue

                if not username:
                    client.close()
                    continue
                
                with clients_lock:
                    if username in clients:
                        error = json.dumps({
                            'type': 'error',
                            'message': 'Username already taken'
                        }) + '\n'
                        client.send(error.encode('utf-8'))
                        client.close()
                        continue
                    
                    clients[username] = client
                
                client.settimeout(None)
                
                print(f"[LOGIN] ✓ {username} logged in")
                
                welcome = json.dumps({
                    'type': 'system',
                    'message': f'Welcome to the server, {username}!'
                }) + '\n'
                client.send(welcome.encode('utf-8'))
                
                broadcast({
                    'type': 'system',
                    'message': f'{username} joined the chat'
                }, exclude_user=username)
                
                send_user_list()
                
                thread = threading.Thread(target=handle, args=(client, username), daemon=True)
                thread.start()
                
            except Exception as e:
                print(f"[ERROR] Handshake error: {e}")
                client.close()
                
        except KeyboardInterrupt:
            print("\n[SHUTDOWN] Server shutting down...")
            break
        except Exception as e:
            print(f"[ERROR] Accept error: {e}")


if __name__ == "__main__":
    try:
        receive()
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Server stopped")
    finally:
        server_socket.close()