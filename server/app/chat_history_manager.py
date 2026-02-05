"""
Chat History Manager Module (FIXED VERSION)
Handles all database operations for message history and chat lists
"""
import requests
from typing import List, Dict, Optional
from datetime import datetime, timezone
import logging

# FIXED: Add logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class ChatHistoryManager:
    """Manages chat history through Flask DB API"""
    
    def __init__(self, db_api_url: str = "http://localhost:5001/api"):
        self.db_api_url = db_api_url
        self.timeout = 5  # FIXED: Increased from 2 to 5 seconds
        self._test_connection()
    
    def _test_connection(self) -> bool:
        """Test if the database API is reachable"""
        try:
            response = requests.get(
                f"{self.db_api_url.replace('/api', '')}/health",
                timeout=2
            )
            if response.status_code == 200:
                logger.info(f"[ChatHistory] ✓ Connected to database API")
                return True
            else:
                logger.warning(f"[ChatHistory] ⚠️ Database API returned {response.status_code}")
                return False
        except requests.exceptions.ConnectionError:
            logger.error(f"[ChatHistory] ✗ Could not connect to database API at {self.db_api_url}")
            return False
        except requests.exceptions.Timeout:
            logger.error(f"[ChatHistory] ✗ Database API connection timeout")
            return False
        except Exception as e:
            logger.error(f"[ChatHistory] ✗ Unexpected error: {e}")
            return False
    
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
            
            if response.status_code == 201:
                logger.debug(f"[ChatHistory] ✓ Saved message from {sender}")
                return True
            else:
                logger.error(f"[ChatHistory] ✗ Failed to save message: {response.status_code}")
                return False
                
        except requests.exceptions.ConnectionError:
            logger.error(f"[ChatHistory] ✗ Connection error while saving message")
            return False
        except requests.exceptions.Timeout:
            logger.error(f"[ChatHistory] ✗ Timeout while saving message")
            return False
        except requests.exceptions.RequestException as e:
            logger.error(f"[ChatHistory] ✗ Request error while saving message: {e}")
            return False
        except Exception as e:
            logger.error(f"[ChatHistory] ✗ Unexpected error saving message: {e}")
            return False
    
    def get_message_history(
        self, 
        username: str, 
        chat_with: str, 
        limit: int = 100
    ) -> Optional[List[Dict]]:
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
                messages = data.get('messages', [])
                logger.info(f"[ChatHistory] ✓ Fetched {len(messages)} messages for {username} <-> {chat_with}")
                return messages
            else:
                logger.error(f"[ChatHistory] ✗ Error fetching history: {response.status_code}")
                try:
                    error_data = response.json()
                    logger.error(f"[ChatHistory] Error details: {error_data.get('error')}")
                except:
                    pass
                return None
                
        except requests.exceptions.ConnectionError:
            logger.error(f"[ChatHistory] ✗ Connection error while fetching history")
            return None
        except requests.exceptions.Timeout:
            logger.error(f"[ChatHistory] ✗ Timeout while fetching history")
            return None
        except requests.exceptions.RequestException as e:
            logger.error(f"[ChatHistory] ✗ Request error while fetching history: {e}")
            return None
        except Exception as e:
            logger.error(f"[ChatHistory] ✗ Unexpected error fetching history: {e}")
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
                chats = data.get('chats', [])
                logger.info(f"[ChatHistory] ✓ Fetched {len(chats)} chats for {username}")
                return chats
            else:
                logger.error(f"[ChatHistory] ✗ Error fetching chat list: {response.status_code}")
                return None
                
        except requests.exceptions.ConnectionError:
            logger.error(f"[ChatHistory] ✗ Connection error while fetching chat list")
            return None
        except requests.exceptions.Timeout:
            logger.error(f"[ChatHistory] ✗ Timeout while fetching chat list")
            return None
        except requests.exceptions.RequestException as e:
            logger.error(f"[ChatHistory] ✗ Request error while fetching chat list: {e}")
            return None
        except Exception as e:
            logger.error(f"[ChatHistory] ✗ Unexpected error fetching chat list: {e}")
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
            
            if response.status_code == 200:
                logger.warning(f"[ChatHistory] ⚠️ All messages deleted")
                return True
            else:
                logger.error(f"[ChatHistory] ✗ Failed to delete messages: {response.status_code}")
                return False
                
        except requests.exceptions.ConnectionError:
            logger.error(f"[ChatHistory] ✗ Connection error while deleting messages")
            return False
        except requests.exceptions.Timeout:
            logger.error(f"[ChatHistory] ✗ Timeout while deleting messages")
            return False
        except requests.exceptions.RequestException as e:
            logger.error(f"[ChatHistory] ✗ Request error while deleting messages: {e}")
            return False
        except Exception as e:
            logger.error(f"[ChatHistory] ✗ Unexpected error deleting messages: {e}")
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
            'timestamp': datetime.now(timezone.utc).isoformat()  # FIXED: Timezone aware
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
    
    @staticmethod
    def validate_timestamp(timestamp_str: str) -> bool:
        """
        Validate that timestamp is in ISO 8601 format
        
        Args:
            timestamp_str: Timestamp string to validate
            
        Returns:
            bool: True if valid, False otherwise
        """
        try:
            datetime.fromisoformat(timestamp_str.replace('Z', '+00:00'))
            return True
        except (ValueError, AttributeError):
            return False
# End of chat_history_manager.py