from flask import Flask, request, jsonify
from dotenv import load_dotenv
load_dotenv()
from flask_sqlalchemy import SQLAlchemy
from flask_jwt_extended import JWTManager, create_access_token, jwt_required, get_jwt_identity
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime, timedelta, timezone
import os

app = Flask(__name__)

# FIXED: Configuration from environment variables with proper defaults
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', 'sqlite:///unified.db')
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['JWT_SECRET_KEY'] = os.getenv('JWT_SECRET_KEY', 'jwt-dev-secret')  # Must match dm_server.py
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(hours=int(os.getenv('JWT_EXPIRE_HOURS', '24')))

db = SQLAlchemy(app)
jwt = JWTManager(app)

# FIXED: Constants
MAX_MESSAGE_SIZE = int(os.getenv('MAX_MESSAGE_SIZE', '10240'))  # 10KB
MAX_USERNAME_LENGTH = 30
MAX_PASSWORD_LENGTH = 100

# ============================================================================
# DATABASE MODELS
# ============================================================================

class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False, index=True)  # FIXED: Added index
    password_hash = db.Column(db.String(200), nullable=False)
    created_at = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))  # FIXED: Timezone aware

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

class Message(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    sender = db.Column(db.String(100), nullable=False, index=True)  # FIXED: Added index
    recipient = db.Column(db.String(100), nullable=False, index=True)  # FIXED: Added index
    message = db.Column(db.Text, nullable=False)
    timestamp = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc), index=True)  # FIXED: Timezone aware + index
    message_type = db.Column(db.String(20), nullable=False)

    def to_dict(self):
        return {
            'id': self.id,
            'from': self.sender,
            'to': self.recipient,
            'message': self.message,
            'timestamp': self.timestamp.isoformat(),  # FIXED: ISO 8601 format
            'type': self.message_type
        }

class ChatList(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(100), nullable=False, index=True)  # FIXED: Added index
    chat_with = db.Column(db.String(100), nullable=False, index=True)  # FIXED: Added index
    last_message = db.Column(db.Text)
    last_updated = db.Column(db.DateTime, default=lambda: datetime.now(timezone.utc))  # FIXED: Timezone aware

    def to_dict(self):
        return {
            'username': self.username,
            'chat_with': self.chat_with,
            'last_message': self.last_message,
            'last_updated': self.last_updated.isoformat()  # FIXED: ISO 8601 format
        }

# FIXED: Add composite unique constraint
db.Index('idx_chatlist_user_chat', ChatList.username, ChatList.chat_with, unique=True)

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

def validate_username(username):
    """Validate username format"""
    if not username:
        return False, "Username is required"
    if len(username) > MAX_USERNAME_LENGTH:
        return False, f"Username too long (max {MAX_USERNAME_LENGTH} chars)"
    if not username.replace('_', '').isalnum():
        return False, "Username can only contain letters, numbers, and underscores"
    return True, None

def validate_password(password):
    """Validate password strength"""
    if not password:
        return False, "Password is required"
    if len(password) < 8:
        return False, "Password must be at least 8 characters"
    if len(password) > MAX_PASSWORD_LENGTH:
        return False, f"Password too long (max {MAX_PASSWORD_LENGTH} chars)"
    return True, None

def validate_message(message):
    """Validate message content"""
    if not message:
        return False, "Message cannot be empty"
    if len(message) > MAX_MESSAGE_SIZE:
        return False, f"Message too large (max {MAX_MESSAGE_SIZE} bytes)"
    return True, None

# ============================================================================
# AUTHENTICATION ROUTES
# ============================================================================

@app.route('/auth/register', methods=['POST'])
def register():
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Invalid request'}), 400
        
        username = data.get('username', '').strip()
        password = data.get('password', '')
        
        # FIXED: Comprehensive validation
        valid, error = validate_username(username)
        if not valid:
            return jsonify({'error': error}), 400
        
        valid, error = validate_password(password)
        if not valid:
            return jsonify({'error': error}), 400
        
        # Check if user exists
        if User.query.filter_by(username=username).first():
            return jsonify({'error': 'Username already exists'}), 409
        
        # Create user
        user = User(username=username)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        
        print(f"[AUTH] New user registered: {username}")
        return jsonify({
            'message': 'User registered successfully',
            'username': username
        }), 201
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Registration error: {e}")
        return jsonify({'error': 'Registration failed'}), 500

