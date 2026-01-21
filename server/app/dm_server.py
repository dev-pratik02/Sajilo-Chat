import socket
import threading
import json
import jwt

JWT_SECRET = "jwt-secret-change-me"
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
BufferSize = 4096  # Increased buffer size

server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

try:
    server_socket.bind(("0.0.0.0", Port))
    server_socket.listen()
    print("=" * 60)
    print("         SAJILO CHAT SERVER")
    print("=" * 60)
    print(f"Server is listening on {IP_address}:{Port}")
    print(f"Use 'localhost' or '{IP_address}' to connect")
    print("Waiting for connections...")
    print("=" * 60)
except OSError as e:
    print(f"Error binding to port: {e}")
    print("Try closing other instances or wait a minute")
    exit()

clients = {}
clients_lock = threading.Lock()


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


def handle(client, username):
    """Handle messages from a client"""
    buffer = ""
    
    # NEW: File transfer state tracking
    in_file_transfer = False
    file_metadata = None
    receiver_socket = None
    bytes_relayed = 0
    
    while True:
        try:
            chunk = client.recv(BufferSize)
            if not chunk:
                print(f"[INFO] {username} connection closed")
                break
            
            # NEWWWWW: Binary relay mode for file transfers
            if in_file_transfer:
                try:
                    # Forward raw bytes directly to receiver
                    receiver_socket.send(chunk)
                    bytes_relayed += len(chunk)
                    
                    # Check if transfer complete
                    if bytes_relayed >= file_metadata['file_size']:
                        print(f"[FILE] ✓ Relayed {file_metadata['file_name']} "
                              f"({bytes_relayed} bytes) from {username} to {file_metadata['receiver']}")
                        
                        # Send end frame to receiver
                        end_frame = json.dumps({
                            'type': 'file_transfer_end',
                            'file_id': file_metadata['file_id'],
                            'status': 'success'
                        }) + '\n'
                        receiver_socket.send(end_frame.encode('utf-8'))
                        
                        # Reset state - back to JSON mode
                        in_file_transfer = False
                        file_metadata = None
                        receiver_socket = None
                        bytes_relayed = 0
                    
                    continue  # Skip JSON parsing
                    
                except Exception as e:
                    print(f"[ERROR] File relay failed: {e}")
                    # Reset state on error
                    in_file_transfer = False
                    file_metadata = None
                    receiver_socket = None
                    bytes_relayed = 0
                    
                    # Notify sender of failure
                    error_data = {
                        'type': 'error',
                        'message': 'File transfer failed'
                    }
                    try:
                        json_msg = json.dumps(error_data) + '\n'
                        client.send(json_msg.encode('utf-8'))
                    except:
                        pass
                    continue
            
            # Normal JSON message processing
            buffer += chunk.decode('utf-8')
            
            # Process complete messages (separated by newlines)
            while '\n' in buffer:
                line, buffer = buffer.split('\n', 1)
                if not line.strip():
                    continue
                
                try:
                    message_data = json.loads(line)
                    message_type = message_data.get('type')
                    
                    # NEW: Handle file transfer initiation
                    if message_type == 'file_transfer_start':
                        recipient = message_data.get('receiver')
                        file_name = message_data.get('file_name')
                        file_size = message_data.get('file_size')
                        file_id = message_data.get('file_id')
                        
                        print(f"[FILE] {username} wants to send '{file_name}' ({file_size} bytes) to {recipient}")
                        
                        # Check if recipient is online
                        with clients_lock:
                            if recipient not in clients:
                                error = {
                                    'type': 'error',
                                    'message': f'{recipient} is offline. Cannot send file.'
                                }
                                json_msg = json.dumps(error) + '\n'
                                client.send(json_msg.encode('utf-8'))
                                print(f"[ERROR] {recipient} offline, can't relay file")
                                continue
                            
                            receiver_socket = clients[recipient]
                        
                        # Forward metadata to receiver
                        try:
                            receiver_socket.send((json.dumps(message_data) + '\n').encode('utf-8'))
                        except Exception as e:
                            print(f"[ERROR] Could not send metadata to {recipient}: {e}")
                            error = {
                                'type': 'error',
                                'message': f'Failed to reach {recipient}'
                            }
                            json_msg = json.dumps(error) + '\n'
                            client.send(json_msg.encode('utf-8'))
                            continue
                        
                        # Enter binary relay mode
                        in_file_transfer = True
                        file_metadata = message_data
                        bytes_relayed = 0
                        
                        print(f"[FILE] Entering relay mode: {file_name} → {recipient}")
                    
                    elif message_type == 'group':
                        broadcast_data = {
                            'type': 'group',
                            'from': username,
                            'message': message_data.get('message')
                        }
                        broadcast(broadcast_data)
                        print(f"[GROUP] {username}: {message_data.get('message')}")
                        
                    elif message_type == 'dm':
                        recipient = message_data.get('to')
                        dm_data = {
                            'type': 'dm',
                            'from': username,
                            'message': message_data.get('message')
                        }
                        
                        if send_to_user(recipient, dm_data):
                            # Send confirmation back to sender
                            confirmation = {
                                'type': 'dm',
                                'from': username,
                                'to': recipient,
                                'message': message_data.get('message'),
                                'sent': True
                            }
                            json_msg = json.dumps(confirmation) + '\n'
                            client.send(json_msg.encode('utf-8'))
                            print(f"[DM] {username} -> {recipient}: {message_data.get('message')}")
                        else:
                            error_data = {
                                'type': 'error',
                                'message': f'User {recipient} not found or offline'
                            }
                            json_msg = json.dumps(error_data) + '\n'
                            client.send(json_msg.encode('utf-8'))
                            print(f"[ERROR] {username} tried to DM offline user: {recipient}")
                            
                    elif message_type == 'request_users':
                        send_user_list()
                        
                except json.JSONDecodeError as e:
                    print(f"[ERROR] JSON decode error from {username}: {e}")
                    print(f"[ERROR] Problematic data: {line}")
                    
        except Exception as e:
            print(f"[ERROR] Error handling {username}: {e}")
            import traceback
            traceback.print_exc()
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

            # Handshake for username
            json_msg = json.dumps({'type': 'request_auth'}) + '\n'
            client.send(json_msg.encode('utf-8'))
            print(f"[DEBUG] Sent username request")
            
            # Receive username with timeout
            client.settimeout(10.0)
            
            try:
                data = b''
                while b'\n' not in data:
                    chunk = client.recv(1024)
                    if not chunk:
                        print(f"[ERROR] Client disconnected during handshake")
                        client.close()
                        break
                    data += chunk
                
                if b'\n' not in data:
                    continue
                
                message = data.decode('utf-8').strip()
                print(f"[DEBUG] Received: {message}")
                
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
                    print(f"[ERROR] Empty username")
                    client.close()
                    continue
                
                print(f"[DEBUG] Username: '{username}'")
                
                # Check if username taken
                with clients_lock:
                    if username in clients:
                        error = json.dumps({
                            'type': 'error',
                            'message': 'Username already taken'
                        }) + '\n'
                        client.send(error.encode('utf-8'))
                        client.close()
                        print(f"[REJECTED] Username '{username}' already taken")
                        continue
                    
                    clients[username] = client
                
                client.settimeout(None)
                
                print(f"[LOGIN] ✓ {username} logged in")
                
                # Send welcome
                welcome = json.dumps({
                    'type': 'system',
                    'message': f'Welcome to the server, {username}!'
                }) + '\n'
                client.send(welcome.encode('utf-8'))
                
                # Notify others
                broadcast({
                    'type': 'system',
                    'message': f'{username} joined the chat'
                }, exclude_user=username)
                
                # Send user list
                send_user_list()
                
                # Start handler
                thread = threading.Thread(target=handle, args=(client, username), daemon=True)
                thread.start()
                
            except socket.timeout:
                print(f"[ERROR] Timeout waiting for username")
                client.close()
            except json.JSONDecodeError as e:
                print(f"[ERROR] JSON error: {e}")
                client.close()
            except Exception as e:
                print(f"[ERROR] Handshake error: {e}")
                import traceback
                traceback.print_exc()
                client.close()
                
        except KeyboardInterrupt:
            print("\n[SHUTDOWN] Server shutting down...")
            break
        except Exception as e:
            print(f"[ERROR] Accept error: {e}")
            import traceback
            traceback.print_exc()


if __name__ == "__main__":
    try:
        receive()
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Server stopped")
    finally:
        server_socket.close()