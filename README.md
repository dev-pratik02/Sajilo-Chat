# Sajilo Chat

A LAN chat application with a **Flutter** client and a **Python** backend. It offers end-to-end encrypted direct messages, a shared group chat and direct file transfer.

> **Project status:** built for learning and demonstration on a trusted local network. Read [Security notes](#security-notes) before using it for anything sensitive.

## Features

- User registration and login with hashed passwords and JWT authentication
- Direct messages encrypted on the device (X25519 key exchange, HKDF-SHA256, AES-256-GCM)
- Group chat for all connected users (not encrypted)
- Chat history stored in SQLite
- Online user list, typing indicators and unread counts
- File transfer between two online users, up to 50 MB (not encrypted)
- Reconnect prompt when the connection drops

## Architecture

The backend runs as two processes that must both be running.

```
                    HTTP :5001      ┌──────────────────────┐
              ┌────────────────────►│  unified_server.py   │──► SQLite
              │  register, login,   │  Flask REST API      │    (unified.db)
┌─────────────┴──┐ public keys      └──────────▲───────────┘
│ Flutter client │                             │ HTTP: save and load messages
└─────────────┬──┘                  ┌──────────┴───────────┐
              │  TCP :5050          │  dm_server.py        │
              └────────────────────►│  Real-time socket    │
                 chat, files        │  server              │
                                    └──────────────────────┘
```

## Tech stack

| Layer | Technology |
|---|---|
| Client | Flutter, Dart (`cryptography`, `http`, `shared_preferences`, `file_picker`) |
| REST API | Flask, Flask-SQLAlchemy, Flask-JWT-Extended |
| Real-time server | Python `socket` and `threading`, newline-delimited JSON |
| Database | SQLite |

## Project structure

```
Sajilo-Chat/
├── client/sajilo_chat/
│   └── lib/
│       ├── main.dart                   # App entry point
│       ├── login_page.dart             # Register, login, connect
│       ├── chat_list.dart              # Online users and unread counts
│       ├── chat_screen.dart            # Conversation UI
│       ├── message_bubble.dart         # Message widget
│       ├── crypto_manager.dart         # Keys, encryption, decryption
│       ├── chat_history_handler.dart   # History requests and cache
│       ├── file_transfer_handler.dart  # Sending and receiving files
│       └── utilities.dart              # Socket wrapper
└── server/
    ├── requirements.txt
    └── app/
        ├── unified_server.py           # REST API (port 5001)
        ├── dm_server.py                # Socket server (port 5050)
        ├── chat_history_manager.py     # Socket server → API calls
        ├── start_server.py             # Helper that starts the API only
        └── enhanced_test_server.py     # API diagnostic script
```

## Getting started

### Prerequisites

- Python 3 with `pip`
- Flutter 3.38.4 or newer (Dart 3.10.4 or newer)
- Server and client devices on the same network

### 1. Clone

```bash
git clone https://github.com/dev-pratik02/Sajilo-Chat.git
cd Sajilo-Chat
```

### 2. Install server dependencies

**macOS / Linux**

```bash
cd server
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**Windows (PowerShell)**

```powershell
cd server
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

### 3. Create a JWT secret

Both servers read `JWT_SECRET` from the **environment**, and the value must be identical for both. They do not load a `.env` file automatically.

Generate a value once:

```bash
python -c "import secrets; print(secrets.token_urlsafe(32))"
```

Set it in **each** terminal that runs a server:

```bash
export JWT_SECRET="paste-your-secret-here"      # macOS / Linux
```

```powershell
$env:JWT_SECRET="paste-your-secret-here"        # Windows PowerShell
```

### 4. Start the servers

Open two terminals, activate the virtual environment and set `JWT_SECRET` in both. Starting from the `server` directory:

**Terminal 1: REST API**

```bash
cd app
python unified_server.py
```

**Terminal 2: socket server**

```bash
cd app
python dm_server.py
```

Check that the API is up:

```bash
curl http://localhost:5001/health
```

The socket server prints the LAN IP address that clients should connect to. Both servers must run on the same machine, because `dm_server.py` reaches the API at `localhost:5001`.

### 5. Run the client

```bash
cd client/sajilo_chat
flutter pub get
flutter run
```

On the login screen, register an account, then log in with the server address:

| Client runs on | Server IP to enter |
|---|---|
| Same computer as the server | `127.0.0.1` |
| Android emulator on the server computer | `10.0.2.2` |
| Another device on the network | The server's LAN IP |

Allow inbound connections on ports **5001** and **5050** in the server's firewall.

**Account rules**

- Username: 3–64 characters (letters, numbers, `_`, `-`)
- Password: 8–128 characters, with at least one uppercase letter, one lowercase letter and one number


## How encryption works

1. The client generates an X25519 identity key pair for each username and stores it on the device.
2. The public key is uploaded to the API. The private key is never sent.
3. To open a direct chat, the client fetches the other user's public key and computes a shared secret.
4. HKDF-SHA256 derives a 256-bit session key, bound to the two usernames in sorted order.
5. Each message is encrypted with AES-256-GCM using a random nonce. The server relays and stores only the ciphertext, nonce and authentication tag.

Because the private key exists only on one device, logging in from a new device (or after clearing app data) creates a new key, and earlier direct messages can no longer be decrypted.




