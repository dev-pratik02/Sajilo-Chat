import requests, socket, json, time
HOST='127.0.0.1'
FLASK_PORT=5001
DM_PORT=5050
u='smoketest_user'
p='password123'

print('Registering user...')
try:
    r=requests.post(f'http://{HOST}:{FLASK_PORT}/auth/register', json={'username':u,'password':p}, timeout=5)
    print('Register status:', r.status_code, r.text)
except Exception as e:
    print('Register error (may already exist):', e)

print('Logging in...')
r=requests.post(f'http://{HOST}:{FLASK_PORT}/auth/login', json={'username':u,'password':p}, timeout=5)
print('Login status:', r.status_code, r.text)
if r.status_code!=200:
    print('Login failed, aborting')
    raise SystemExit

token=r.json().get('access_token')
print('Got token len:', len(token or ''))

print('Connecting to DM server...')
s=socket.create_connection((HOST,DM_PORT), timeout=5)
print('Connected, waiting for request_auth...')
b=''
# read until newline
while True:
    ch=s.recv(4096)
    if not ch:
        print('socket closed')
        break
    try:
        b+=ch.decode('utf-8')
    except Exception:
        # ignore decode errors during binary relays
        continue
    if '\n' in b:
        line, b = b.split('\n',1)
        print('Received:', line)
        try:
            j=json.loads(line)
            if j.get('type')=='request_auth':
                auth_frame=json.dumps({'token':token})+'\n'
                s.sendall(auth_frame.encode('utf-8'))
                print('Sent token')
                break
        except Exception as e:
            print('recv parse error', e)

# read welcome and other messages for a short while
s.settimeout(2)
try:
    while True:
        data=s.recv(4096)
        if not data: break
        try:
            text=data.decode('utf-8').strip()
            print('IN:', text)
            if 'Welcome' in text:
                break
        except Exception:
            pass
except Exception:
    pass

# request users
req=json.dumps({'type':'request_users'})+'\n'
s.sendall(req.encode('utf-8'))
print('Requested user list')
# send a group message
msg=json.dumps({'type':'group','message':'Hello from smoketest'})+'\n'
s.sendall(msg.encode('utf-8'))
print('Sent group message')

# wait for any responses
time.sleep(1)
try:
    while True:
        data=s.recv(4096)
        if not data: break
        try:
            print('IN2:', data.decode('utf-8').strip())
        except Exception:
            pass
except Exception:
    pass

print('Closing socket')
s.close()
print('Done')
