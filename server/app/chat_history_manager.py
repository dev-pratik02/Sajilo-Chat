"""
Chat History Manager Module
Handles all database operations for encrypted message history and chat lists
"""
import requests
from typing import List, Dict, Optional
from datetime import datetime

class ChatHistoryManager:
    """Manages encrypted chat history through Flask DB API"""
    
    def __init__(self, db_api_url: str = "http://localhost:5001/api"):
        self.db_api_url = db_api_url
        self.timeout = 2
    
    def save_encrypted_message(self, sender: str, recipient: str, encrypted_data: Dict, msg_type: str) -> bool:
        """
        Save an encrypted message to the database
        
        Args:
            sender: Username of the sender
            recipient: Username of recipient or 'group'
            encrypted_data: Dict containing ciphertext, nonce, mac
            msg_type: 'group' or 'dm'
            
        Returns:
            bool: True if saved successfully, False otherwise
        """
        try:
            response = requests.post(
                f"{self.db_api_url}/messages/save",
                json={
                    'sender': sender,
                    'recipient': recipient,
                    'ciphertext': encrypted_data.get('ciphertext'),
                    'nonce': encrypted_data.get('nonce'),
                    'mac': encrypted_data.get('mac'),
                    'type': msg_type
                },
                timeout=self.timeout
            )
            return response.status_code == 201
        except Exception as e:
            print(f"[ChatHistory] Error saving encrypted message: {e}")
            return False
    
    def get_message_history(self, username: str, chat_with: str, limit: int = 100) -> Optional[List[Dict]]:
        """
        Get encrypted message history for a specific chat
        
        Args:
            username: Current user's username
            chat_with: Username of chat partner or 'group'
            limit: Maximum number of messages to retrieve
            
        Returns:
            List of encrypted message dictionaries or None if error
        """
        try:
            response = requests.get(
                f"{self.db_api_url}/messages/history",
                params={
                    'username': username,
                    'chat_with': chat_with,
                    'limit': limit
                },
                timeout=self.timeout
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('messages', [])
            else:
                print(f"[ChatHistory] Error fetching history: {response.status_code}")
                return None
                
        except Exception as e:
            print(f"[ChatHistory] Error fetching history: {e}")
            return None
    
    def get_chat_list(self, username: str) -> Optional[List[Dict]]:
        """
        Get list of all chats for a user
        
        Args:
            username: Username to get chat list for
            
        Returns:
            List of chat dictionaries or None if error
        """
        try:
            response = requests.get(
                f"{self.db_api_url}/chats/list",
                params={'username': username},
                timeout=self.timeout
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('chats', [])
            else:
                return None
                
        except Exception as e:
            print(f"[ChatHistory] Error fetching chat list: {e}")
            return None
    
    def upload_public_key(self, username: str, public_key: str) -> bool:
        """
        Upload user's public identity key
        
        Args:
            username: Username
            public_key: Base64 encoded public key
            
        Returns:
            bool: True if successful
        """
        try:
            response = requests.post(
                f"{self.db_api_url}/keys/upload",
                json={
                    'username': username,
                    'public_key': public_key
                },
                timeout=self.timeout
            )
            return response.status_code == 200
        except Exception as e:
            print(f"[ChatHistory] Error uploading public key: {e}")
            return False
    
    def get_public_key(self, username: str) -> Optional[str]:
        """
        Get a user's public key
        
        Args:
            username: Username to get key for
            
        Returns:
            Base64 encoded public key or None if not found
        """
        try:
            response = requests.get(
                f"{self.db_api_url}/keys/get/{username}",
                timeout=self.timeout
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('public_key')
            else:
                return None
                
        except Exception as e:
            print(f"[ChatHistory] Error fetching public key: {e}")
            return None
    
    def get_public_keys_batch(self, usernames: List[str]) -> Optional[Dict[str, str]]:
        """
        Get multiple users' public keys at once
        
        Args:
            usernames: List of usernames
            
        Returns:
            Dict mapping username to public key
        """
        try:
            response = requests.post(
                f"{self.db_api_url}/keys/batch",
                json={'usernames': usernames},
                timeout=self.timeout
            )
            
            if response.status_code == 200:
                data = response.json()
                return data.get('keys', {})
            else:
                return None
                
        except Exception as e:
            print(f"[ChatHistory] Error fetching public keys: {e}")
            return None
    
    def delete_all_messages(self) -> bool:
        """
        Delete all messages (for testing purposes)
        
        Returns:
            bool: True if successful
        """
        try:
            response = requests.delete(
                f"{self.db_api_url}/messages/delete",
                timeout=self.timeout
            )
            return response.status_code == 200
        except Exception as e:
            print(f"[ChatHistory] Error deleting messages: {e}")
            return False


# Message formatting utilities
class MessageFormatter:
    """Formats encrypted messages for sending/receiving"""
    
    @staticmethod
    def format_encrypted_for_storage(sender: str, recipient: str, encrypted_data: Dict, msg_type: str) -> Dict:
        """Format encrypted message for database storage"""
        return {
            'sender': sender,
            'recipient': recipient,
            'ciphertext': encrypted_data['ciphertext'],
            'nonce': encrypted_data['nonce'],
            'mac': encrypted_data['mac'],
            'type': msg_type,
            'timestamp': datetime.utcnow().isoformat()
        }
    
    @staticmethod
    def format_encrypted_for_client(message_data: Dict) -> Dict:
        """Format encrypted message for sending to client"""
        return {
            'from': message_data.get('from', message_data.get('sender')),
            'to': message_data.get('to', message_data.get('recipient')),
            'encrypted_data': {
                'ciphertext': message_data.get('ciphertext'),
                'nonce': message_data.get('nonce'),
                'mac': message_data.get('mac'),
            },
            'timestamp': message_data.get('timestamp'),
            'type': message_data.get('type')
        }
    
    @staticmethod
    def format_history_response(chat_with: str, messages: List[Dict]) -> Dict:
        """Format encrypted history response for client"""
        return {
            'type': 'history',
            'chat_with': chat_with,
            'messages': [
                MessageFormatter.format_encrypted_for_client(msg)
                for msg in messages
            ]
        }
