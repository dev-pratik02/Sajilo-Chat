"""
Chat History Manager Module
Handles all database operations for message history and chat lists
"""
import requests
from typing import List, Dict, Optional
from datetime import datetime

class ChatHistoryManager:
    """Manages chat history through Flask DB API"""
    
    def __init__(self, db_api_url: str = "http://localhost:5001/api"):
        self.db_api_url = db_api_url
        self.timeout = 2
    
    def save_message(self, sender: str, recipient: str, message: str, msg_type: str) -> bool:
        """
        Save a message to the database
        
        Args:
            sender: Username of the sender
            recipient: Username of recipient or 'group'
            message: Message content
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
                    'message': message,
                    'type': msg_type
                },
                timeout=self.timeout
            )
            return response.status_code == 201
        except Exception as e:
            print(f"[ChatHistory] Error saving message: {e}")
            return False
    
    def get_message_history(self, username: str, chat_with: str, limit: int = 100) -> Optional[List[Dict]]:
        """
        Get message history for a specific chat
        
        Args:
            username: Current user's username
            chat_with: Username of chat partner or 'group'
            limit: Maximum number of messages to retrieve
            
        Returns:
            List of message dictionaries or None if error
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
    """Formats messages for sending/receiving"""
    
    @staticmethod
    def format_for_storage(sender: str, recipient: str, message: str, msg_type: str) -> Dict:
        """Format message for database storage"""
        return {
            'sender': sender,
            'recipient': recipient,
            'message': message,
            'type': msg_type,
            'timestamp': datetime.utcnow().isoformat()
        }
    
    @staticmethod
    def format_for_client(message_data: Dict) -> Dict:
        """Format message for sending to client"""
        return {
            'from': message_data.get('from', message_data.get('sender')),
            'message': message_data.get('message'),
            'timestamp': message_data.get('timestamp'),
            'type': message_data.get('type')
        }
    
    @staticmethod
    def format_history_response(chat_with: str, messages: List[Dict]) -> Dict:
        """Format history response for client"""
        return {
            'type': 'history',
            'chat_with': chat_with,
            'messages': messages
        }