import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:crypto/crypto.dart' as crypto;

/// Manages end-to-end encryption for messages
/// Uses ECDH for key exchange and AES-GCM for message encryption
/// 
/// Session key derivation now uses canonical ordering
class CryptoManager {
  // Cryptographic algorithms
  final _keyExchangeAlgo = X25519();
  final _aesGcm = AesGcm.with256bits();
  
  // User's persistent identity key pair
  SimpleKeyPair? _identityKeyPair;
  
  // Current username (needed for canonical key derivation)
  String? _currentUsername;
  
  // Session keys per chat (ECDH derived)
  final Map<String, SecretKey> _sessionKeys = {};
  
  // Other users' public keys
  final Map<String, SimplePublicKey> _publicKeys = {};
  
  // Message counters for ratcheting (optional forward secrecy)
  final Map<String, int> _messageCounters = {};
  
  CryptoManager();
  
  /// Initialize crypto manager - load or generate identity keys
  Future<void> initialize(String username) async {
    try {
      print('[Crypto] Initializing for user: $username');
      _currentUsername = username;  // Store username for key derivation
      
      final prefs = await SharedPreferences.getInstance();
      
      // Try to load existing identity key
      final storedPrivateKey = prefs.getString('identity_private_key_$username');
      
      if (storedPrivateKey != null) {
        // Load existing key
        print('[Crypto] Loading existing identity key');
        try {
          final privateKeyBytes = base64Decode(storedPrivateKey);
          final storedPublicKey = prefs.getString('identity_public_key_$username');
          
          if (storedPublicKey == null) {
            print('[Crypto] Warning: Public key missing, regenerating keys');
            await _generateNewKeys(username, prefs);
            return;
          }
          
          final publicKeyBytes = base64Decode(storedPublicKey);
          
          _identityKeyPair = SimpleKeyPairData(
            privateKeyBytes,
            publicKey: SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519),
            type: KeyPairType.x25519,
          );
          
          print('[Crypto] Identity key loaded successfully');
        } catch (e) {
          print('[Crypto] Error loading keys: $e, regenerating...');
          await _generateNewKeys(username, prefs);
        }
      } else {
        // Generate new identity key pair
        await _generateNewKeys(username, prefs);
      }
    } catch (e) {
      print('[Crypto] ERROR in initialize: $e');
      rethrow;
    }
  }
  
  /// Generate and store new identity keys
  Future<void> _generateNewKeys(String username, SharedPreferences prefs) async {
    print('[Crypto] Generating new identity key pair');
    _identityKeyPair = await _keyExchangeAlgo.newKeyPair();
    
    // Extract and store keys
    final privateKeyBytes = await _identityKeyPair!.extractPrivateKeyBytes();
    final publicKey = await _identityKeyPair!.extractPublicKey();
    final publicKeyBytes = publicKey.bytes;
    
    await prefs.setString('identity_private_key_$username', base64Encode(privateKeyBytes));
    await prefs.setString('identity_public_key_$username', base64Encode(publicKeyBytes));
    
    print('[Crypto] New identity key pair generated and stored');
  }
  
  /// Get user's public identity key (to send to server)
  Future<String> getPublicIdentityKey() async {
    if (_identityKeyPair == null) {
      throw Exception('Crypto manager not initialized');
    }
    
    try {
      final publicKey = await _identityKeyPair!.extractPublicKey();
      return base64Encode(publicKey.bytes);
    } catch (e) {
      print('[Crypto] Error getting public key: $e');
      rethrow;
    }
  }
  
  /// Store another user's public key
  void storePublicKey(String username, String publicKeyBase64) {
    try {
      final publicKeyBytes = base64Decode(publicKeyBase64);
      _publicKeys[username] = SimplePublicKey(publicKeyBytes, type: KeyPairType.x25519);
      print('[Crypto] Stored public key for: $username');
    } catch (e) {
      print('[Crypto] Error storing public key: $e');
      rethrow;
    }
  }
  
  ///  Derive session key with canonical ordering
  /// This ensures both users derive the SAME key
  Future<void> deriveSessionKey(String chatWith) async {
    if (_identityKeyPair == null) {
      throw Exception('Crypto manager not initialized');
    }
    
    if (_currentUsername == null) {
      throw Exception('Current username not set');
    }
    
    final theirPublicKey = _publicKeys[chatWith];
    if (theirPublicKey == null) {
      throw Exception('Public key not found for: $chatWith');
    }
    
    try {
      print('[Crypto] Deriving session key with: $chatWith');
      
      // Perform ECDH
      final sharedSecret = await _keyExchangeAlgo.sharedSecretKey(
        keyPair: _identityKeyPair!,
        remotePublicKey: theirPublicKey,
      );
      
      // Extract shared secret bytes
      final sharedSecretBytes = await sharedSecret.extractBytes();
      
      // Use canonical (alphabetically sorted) username ordering
      // This ensures both users use the SAME info string for HKDF
      final users = [_currentUsername!, chatWith]..sort();
      final canonicalInfo = 'sajilo_chat_session_${users[0]}_${users[1]}';
      
      print('[Crypto] Using canonical info: $canonicalInfo');
      
      // Derive session key using HKDF (via SHA-256)
      final sessionKeyBytes = _hkdf(
        sharedSecretBytes,
        info: utf8.encode(canonicalInfo),  //   Both users use same string
        length: 32, // 256 bits for AES-256
      );
      
      _sessionKeys[chatWith] = SecretKey(sessionKeyBytes);
      _messageCounters[chatWith] = 0;
      
      print('[Crypto]   Session key derived for: $chatWith');
      print('[Crypto] Key fingerprint: ${_getKeyFingerprint(sessionKeyBytes)}');
      
    } catch (e) {
      print('[Crypto] Error deriving session key: $e');
      rethrow;
    }
  }
  
  /// Get key fingerprint for debugging (first 8 bytes as hex)
  String _getKeyFingerprint(List<int> keyBytes) {
    return keyBytes.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join(':');
  }
  
  /// Encrypt a message for a specific chat
  Future<Map<String, dynamic>> encryptMessage(String chatWith, String plaintext) async {
    final sessionKey = _sessionKeys[chatWith];
    if (sessionKey == null) {
      throw Exception('No session key for: $chatWith');
    }
    
    try {
      // Generate random nonce (96 bits for AES-GCM)
      final nonce = _aesGcm.newNonce();
      
      // Encrypt the message
      final secretBox = await _aesGcm.encrypt(
        utf8.encode(plaintext),
        secretKey: sessionKey,
        nonce: nonce,
      );
      
      // Increment message counter for potential ratcheting
      _messageCounters[chatWith] = (_messageCounters[chatWith] ?? 0) + 1;
      
      // Return encrypted data (WITHOUT counter - server doesn't need it)
      return {
        'ciphertext': base64Encode(secretBox.cipherText),
        'nonce': base64Encode(secretBox.nonce),
        'mac': base64Encode(secretBox.mac.bytes),
      };
    } catch (e) {
      print('[Crypto] Encryption error: $e');
      rethrow;
    }
  }
  
  /// Decrypt a received message
  Future<String> decryptMessage(String chatWith, Map<String, dynamic> encryptedData) async {
    final sessionKey = _sessionKeys[chatWith];
    if (sessionKey == null) {
      throw Exception('No session key for: $chatWith');
    }
    
    try {
      // Validate required fields
      if (!encryptedData.containsKey('ciphertext') ||
          !encryptedData.containsKey('nonce') ||
          !encryptedData.containsKey('mac')) {
        throw Exception('Invalid encrypted data: missing required fields');
      }
      
      // Reconstruct SecretBox from encrypted data
      final ciphertext = base64Decode(encryptedData['ciphertext']);
      final nonce = base64Decode(encryptedData['nonce']);
      final mac = Mac(base64Decode(encryptedData['mac']));
      
      final secretBox = SecretBox(ciphertext, nonce: nonce, mac: mac);
      
      // Decrypt
      final plaintext = await _aesGcm.decrypt(
        secretBox,
        secretKey: sessionKey,
      );
      
      return utf8.decode(plaintext);
    } on SecretBoxAuthenticationError {
      // MAC validation failed - message was tampered with OR key mismatch
      print('[Crypto] MAC validation failed');
      print('[Crypto] This could mean:');
      print('[Crypto]   1. Message was tampered with');
      print('[Crypto]   2. Session keys don\'t match (derivation issue)');
      print('[Crypto]   3. Wrong nonce or ciphertext');
      throw Exception('Message authentication failed - possible key mismatch');
    } catch (e) {
      print('[Crypto] Decryption failed: $e');
      throw Exception('Failed to decrypt message: $e');
    }
  }
  
  /// Optional: Ratchet session key forward for forward secrecy
  /// Call this after sending/receiving a message
  Future<void> ratchetSessionKey(String chatWith) async {
    final currentKey = _sessionKeys[chatWith];
    if (currentKey == null) {
      print('[Crypto] Warning: No session key to ratchet for: $chatWith');
      return;
    }
    
    try {
      // Extract current key bytes
      final currentKeyBytes = await currentKey.extractBytes();
      
      // Derive new key using current key as input
      final counter = _messageCounters[chatWith] ?? 0;
      final newKeyBytes = _hkdf(
        currentKeyBytes,
        info: utf8.encode('ratchet_${chatWith}_$counter'),
        length: 32,
      );
      
      _sessionKeys[chatWith] = SecretKey(newKeyBytes);
      print('[Crypto] Ratcheted session key for: $chatWith');
    } catch (e) {
      print('[Crypto] Error ratcheting key: $e');
      // Don't rethrow - ratcheting failure shouldn't break communication
    }
  }
  
  /// HKDF implementation using SHA-256
  List<int> _hkdf(List<int> inputKeyMaterial, {required List<int> info, int length = 32}) {
    // Extract step (using empty salt)
    final prk = crypto.Hmac(crypto.sha256, []).convert(inputKeyMaterial).bytes;
    
    // Expand step
    final result = <int>[];
    var t = <int>[];
    var counter = 1;
    
    while (result.length < length) {
      final hmac = crypto.Hmac(crypto.sha256, prk);
      final data = [...t, ...info, counter];
      t = hmac.convert(data).bytes;
      result.addAll(t);
      counter++;
    }
    
    return result.sublist(0, length);
  }
  
  /// Clear all session keys (e.g., on logout)
  void clearSessionKeys() {
    _sessionKeys.clear();
    _messageCounters.clear();
    print('[Crypto] All session keys cleared');
  }
  
  /// Clear everything including identity keys
  Future<void> clearAll(String username) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('identity_private_key_$username');
      await prefs.remove('identity_public_key_$username');
      
      _identityKeyPair = null;
      _sessionKeys.clear();
      _publicKeys.clear();
      _messageCounters.clear();
      _currentUsername = null;
      
      print('[Crypto] All crypto data cleared');
    } catch (e) {
      print('[Crypto] Error clearing data: $e');
    }
  }
  
  /// Check if session key exists
  bool hasSessionKey(String chatWith) {
    return _sessionKeys.containsKey(chatWith);
  }
  
  /// Get session key status for debugging
  Map<String, bool> getSessionKeyStatus() {
    return {
      for (var key in _sessionKeys.keys)
        key: _sessionKeys[key] != null,
    };
  }
}