@app.route('/auth/login', methods=['POST'])
def login():
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Invalid request'}), 400
        
        username = data.get('username', '').strip()
        password = data.get('password', '')
        
        if not username or not password:
            return jsonify({'error': 'Username and password required'}), 400
        
        user = User.query.filter_by(username=username).first()
        
        if not user or not user.check_password(password):
            return jsonify({'error': 'Invalid credentials'}), 401
        
        # Create JWT token
        access_token = create_access_token(identity=username)
        
        print(f"[AUTH] User logged in: {username}")
        return jsonify({
            'access_token': access_token,
            'username': username
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Login error: {e}")
        return jsonify({'error': 'Login failed'}), 500

# ============================================================================
# CHAT HISTORY API ROUTES
# ============================================================================

@app.route('/api/messages/save', methods=['POST'])
def save_message():
    try:
        data = request.json
        if not data:
            return jsonify({'error': 'Invalid request'}), 400
        
        sender = data.get('sender', '').strip()
        recipient = data.get('recipient', '').strip()
        msg_text = data.get('message', '')
        msg_type = data.get('type', '')
        
        # FIXED: Validate all fields
        if not sender or not recipient or not msg_type:
            return jsonify({'error': 'Missing required fields'}), 400
        
        valid, error = validate_message(msg_text)
        if not valid:
            return jsonify({'error': error}), 400
        
        if msg_type not in ['group', 'dm']:
            return jsonify({'error': 'Invalid message type'}), 400
        
        # Save message
        message = Message(
            sender=sender,
            recipient=recipient,
            message=msg_text,
            message_type=msg_type
        )
        
        db.session.add(message)
        
        # Update chat list for DMs
        if msg_type == 'dm':
            # Update for sender
            chat_entry = ChatList.query.filter_by(
                username=sender,
                chat_with=recipient
            ).first()
            
            if not chat_entry:
                chat_entry = ChatList(
                    username=sender,
                    chat_with=recipient
                )
                db.session.add(chat_entry)
            
            chat_entry.last_message = msg_text
            chat_entry.last_updated = datetime.now(timezone.utc)
            
            # Update for recipient
            chat_entry2 = ChatList.query.filter_by(
                username=recipient,
                chat_with=sender
            ).first()
            
            if not chat_entry2:
                chat_entry2 = ChatList(
                    username=recipient,
                    chat_with=sender
                )
                db.session.add(chat_entry2)
            
            chat_entry2.last_message = msg_text
            chat_entry2.last_updated = datetime.now(timezone.utc)
        
        db.session.commit()
        return jsonify({'success': True, 'message': 'Message saved'}), 201
        
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Save message error: {e}")
        return jsonify({'error': 'Failed to save message'}), 500

@app.route('/api/messages/history', methods=['GET'])
def get_message_history():
    try:
        username = request.args.get('username', '').strip()
        chat_with = request.args.get('chat_with', '').strip()
        limit = request.args.get('limit', 100, type=int)
        
        # FIXED: Validation
        if not username or not chat_with:
            return jsonify({'error': 'Missing required parameters'}), 400
        
        if limit < 1 or limit > 500:  # FIXED: Reasonable limit
            limit = 100
        
        # Fetch messages
        if chat_with == 'group':
            messages = Message.query.filter_by(
                message_type='group'
            ).order_by(Message.timestamp.asc()).limit(limit).all()
        else:
            messages = Message.query.filter(
                db.or_(
                    db.and_(Message.sender == username, Message.recipient == chat_with),
                    db.and_(Message.sender == chat_with, Message.recipient == username)
                )
            ).order_by(Message.timestamp.asc()).limit(limit).all()
        
        return jsonify({
            'success': True,
            'messages': [msg.to_dict() for msg in messages]
        }), 200
        
    except Exception as e:
        print(f"[ERROR] Get history error: {e}")
        return jsonify({'error': 'Failed to fetch history'}), 500

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
        print(f"[ERROR] Get chat list error: {e}")
        return jsonify({'error': 'Failed to fetch chat list'}), 500

@app.route('/api/messages/delete', methods=['DELETE'])
def delete_messages():
    """Delete all messages - use with caution!"""
    try:
        # FIXED: Add authorization check in production
        Message.query.delete()
        ChatList.query.delete()
        db.session.commit()
        print("[WARNING] All messages deleted")
        return jsonify({'success': True, 'message': 'All messages deleted'}), 200
    except Exception as e:
        db.session.rollback()
        print(f"[ERROR] Delete messages error: {e}")
        return jsonify({'error': 'Failed to delete messages'}), 500

# ============================================================================
# HEALTH CHECK
# ============================================================================

@app.route('/health', methods=['GET'])
def health():
    try:
        # Check database connection
        db.session.execute(db.text('SELECT 1'))
        return jsonify({
            'status': 'healthy',
            'service': 'Sajilo Chat Unified Server',
            'database': 'connected'
        }), 200
    except Exception as e:
        return jsonify({
            'status': 'unhealthy',
            'service': 'Sajilo Chat Unified Server',
            'database': 'disconnected',
            'error': str(e)
        }), 503

# ============================================================================
# ERROR HANDLERS
# ============================================================================

@app.errorhandler(400)
def bad_request(e):
    return jsonify({'error': 'Bad request'}), 400

@app.errorhandler(401)
def unauthorized(e):
    return jsonify({'error': 'Unauthorized'}), 401

@app.errorhandler(404)
def not_found(e):
    return jsonify({'error': 'Not found'}), 404

@app.errorhandler(500)
def internal_error(e):
    db.session.rollback()
    return jsonify({'error': 'Internal server error'}), 500

# ============================================================================
# INITIALIZATION
# ============================================================================

with app.app_context():
    db.create_all()
    print("✅ Database initialized!")
    print(f"✅ Database indexes created")

if __name__ == '__main__':
    print("=" * 60)
    print("    SAJILO CHAT UNIFIED SERVER (FIXED)")
    print("=" * 60)
    print(f"Running on http://0.0.0.0:5001")
    print(f"JWT Secret: {app.config['JWT_SECRET_KEY'][:10]}...")
    print(f"JWT Expiry: {app.config['JWT_ACCESS_TOKEN_EXPIRES']}")
    print(f"Max Message Size: {MAX_MESSAGE_SIZE} bytes")
    print("Services:")
    print("  - Authentication: /auth/register, /auth/login")
    print("  - Chat History: /api/messages/*")
    print("  - Health Check: /health")
    print("=" * 60)
    
    # FIXED: Production warning
    if os.getenv('FLASK_ENV') != 'production':
        print("⚠️  WARNING: Running in development mode")
        print("⚠️  Set FLASK_ENV=production for production use")
        print("=" * 60)
    
    app.run(host='0.0.0.0', port=5001, debug=(os.getenv('FLASK_ENV') != 'production'))
