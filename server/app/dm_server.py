import socket
import threading
import json
import jwt
import os
import time
import struct
from dotenv import load_dotenv

# Load environment variables from .env if present
load_dotenv()
from chat_history_manager import ChatHistoryManager

# Configuration - use environment variables for security
JWT_SECRET = os.getenv("JWT_SECRET_KEY", "jwt-dev-secret")  # FIXED: Match unified_server
JWT_ALGORITHM = "HS256"
BUFFER_SIZE = int(os.getenv("BUFFER_SIZE", "4096"))  # FIXED: Configurable
MAX_MESSAGE_SIZE = int(os.getenv("MAX_MESSAGE_SIZE", "10240"))  # FIXED: 10KB limit
FILE_TRANSFER_TIMEOUT = int(os.getenv("FILE_TRANSFER_TIMEOUT", "300"))  # FIXED: 5 min timeout

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

server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

# Initialize chat history manager
chat_history = ChatHistoryManager(db_api_url="http://localhost:5001/api")

try:
    server_socket.bind(("0.0.0.0", Port))
    server_socket.listen()
    print("=" * 60)
    print("         SAJILO CHAT SERVER (WITH HISTORY)")
    print("=" * 60)
    print(f"[SERVER] Listening on {IP_address}:{Port}")
    print(f"[SERVER] Database API: {chat_history.db_api_url}")
    print(f"[SERVER] JWT Secret: {JWT_SECRET[:10]}...")
    print(f"[SERVER] Buffer Size: {BUFFER_SIZE} bytes")
    print(f"[SERVER] Max Message Size: {MAX_MESSAGE_SIZE} bytes")
    print("=" * 60)
except OSError as e:
    print(f"[ERROR] Error binding to port: {e}")
    exit()

clients = {}
clients_lock = threading.Lock()


def broadcast(message_data, exclude_user=None):
    """Send message to all connected clients except exclude_user"""
    with clients_lock:
        disconnected = []
        for username, client in clients.items():
            if username != exclude_user:
                try:
                    json_msg = json.dumps(message_data) + '\n'
                    client.send(json_msg.encode('utf-8'))
                except Exception as e:
                    print(f"[ERROR] Failed to send to {username}: {e}")
                    disconnected.append(username)
        
        # Clean up disconnected clients
        for username in disconnected:
            if username in clients:
                del clients[username]


def send_to_user(username, message_data):
    """Send message to a specific user"""
    with clients_lock:
        if username in clients:
            try:
                json_msg = json.dumps(message_data) + '\n'
                clients[username].send(json_msg.encode('utf-8'))
                return True
            except Exception as e:
                print(f"[ERROR] Failed to send to {username}: {e}")
                # Remove disconnected client
                if username in clients:
                    del clients[username]
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


