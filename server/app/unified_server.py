from flask import Flask, request, jsonify
from flask_sqlalchemy import SQLAlchemy
from flask_jwt_extended import JWTManager, create_access_token, jwt_required, get_jwt_identity
from werkzeug.security import generate_password_hash, check_password_hash
from datetime import datetime, timedelta
import os

app = Flask(__name__)

# Configuration
app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///unified.db'
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
app.config['JWT_SECRET_KEY'] = 'jwt-secret-change-me'  # Should match dm_server.py
app.config['JWT_ACCESS_TOKEN_EXPIRES'] = timedelta(hours=24)

db = SQLAlchemy(app)
jwt = JWTManager(app)

# ============================================================================
# DATABASE MODELS
# ============================================================================

# User model (for authentication)
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password_hash = db.Column(db.String(200), nullable=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)

    def set_password(self, password):
        self.password_hash = generate_password_hash(password)
    
    def check_password(self, password):
        return check_password_hash(self.password_hash, password)

# Message model (for chat history)
class Message(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    sender = db.Column(db.String(100), nullable=False)
    recipient = db.Column(db.String(100), nullable=False)
    message = db.Column(db.Text, nullable=False)
    timestamp = db.Column(db.DateTime, default=datetime.utcnow)
    message_type = db.Column(db.String(20), nullable=False)

    def to_dict(self):
        return {
            'id': self.id,
            'from': self.sender,
            'to': self.recipient,
            'message': self.message,
            'timestamp': self.timestamp.isoformat(),
            'type': self.message_type
        }

# ChatList model
class ChatList(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(100), nullable=False)
    chat_with = db.Column(db.String(100), nullable=False)
    last_message = db.Column(db.Text)
    last_updated = db.Column(db.DateTime, default=datetime.utcnow)

    def to_dict(self):
        return {
            'username': self.username,
            'chat_with': self.chat_with,
            'last_message': self.last_message,
            'last_updated': self.last_updated.isoformat()
        }

# ============================================================================
# AUTHENTICATION ROUTES
# ============================================================================

@app.route('/auth/register', methods=['POST'])
def register():
    try:
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        
        if not username or not password:
            return jsonify({'error': 'Username and password required'}), 400
        
        if len(password) < 8:
            return jsonify({'error': 'Password must be at least 8 characters'}), 400
        
        if User.query.filter_by(username=username).first():
            return jsonify({'error': 'Username already exists'}), 409
        
        user = User(username=username)
        user.set_password(password)
        db.session.add(user)
        db.session.commit()
        
        return jsonify({
            'message': 'User registered successfully',
            'username': username
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/auth/login', methods=['POST'])
def login():
    try:
        data = request.get_json()
        username = data.get('username')
        password = data.get('password')
        
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
        return jsonify({'error': str(e)}), 500

# ============================================================================
# CHAT HISTORY API ROUTES
# ============================================================================

@app.route('/api/messages/save', methods=['POST'])
def save_message():
    try:
        data = request.json
        
        message = Message(
            sender=data['sender'],
            recipient=data['recipient'],
            message=data['message'],
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
            
            chat_entry.last_message = data['message']
            chat_entry.last_updated = datetime.utcnow()
            
            # Update for recipient
            chat_entry2 = ChatList.query.filter_by(
                username=data['recipient'],
                chat_with=data['sender']
            ).first()
            
            if not chat_entry2:
                chat_entry2 = ChatList(
                    username=data['recipient'],
                    chat_with=data['sender']
                )
                db.session.add(chat_entry2)
            
            chat_entry2.last_message = data['message']
            chat_entry2.last_updated = datetime.utcnow()
        
        db.session.commit()
        return jsonify({'success': True, 'message': 'Message saved'}), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@app.route('/api/messages/history', methods=['GET'])
def get_message_history():
    try:
        username = request.args.get('username')
        chat_with = request.args.get('chat_with')
        limit = request.args.get('limit', 100, type=int)
        
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
        return jsonify({'error': str(e)}), 500

@app.route('/api/chats/list', methods=['GET'])
def get_chat_list():
    try:
        username = request.args.get('username')
        chats = ChatList.query.filter_by(
            username=username
        ).order_by(ChatList.last_updated.desc()).all()
        
        return jsonify({
            'success': True,
            'chats': [chat.to_dict() for chat in chats]
        }), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500

@app.route('/api/messages/delete', methods=['DELETE'])
def delete_messages():
    try:
        Message.query.delete()
        ChatList.query.delete()
        db.session.commit()
        return jsonify({'success': True, 'message': 'All messages deleted'}), 200
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

# ============================================================================
# HEALTH CHECK
# ============================================================================

@app.route('/health', methods=['GET'])
def health():
    return jsonify({'status': 'ok', 'service': 'Sajilo Chat Unified Server'}), 200

# ============================================================================
# INITIALIZATION
# ============================================================================

with app.app_context():
    db.create_all()
    print("  Database initialized!")

if __name__ == '__main__':
    print("=" * 60)
    print("    SAJILO CHAT UNIFIED SERVER")
    print("=" * 60)
    print("Running on http://0.0.0.0:5001")
    print("Services:")
    print("  - Authentication: /auth/register, /auth/login")
    print("  - Chat History: /api/messages/*")
    print("=" * 60)
    app.run(host='0.0.0.0', port=5001, debug=True)