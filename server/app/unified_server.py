from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_jwt_extended import JWTManager, create_access_token, jwt_required, get_jwt_identity
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime, timedelta
import os
import re

app = Flask(__name__)

# Centralized JWT secret (shared with dm_server)
JWT_SECRET = os.getenv("JWT_SECRET")
if not JWT_SECRET:
    raise RuntimeError("JWT_SECRET environment variable must be set! Never use default secrets in production.")

# Configuration
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///unified.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['JWT_SECRET_KEY'] = JWT_SECRET
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(hours=24)

db = SQLAlchemy(app)
jwt = JWTManager(app)


# User model (for authentication)
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False, index=True)
    password_hash = db.Column(db.String(200), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow, index=True)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)


# PublicKey model for E2EE
class PublicKey(db.Model):
    __tablename__ = "public_keys"
    
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(64), unique=True, nullable=False, index=True)
    public_key = db.Column(db.Text, nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    def to_dict(self):
        return {
            'username': self.username,
            'public_key': self.public_key,
            'created_at': self.created_at.isoformat(),
            'updated_at': self.updated_at.isoformat()
        }


# Message model (for encrypted chat history)
class Message(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    sender = db.Column(db.String(100), nullable=False, index=True)
    recipient = db.Column(db.String(100), nullable=False, index=True)
    
    # Encrypted message data
    ciphertext = db.Column(db.Text, nullable=False)
    nonce = db.Column(db.String(255), nullable=False)
    mac = db.Column(db.String(255), nullable=False)
    
    timestamp = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    message_type = db.Column(db.String(20), nullable=False)
    
    # Message status
    delivered = db.Column(db.Boolean, default=False)
    read = db.Column(db.Boolean, default=False)

    def to_dict(self):
        return {
            'id': self.id,
            'from': self.sender,
            'to': self.recipient,
            'ciphertext': self.ciphertext,
            'nonce': self.nonce,
            'mac': self.mac,
            'timestamp': self.timestamp.isoformat(),
            'type': self.message_type,
            'delivered': self.delivered,
            'read': self.read
        }


class SessionInfo(db.Model):
    """Track active encryption sessions with ratchet state"""
    __tablename__ = "session_info"
    
    id = db.Column(db.Integer, primary_key=True)
    user1 = db.Column(db.String(64), nullable=False, index=True)
    user2 = db.Column(db.String(64), nullable=False, index=True)
    ratchet_count = db.Column(db.Integer, default=0)
    last_updated = db.Column(db.DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
    
    __table_args__ = (
        db.UniqueConstraint('user1', 'user2', name='uq_session_pair'),
    )
    
    def to_dict(self):
        return {
            'user1': self.user1,
            'user2': self.user2,
            'ratchet_count': self.ratchet_count,
            'last_updated': self.last_updated.isoformat()
        }


# ChatList model
class ChatList(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(100), nullable=False, index=True)
    chat_with = db.Column(db.String(100), nullable=False, index=True)
    last_updated = db.Column(db.DateTime, default=datetime.utcnow, index=True)
    unread_count = db.Column(db.Integer, default=0)

    __table_args__ = (
        db.UniqueConstraint('username', 'chat_with', name='uq_user_chat'),
    )

    def to_dict(self):
        return {
            'username': self.username,
            'chat_with': self.chat_with,
            'last_updated': self.last_updated.isoformat(),
            'unread_count': self.unread_count
        }


# ========================
# INPUT VALIDATION
# ========================

def validate_username(username):
    """Validate username format"""
    if not username or not isinstance(username, str):
        return "Username is required"
    if len(username) < 3 or len(username) > 64:
        return "Username must be 3-64 characters"
    if not re.match(r'^[a-zA-Z0-9_-]+$', username):
        return "Username can only contain letters, numbers, hyphens and underscores"
    return None

def validate_password(password):
    """Validate password strength"""
    if not password or not isinstance(password, str):
        return "Password is required"
    if len(password) < 8:
        return "Password must be at least 8 characters"
    if len(password) > 128:
        return "Password is too long"
    if not re.search(r'[A-Z]', password):
        return "Password must contain at least one uppercase letter"
    if not re.search(r'[a-z]', password):
        return "Password must contain at least one lowercase letter"
    if not re.search(r'[0-9]', password):
        return "Password must contain at least one number"
    return None


# ========================
# AUTHENTICATION ROUTES
# ========================

@app.route('/auth/register', methods=['POST'])
def register():
    try:
        data = request.get_json()
        username = data.get('username', '').strip()
        password = data.get('password', '')
        public_key = data.get('public_key')
        
        # Validate username
        username_error = validate_username(username)
        if username_error:
            return jsonify({'error': username_error}), 400
        
        # Validate password
        password_error = validate_password(password)
        if password_error:
            return jsonify({'error': password_error}), 400
        
        if User.query.filter_by(username=username).first():
            return jsonify({'error': 'Username already exists'}), 409
        
        # Create user
        user = User(username=username)
        user.set_password(password)
        db.session.add(user)
        
        # Store public key if provided
        if public_key:
            pub_key_entry = PublicKey(username=username, public_key=public_key)
            db.session.add(pub_key_entry)
        
        db.session.commit()
        
        return jsonify({
            'message': 'User registered successfully',
            'username': username
        }), 201
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Registration failed: {e}")
        return jsonify({'error': 'Registration failed'}), 500


@app.route('/auth/login', methods=['POST'])
def login():
    try:
        data = request.get_json()
        username = data.get('username', '').strip()
        password = data.get('password', '')
        
        if not username or not password:
            return jsonify({'error': 'Username and password required'}), 400
        
        user = User.query.filter_by(username=username).first()
        
        if not user or not user.check_password(password):
            return jsonify({'error': 'Invalid credentials'}), 401
        
        access_token = create_access_token(identity=username)
        
        return jsonify({
            'access_token': access_token,
            'username': username
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Login failed: {e}")
        return jsonify({'error': 'Login failed'}), 500


# ========================
# PUBLIC KEY MANAGEMENT
# ========================

@app.route('/api/keys/upload', methods=['POST'])
def upload_public_key():
    """Upload or update user's public identity key"""
    try:
        data = request.json
        username = data.get('username', '').strip()
        public_key = data.get('public_key')
        
        # Validate username
        username_error = validate_username(username)
        if username_error:
            return jsonify({'error': username_error}), 400
        
        if not public_key or not isinstance(public_key, str):
            return jsonify({'error': 'Valid public_key required'}), 400
        
        # Check if key already exists
        existing_key = PublicKey.query.filter_by(username=username).first()
        
        if existing_key:
            # Update existing key
            existing_key.public_key = public_key
            existing_key.updated_at = datetime.utcnow()
        else:
            # Create new key entry
            new_key = PublicKey(username=username, public_key=public_key)
            db.session.add(new_key)
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'Public key uploaded successfully'
        }), 200
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Key upload failed: {e}")
        return jsonify({'error': 'Failed to upload key'}), 500


@app.route('/api/keys/get/<username>', methods=['GET'])
def get_public_key(username):
    """Fetch a user's public key"""
    try:
        # Validate username
        username = username.strip()
        username_error = validate_username(username)
        if username_error:
            return jsonify({'error': username_error}), 400
        
        key_entry = PublicKey.query.filter_by(username=username).first()
        
        if not key_entry:
            return jsonify({'error': 'Public key not found for user'}), 404
        
        return jsonify({
            'success': True,
            'username': username,
            'public_key': key_entry.public_key
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Key fetch failed: {e}")
        return jsonify({'error': 'Failed to fetch key'}), 500


@app.route('/api/keys/batch', methods=['POST'])
def get_public_keys_batch():
    """Fetch multiple users' public keys at once"""
    try:
        data = request.json
        usernames = data.get('usernames', [])
        
        if not usernames or not isinstance(usernames, list):
            return jsonify({'error': 'Usernames list required'}), 400
        
        # Limit batch size
        if len(usernames) > 100:
            return jsonify({'error': 'Maximum 100 usernames per request'}), 400
        
        keys = PublicKey.query.filter(PublicKey.username.in_(usernames)).all()
        
        result = {
            key.username: key.public_key
            for key in keys
        }
        
        return jsonify({
            'success': True,
            'keys': result
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Batch key fetch failed: {e}")
        return jsonify({'error': 'Failed to fetch keys'}), 500


# ========================
# SESSION MANAGEMENT
# ========================

@app.route('/api/session/info', methods=['POST'])
def get_session_info():
    """Get session info including ratchet count"""
    try:
        data = request.json
        user1 = data.get('user1', '').strip()
        user2 = data.get('user2', '').strip()
        
        if not user1 or not user2:
            return jsonify({'error': 'Both users required'}), 400
        
        # Normalize order
        user1, user2 = sorted([user1, user2])
        
        session = SessionInfo.query.filter_by(
            user1=user1,
            user2=user2
        ).first()
        
        if not session:
            return jsonify({
                'success': True,
                'ratchet_count': 0,
                'exists': False
            }), 200
        
        return jsonify({
            'success': True,
            'ratchet_count': session.ratchet_count,
            'exists': True,
            'last_updated': session.last_updated.isoformat()
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Session info fetch failed: {e}")
        return jsonify({'error': 'Failed to fetch session info'}), 500


@app.route('/api/session/ratchet', methods=['POST'])
def increment_ratchet():
    """Increment ratchet count for a session"""
    try:
        data = request.json
        user1 = data.get('user1', '').strip()
        user2 = data.get('user2', '').strip()
        
        if not user1 or not user2:
            return jsonify({'error': 'Both users required'}), 400
        
        # Normalize order
        user1, user2 = sorted([user1, user2])
        
        session = SessionInfo.query.filter_by(
            user1=user1,
            user2=user2
        ).first()
        
        if not session:
            session = SessionInfo(user1=user1, user2=user2, ratchet_count=1)
            db.session.add(session)
        else:
            session.ratchet_count += 1
            session.last_updated = datetime.utcnow()
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'ratchet_count': session.ratchet_count
        }), 200
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Ratchet increment failed: {e}")
        return jsonify({'error': 'Failed to increment ratchet'}), 500


# ========================
# ENCRYPTED MESSAGE STORAGE
# ========================

@app.route('/api/messages/save', methods=['POST'])
def save_encrypted_message():
    """Save encrypted message to database"""
    try:
        data = request.json
        
        # Validate required fields
        required_fields = ['sender', 'recipient', 'ciphertext', 'nonce', 'mac', 'type']
        for field in required_fields:
            if field not in data:
                return jsonify({'error': f'Missing required field: {field}'}), 400
        
        message = Message(
            sender=data['sender'],
            recipient=data['recipient'],
            ciphertext=data['ciphertext'],
            nonce=data['nonce'],
            mac=data['mac'],
            message_type=data['type']
        )
        
        db.session.add(message)
        
        # Update chat list
        if data['type'] == 'dm':
            # Update for sender
            chat_entry = ChatList.query.filter_by(
                username=data['sender'],
                chat_with=data['recipient']
            ).first()
            
            if not chat_entry:
                chat_entry = ChatList(
                    username=data['sender'],
                    chat_with=data['recipient']
                )
                db.session.add(chat_entry)
            
            chat_entry.last_updated = datetime.utcnow()
            
            # Update for recipient
            chat_entry2 = ChatList.query.filter_by(
                username=data['recipient'],
                chat_with=data['sender']
            ).first()
            
            if not chat_entry2:
                chat_entry2 = ChatList(
                    username=data['recipient'],
                    chat_with=data['sender'],
                    unread_count=1
                )
                db.session.add(chat_entry2)
            else:
                chat_entry2.unread_count += 1
            
            chat_entry2.last_updated = datetime.utcnow()
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message_id': message.id,
            'message': 'Encrypted message saved'
        }), 201
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Message save failed: {e}")
        return jsonify({'error': 'Failed to save message'}), 500


@app.route('/api/messages/history', methods=['GET'])
def get_encrypted_message_history():
    """Get encrypted message history"""
    try:
        username = request.args.get('username', '').strip()
        chat_with = request.args.get('chat_with', '').strip()
        limit = request.args.get('limit', 100, type=int)
        offset = request.args.get('offset', 0, type=int)
        
        # Validate limit
        if limit > 500:
            limit = 500
        if limit < 1:
            limit = 100
        
        if chat_with == 'group':
            messages = Message.query.filter_by(
                message_type='group'
            ).order_by(Message.timestamp.desc()).offset(offset).limit(limit).all()
        else:
            messages = Message.query.filter(
                db.or_(
                    db.and_(Message.sender == username, Message.recipient == chat_with),
                    db.and_(Message.sender == chat_with, Message.recipient == username)
                )
            ).order_by(Message.timestamp.desc()).offset(offset).limit(limit).all()
        
        # Reverse to get chronological order
        messages.reverse()
        
        return jsonify({
            'success': True,
            'messages': [msg.to_dict() for msg in messages],
            'count': len(messages),
            'offset': offset,
            'limit': limit
        }), 200
        
    except Exception as e:
        print(f"[ERROR] History fetch failed: {e}")
        return jsonify({'error': 'Failed to fetch history'}), 500


@app.route('/api/messages/mark_read', methods=['POST'])
def mark_messages_read():
    """Mark messages as read"""
    try:
        data = request.json
        username = data.get('username', '').strip()
        chat_with = data.get('chat_with', '').strip()
        
        if not username or not chat_with:
            return jsonify({'error': 'Username and chat_with required'}), 400
        
        # Mark messages as read
        Message.query.filter(
            Message.sender == chat_with,
            Message.recipient == username,
            Message.read == False
        ).update({'read': True})
        
        # Reset unread count
        chat_entry = ChatList.query.filter_by(
            username=username,
            chat_with=chat_with
        ).first()
        
        if chat_entry:
            chat_entry.unread_count = 0
        
        db.session.commit()
        
        return jsonify({'success': True}), 200
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Mark read failed: {e}")
        return jsonify({'error': 'Failed to mark messages as read'}), 500


@app.route('/api/chats/list', methods=['GET'])
def get_chat_list():
    try:
        username = request.args.get('username', '').strip()
        
        if not username:
            return jsonify({'error': 'Username required'}), 400
        
        chats = ChatList.query.filter_by(
            username=username
        ).order_by(ChatList.last_updated.desc()).all()
        
        return jsonify({
            'success': True,
            'chats': [chat.to_dict() for chat in chats]
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Chat list fetch failed: {e}")
        return jsonify({'error': 'Failed to fetch chat list'}), 500


@app.route('/api/messages/delete', methods=['DELETE'])
def delete_messages():
    """Delete all messages (for testing only - remove in production)"""
    try:
        Message.query.delete()
        ChatList.query.delete()
        db.session.commit()
        return jsonify({'success': True, 'message': 'All messages deleted'}), 200
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Delete failed: {e}")
        return jsonify({'error': 'Failed to delete messages'}), 500


# ========================
# HEALTH CHECK
# ========================

@app.route('/health', methods=['GET'])
def health():
    return jsonify({
        'status': 'ok',
        'service': 'Sajilo Chat Unified Server (E2EE Enabled)',
        'features': ['authentication', 'public_key_exchange', 'encrypted_storage', 'ratcheting'],
        'version': '2.0.0'
    }), 200


# Initialize database and run server
with app.app_context():
    db.create_all()
    print("✓ Database initialized with E2EE support!")

if __name__ == '__main__':
    print("=" * 60)
    print("    SAJILO CHAT UNIFIED SERVER (E2EE ENABLED) v2.0")
    print("=" * 60)
    print("Running on http://0.0.0.0:5001")
    print("Services:")
    print("  - Authentication: /auth/register, /auth/login")
    print("  - Public Keys: /api/keys/*")
    print("  - Encrypted Messages: /api/messages/*")
    print("  - Sessions: /api/session/*")
    app.run(host='0.0.0.0', port=5001, debug=False)