def handle(client, username):
    """Handle messages from a client"""
    buffer = b""
    
    # File transfer state tracking
    file_metadata = None
    receiver_socket = None
    bytes_relayed = 0
    transfer_start_time = None  # FIXED: Add timeout tracking
    
    while True:
        try:
            chunk = client.recv(BUFFER_SIZE)
            if not chunk:
                print(f"[INFO] {username} connection closed")
                break
            
            # (old in-file-transfer branch removed) — using length-prefixed streaming below
            
            # Normal JSON message processing using byte buffer
            buffer += chunk
            
            # FIXED: Buffer size limit
            if len(buffer) > MAX_MESSAGE_SIZE * 2:
                print(f"[ERROR] Buffer overflow for {username}, clearing")
                buffer = b""
                error_data = {
                    'type': 'error',
                    'message': 'Message too large, buffer cleared'
                }
                try:
                    client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                except:
                    pass
                continue
            
            # Process any complete JSON lines in the byte buffer
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if not line.strip():
                    continue

                # FIXED: Validate message size
                if len(line) > MAX_MESSAGE_SIZE:
                    print(f"[ERROR] Message too large from {username}: {len(line)} bytes")
                    error_data = {
                        'type': 'error',
                        'message': f'Message too large (max {MAX_MESSAGE_SIZE} bytes)'
                    }
                    try:
                        client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                    except:
                        pass
                    continue

                try:
                    try:
                        message_data = json.loads(line.decode('utf-8'))
                    except Exception:
                        raise json.JSONDecodeError('Invalid UTF-8 in JSON header', '', 0)
                    message_type = message_data.get('type')
                    
                    # Handle file transfer initiation
                    if message_type == 'file_transfer_start':
                        recipient = message_data.get('receiver')
                        file_name = message_data.get('file_name')
                        file_size = message_data.get('file_size')
                        file_id = message_data.get('file_id')
                        
                        print(f"[FILE] {username} wants to send '{file_name}' ({file_size} bytes) to {recipient}")
                        
                        with clients_lock:
                            if recipient not in clients:
                                error = {
                                    'type': 'error',
                                    'message': f'{recipient} is offline. Cannot send file.'
                                }
                                client.send((json.dumps(error) + '\n').encode('utf-8'))
                                print(f"[ERROR] {recipient} offline, can't relay file")
                                continue
                            
                            receiver_socket = clients[recipient]

                        try:
                            # Forward metadata to receiver
                            receiver_socket.send((json.dumps(message_data) + '\n').encode('utf-8'))
                        except Exception as e:
                            print(f"[ERROR] Could not send metadata to {recipient}: {e}")
                            error = {
                                'type': 'error',
                                'message': f'Failed to reach {recipient}'
                            }
                            client.send((json.dumps(error) + '\n').encode('utf-8'))
                            continue

                        # Remember metadata so we can match the later end-frame
                        file_metadata = message_data

                        # Now perform a deterministic length-prefixed relay: send a 4-byte BE length to the
                        # receiver, then read exactly `file_size` bytes from the sender and forward them.
                        try:
                            expected = int(file_size)
                        except Exception:
                            expected = 0

                        if expected <= 0:
                            err = {'type': 'error', 'message': 'Invalid file size'}
                            client.send((json.dumps(err) + '\n').encode('utf-8'))
                            continue

                        print(f"[FILE] Streaming {file_name} ({expected} bytes) from {username} to {recipient}")

                        try:
                            # Send 4-byte big-endian length prefix to receiver
                            receiver_socket.sendall(struct.pack('>I', expected))
                        except Exception as e:
                            print(f"[ERROR] Could not send length prefix to receiver: {e}")
                            client.send((json.dumps({'type': 'error', 'message': 'Receiver unreachable'}) + '\n').encode('utf-8'))
                            continue

                        bytes_relayed = 0
                        transfer_start_time = time.time()

                        # Stream file bytes from sender to receiver. Any trailing bytes received
                        # beyond the expected file length will be pushed back into `buffer`
                        # so the JSON processing loop can handle them (including the
                        # `file_transfer_end` frame).
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                        
                            # If we already have some decoded JSON buffer (from the initial recv),
                            # it may contain part or all of the file bytes (if they were ASCII).
                            # Consume those bytes first before performing new recv() calls.
                        if buffer:
                                # buffer is a bytes object containing any leftover after parsing headers
                                buf_bytes = buffer

                                if buf_bytes:
                                    need = expected - bytes_relayed
                                    data_part = buf_bytes[:need]
                                    if data_part:
                                        try:
                                            print(f"[DEBUG] initial buf len={len(buf_bytes)} need={need} data_part_len={len(data_part)}")
                                            receiver_socket.sendall(data_part)
                                        except Exception as e:
                                            raise Exception(f'Failed to forward initial buffered bytes: {e}')
                                        bytes_relayed += len(data_part)
                                    # Rebuild buffer from any leftover tail (keep as bytes)
                                    leftover = buf_bytes[len(data_part):]
                                    buffer = leftover
                        try:
                            while bytes_relayed < expected:
                                need = expected - bytes_relayed
                                to_read = min(BUFFER_SIZE, need)
                                chunk = client.recv(to_read)
                                if not chunk:
                                    raise Exception('Sender disconnected during file transfer')

                                # If chunk contains more than the remaining file bytes, split it.
                                if len(chunk) > need:
                                    data_part = chunk[:need]
                                    tail = chunk[need:]
                                else:
                                    data_part = chunk
                                    tail = b''

                                # Forward only the binary data part to the receiver
                                receiver_socket.sendall(data_part)
                                bytes_relayed += len(data_part)

                                # If there is a tail (JSON frames appended by sender), prepend it to the
                                # byte buffer so the normal JSON loop will process it next.
                                if tail:
                                    buffer = tail + buffer

                                # Check timeout
                                if time.time() - transfer_start_time > FILE_TRANSFER_TIMEOUT:
                                    raise Exception('File transfer timeout')

                            print(f"[FILE] ✓ Completed streaming {file_name} ({bytes_relayed} bytes)")
                            # Completed streaming; any trailing JSON remains in `buffer` and
                            # will be processed by the normal JSON loop below.
                        except Exception as e:
                            print(f"[ERROR] File streaming failed: {e}")
                            try:
                                client.send((json.dumps({'type': 'error', 'message': str(e)}) + '\n').encode('utf-8'))
                            except:
                                pass
                            try:
                                receiver_socket.send((json.dumps({'type': 'error', 'message': str(e)}) + '\n').encode('utf-8'))
                            except:
                                pass
                        finally:
                            # After streaming we DO NOT clear `file_metadata` immediately because the
                            # sender may have appended a JSON end-frame which has been placed into
                            # `buffer` and will be processed by the JSON loop below. Keep
                            # `receiver_socket` and `file_metadata` around until the end-frame
                            # is consumed and forwarded.
                            transfer_start_time = transfer_start_time
                    
                    elif message_type == 'file_transfer_end':
                        # Forward the end-frame to the receiver if we have an active transfer
                        try:
                            target_id = message_data.get('file_id')
                            if file_metadata and file_metadata.get('file_id') == target_id and receiver_socket:
                                try:
                                    receiver_socket.send((json.dumps(message_data) + '\n').encode('utf-8'))
                                except Exception as e:
                                    print(f"[ERROR] Failed to forward file_transfer_end to receiver: {e}")
                                # Clear transfer state now that end-frame forwarded
                                file_metadata = None
                                receiver_socket = None
                                bytes_relayed = 0
                                transfer_start_time = None
                            else:
                                # No active transfer matching this id; ignore or log
                                print(f"[WARN] Received file_transfer_end for unknown id: {target_id}")
                        except Exception:
                            pass

                    elif message_type == 'group':
                        msg_text = message_data.get('message', '')
                        
                        # FIXED: Validate message content
                        if not msg_text or len(msg_text) > MAX_MESSAGE_SIZE:
                            error_data = {
                                'type': 'error',
                                'message': 'Invalid message'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                            continue
                        
                        # Save to database using ChatHistoryManager
                        chat_history.save_message(username, 'group', msg_text, 'group')
                        
                        broadcast_data = {
                            'type': 'group',
                            'from': username,
                            'message': msg_text
                        }
                        broadcast(broadcast_data)
                        print(f"[GROUP] {username}: {msg_text[:50]}...")
                        
                    elif message_type == 'dm':
                        recipient = message_data.get('to')
                        msg_text = message_data.get('message', '')
                        
                        # FIXED: Validate message content and recipient
                        if not msg_text or len(msg_text) > MAX_MESSAGE_SIZE or not recipient:
                            error_data = {
                                'type': 'error',
                                'message': 'Invalid message or recipient'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                            continue
                        
                        # Save to database using ChatHistoryManager
                        chat_history.save_message(username, recipient, msg_text, 'dm')
                        
                        dm_data = {
                            'type': 'dm',
                            'from': username,
                            'message': msg_text
                        }
                        
                        if send_to_user(recipient, dm_data):
                            confirmation = {
                                'type': 'dm',
                                'from': username,
                                'to': recipient,
                                'message': msg_text,
                                'sent': True
                            }
                            client.send((json.dumps(confirmation) + '\n').encode('utf-8'))
                            print(f"[DM] {username} -> {recipient}: {msg_text[:50]}...")
                        else:
                            error_data = {
                                'type': 'error',
                                'message': f'User {recipient} not found or offline'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                            
                    elif message_type == 'request_users':
                        send_user_list()
                    
                    elif message_type == 'request_history':
                        # Client requesting chat history - use ChatHistoryManager
                        chat_with = message_data.get('chat_with')
                        
                        if not chat_with:
                            error_data = {
                                'type': 'error',
                                'message': 'Invalid history request'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                            continue
                        
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
                            print(f"[HISTORY] Sent {len(messages)} messages to {username} for {chat_with}")
                        else:
                            print(f"[ERROR] Failed to fetch history for {username}")
                            error_data = {
                                'type': 'error',
                                'message': 'Failed to fetch history'
                            }
                            client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                            
                except json.JSONDecodeError as e:
                    print(f"[ERROR] JSON decode error from {username}: {e}")
                    error_data = {
                        'type': 'error',
                        'message': 'Invalid message format'
                    }
                    try:
                        client.send((json.dumps(error_data) + '\n').encode('utf-8'))
                    except:
                        pass
                    
        except Exception as e:
            print(f"[ERROR] Error handling {username}: {e}")
            break
    
    # Cleanup
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

            # Send auth request
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
                except jwt.InvalidTokenError as e:
                    print(f"[ERROR] Invalid token: {e}")
                    client.send(json.dumps({
                        "type": "error",
                        "message": "Invalid token"
                    }).encode())
                    client.close()
                    continue

                if not username:
                    client.close()
                    continue
                
                # FIXED: Username validation
                if not username.replace('_', '').isalnum() or len(username) > 30:
                    error = json.dumps({
                        'type': 'error',
                        'message': 'Invalid username format'
                    }) + '\n'
                    client.send(error.encode('utf-8'))
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
                    
                    # FIXED: Atomic addition to prevent race condition
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
                try:
                    client.close()
                except:
                    pass
                
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
