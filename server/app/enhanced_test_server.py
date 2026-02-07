#!/usr/bin/env python3
"""
Enhanced Test Server for Sajilo Chat - Better Error Diagnostics
"""
import requests
import json
import time
from datetime import datetime

# Test configuration
BASE_URL = "http://localhost:5001"
TEST_USER1 = "debug_alice"
TEST_USER2 = "debug_bob"
TEST_PASSWORD = "TestPass123!"

def print_section(title):
    print("\n" + "="*60)
    print(f"  {title}")
    print("="*60)

def test_message_save_detailed():
    """Test message saving with detailed error reporting"""
    print_section("DETAILED MESSAGE SAVE TEST")
    
    # First, register and login
    print("\n1️⃣  Registering test users...")
    requests.post(f"{BASE_URL}/auth/register", json={
        'username': TEST_USER1,
        'password': TEST_PASSWORD,
        'public_key': 'test_key_alice_123'
    })
    requests.post(f"{BASE_URL}/auth/register", json={
        'username': TEST_USER2,
        'password': TEST_PASSWORD,
        'public_key': 'test_key_bob_456'
    })
    
    print("\n2️⃣  Logging in to get token...")
    response = requests.post(f"{BASE_URL}/auth/login", json={
        'username': TEST_USER1,
        'password': TEST_PASSWORD
    })
    
    if response.status_code != 200:
        print(f"  ❌ Login failed: {response.json()}")
        return
    
    token = response.json()['access_token']
    print(f"  ✅ Got token: {token[:20]}...")
    
    # Test 1: Save with ALL required fields
    print("\n3️⃣  Test 1: Save message with all required fields")
    message_data = {
        'sender': TEST_USER1,
        'recipient': TEST_USER2,
        'ciphertext': 'base64_encrypted_text_here',
        'nonce': 'base64_nonce_here',
        'mac': 'base64_mac_here',
        'type': 'dm'
    }
    
    print(f"  📤 Sending: {json.dumps(message_data, indent=2)}")
    response = requests.post(f"{BASE_URL}/api/messages/save", json=message_data)
    
    print(f"  📥 Status Code: {response.status_code}")
    print(f"  📥 Response: {json.dumps(response.json(), indent=2)}")
    
    if response.status_code == 201:
        print("  ✅ Message saved successfully!")
    else:
        print(f"  ❌ Failed: {response.json()}")
        return
    
    # Test 2: Retrieve the message
    print("\n4️⃣  Test 2: Retrieve message history")
    response = requests.get(
        f"{BASE_URL}/api/messages/history",
        params={
            'username': TEST_USER1,
            'chat_with': TEST_USER2,
            'limit': 10
        }
    )
    
    print(f"  📥 Status Code: {response.status_code}")
    result = response.json()
    print(f"  📥 Response: {json.dumps(result, indent=2)}")
    
    if response.status_code == 200 and result.get('messages'):
        print(f"  ✅ Retrieved {len(result['messages'])} message(s)")
        
        # Verify message structure
        msg = result['messages'][0]
        print("\n5️⃣  Verifying message structure:")
        required_fields = ['ciphertext', 'nonce', 'mac', 'from', 'to', 'type']
        for field in required_fields:
            if field in msg:
                print(f"  ✅ {field}: present ({type(msg[field]).__name__})")
            else:
                print(f"  ❌ {field}: MISSING")
    else:
        print(f"  ❌ Failed to retrieve: {result}")
    
    # Test 3: Chat list
    print("\n6️⃣  Test 3: Get chat list")
    response = requests.get(
        f"{BASE_URL}/api/chats/list",
        params={'username': TEST_USER1}
    )
    
    print(f"  📥 Status Code: {response.status_code}")
    result = response.json()
    print(f"  📥 Response: {json.dumps(result, indent=2)}")
    
    if response.status_code == 200:
        chats = result.get('chats', [])
        print(f"  ✅ Retrieved {len(chats)} chat(s)")
        for chat in chats:
            print(f"    - {chat}")
    else:
        print(f"  ❌ Failed: {result}")
    
    # Cleanup
    print("\n7️⃣  Cleanup: Deleting test data...")
    requests.delete(f"{BASE_URL}/api/messages/delete")
    print("  ✅ Cleanup complete")


def test_field_requirements():
    """Test what happens with missing fields"""
    print_section("FIELD REQUIREMENT TEST")
    
    tests = [
        {
            'name': 'Missing sender',
            'data': {
                'recipient': TEST_USER2,
                'ciphertext': 'test',
                'nonce': 'test',
                'mac': 'test',
                'type': 'dm'
            }
        },
        {
            'name': 'Missing ciphertext',
            'data': {
                'sender': TEST_USER1,
                'recipient': TEST_USER2,
                'nonce': 'test',
                'mac': 'test',
                'type': 'dm'
            }
        },
        {
            'name': 'Missing type',
            'data': {
                'sender': TEST_USER1,
                'recipient': TEST_USER2,
                'ciphertext': 'test',
                'nonce': 'test',
                'mac': 'test',
            }
        },
        {
            'name': 'All fields present',
            'data': {
                'sender': TEST_USER1,
                'recipient': TEST_USER2,
                'ciphertext': 'test',
                'nonce': 'test',
                'mac': 'test',
                'type': 'dm'
            }
        }
    ]
    
    for test in tests:
        print(f"\n🧪 {test['name']}")
        response = requests.post(f"{BASE_URL}/api/messages/save", json=test['data'])
        print(f"  Status: {response.status_code}")
        print(f"  Response: {response.json()}")
        
        if response.status_code == 201:
            print("  ✅ Accepted")
        elif response.status_code == 400:
            print("  ⚠️  Validation error (expected)")
        else:
            print("  ❌ Unexpected error")


def test_database_connection():
    """Test if database is accessible"""
    print_section("DATABASE CONNECTION TEST")
    
    print("\n1️⃣  Checking health endpoint...")
    try:
        response = requests.get(f"{BASE_URL}/health", timeout=2)
        print(f"  ✅ Server responding: {response.json()}")
    except Exception as e:
        print(f"  ❌ Server not responding: {e}")
        return False
    
    print("\n2️⃣  Checking if we can register a user (tests DB write)...")
    test_user = f"dbtest_{int(time.time())}"
    try:
        response = requests.post(f"{BASE_URL}/auth/register", json={
            'username': test_user,
            'password': TEST_PASSWORD
        })
        
        if response.status_code == 201:
            print(f"  ✅ Database write successful")
            return True
        else:
            print(f"  ❌ Database write failed: {response.json()}")
            return False
    except Exception as e:
        print(f"  ❌ Error: {e}")
        return False


def test_encryption_data_format():
    """Test the exact format that crypto_manager.dart produces"""
    print_section("ENCRYPTION DATA FORMAT TEST")
    
    print("\nℹ️  Testing data format from crypto_manager.dart")
    print("   Expected format from encryptMessage():")
    print("   {")
    print("     'ciphertext': 'base64string',")
    print("     'nonce': 'base64string',")
    print("     'mac': 'base64string',")
    print("     'counter': 123  // ⚠️  Not saved to DB")
    print("   }")
    
    # Simulate what the client sends
    client_encrypted_data = {
        'ciphertext': 'SGVsbG8gV29ybGQ=',  # "Hello World" in base64
        'nonce': 'MTIzNDU2Nzg5MDEy',      # Random nonce
        'mac': 'YWJjZGVmZ2hpamts',        # Random MAC
        'counter': 1                       # This field is extra
    }
    
    # What dm_server.py extracts
    server_data = {
        'sender': TEST_USER1,
        'recipient': TEST_USER2,
        'ciphertext': client_encrypted_data.get('ciphertext'),
        'nonce': client_encrypted_data.get('nonce'),
        'mac': client_encrypted_data.get('mac'),
        'type': 'dm'
    }
    
    print("\n1️⃣  Simulating client -> server data flow:")
    print(f"   Client sends: {json.dumps(client_encrypted_data, indent=6)}")
    print(f"   Server saves: {json.dumps(server_data, indent=6)}")
    
    # Test it
    print("\n2️⃣  Testing actual save...")
    response = requests.post(f"{BASE_URL}/api/messages/save", json=server_data)
    
    if response.status_code == 201:
        print("  ✅ Format is correct!")
    else:
        print(f"  ❌ Format issue: {response.json()}")


if __name__ == '__main__':
    print("="*60)
    print("  SAJILO CHAT ENHANCED DIAGNOSTIC TOOL")
    print("="*60)
    print(f"Testing server at: {BASE_URL}")
    print(f"Started at: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    
    # Run tests
    if test_database_connection():
        test_encryption_data_format()
        test_field_requirements()
        test_message_save_detailed()
    else:
        print("\n❌ Cannot proceed - database connection failed")
        print("   Check that unified_server.py is running on port 5001")
    
    print("\n" + "="*60)
    print("  DIAGNOSTIC COMPLETE")
    print("="*60)
