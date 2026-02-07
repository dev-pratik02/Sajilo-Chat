import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_history_handler.dart';
import 'package:sajilo_chat/crypto_manager.dart';
import 'message_bubble.dart';
import 'file_transfer_handler.dart';

class ChatScreen extends StatefulWidget {
  final SocketWrapper socket;
  final String username;
  final String chatWith;
  final ChatHistoryHandler historyHandler;
  final CryptoManager cryptoManager;  // NEW: Crypto manager
  final String serverHost;

  const ChatScreen({
    super.key,
    required this.socket,
    required this.username,
    required this.chatWith,
    required this.historyHandler,
    required this.cryptoManager,
    required this.serverHost,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with TickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<Map<String, dynamic>> _messages = [];
  StreamSubscription? _socketSubscription;
  String _buffer = '';
  
  // File transfer state
  late FileTransferHandler _fileHandler;
  double _fileTransferProgress = 0.0;
  bool _showFileProgress = false;
  String _transferFileName = '';
  
  // History loading state
  bool _historyLoaded = false;
  
  // Typing indicator state
  bool _otherUserTyping = false;
  Timer? _typingTimer;
  Timer? _typingDebouncer;
  
  // E2EE state
  bool _encryptionReady = false;
  bool _fetchingKeys = false;

  @override
  void initState() {
    super.initState();
    
    // Initialize file transfer handler
    _fileHandler = FileTransferHandler(
      onProgress: (progress) {
        setState(() {
          _fileTransferProgress = progress;
          _showFileProgress = true;
        });
      },
      onComplete: (fileName, filePath) {
        setState(() {
          _showFileProgress = false;
          _messages.add({
            'from': 'System',
            'message': 'File received: $fileName',
            'isMe': false,
            'isFile': true,
            'fileName': fileName,
            'filePath': filePath,
          });
        });
        _scrollToBottom();
        
        if (filePath.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File saved: $fileName'),
              backgroundColor: Color(0xFF6C63FF),
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'OPEN',
                textColor: Colors.white,
                onPressed: () => _openFile(filePath),
              ),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      },
      onError: (error) {
        setState(() => _showFileProgress = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File transfer error: $error'),
            backgroundColor: Colors.red,
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
    );
    
    _setupListener();
    _initializeEncryption();
  }
  
  /// E2EE: Initialize encryption for this chat
  Future<void> _initializeEncryption() async {
    if (widget.chatWith == 'group') {
      // Group chat encryption not implemented in this version
      // You could use a shared group key or pairwise encryption
      setState(() => _encryptionReady = true);
      _loadHistoryWithCache();
      return;
    }
    
    setState(() => _fetchingKeys = true);
    
    try {
      print('[E2EE] Initializing encryption for chat with ${widget.chatWith}');
      
      // Check if we already have a session key
      if (widget.cryptoManager.hasSessionKey(widget.chatWith)) {
        print('[E2EE] Session key already exists');
        setState(() {
          _encryptionReady = true;
          _fetchingKeys = false;
        });
        _loadHistoryWithCache();
        return;
      }
      
      // Fetch the other user's public key from server
      print('[E2EE] Fetching public key for ${widget.chatWith}');
      final response = await http.get(
        Uri.parse('http://${widget.serverHost}:5001/api/keys/get/${widget.chatWith}'),
      ).timeout(Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final publicKey = data['public_key'];
        
        // Store the public key
        widget.cryptoManager.storePublicKey(widget.chatWith, publicKey);
        print('[E2EE] Public key stored for ${widget.chatWith}');
        
        // Derive session key
        await widget.cryptoManager.deriveSessionKey(widget.chatWith);
        print('[E2EE] Session key derived');
        
        setState(() {
          _encryptionReady = true;
          _fetchingKeys = false;
        });
        
        // Request history after encryption is ready
        _loadHistoryWithCache();
        
        // Show encryption ready notification
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.lock, color: Colors.white, size: 20),
                SizedBox(width: 12),
                Text('End-to-end encryption enabled 🔐', 
                     style: GoogleFonts.poppins(fontSize: 13)),
              ],
            ),
            backgroundColor: Color(0xFF26DE81),
            behavior: SnackBarBehavior.floating,
            duration: Duration(seconds: 2),
          ),
        );
      } else {
        throw Exception('Failed to fetch public key');
      }
      
    } catch (e) {
      print('[E2EE] Error initializing encryption: $e');
      setState(() => _fetchingKeys = false);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Warning: Could not establish encryption. Try again later.'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
      
      // Still allow chat but without encryption
      setState(() => _encryptionReady = false);
      _loadHistoryWithCache();
    }
  }
    
  void _loadHistoryWithCache() {
        print('[ChatScreen] Loading history for ${widget.chatWith}');
        
        // First, check if we have cached history
        final cachedHistory = widget.historyHandler.getCachedHistory(widget.chatWith);
        
        if (cachedHistory != null && cachedHistory.isNotEmpty) {
          print('[ChatScreen] Found ${cachedHistory.length} messages in cache');
          setState(() {
            _messages.clear();
            _messages.addAll(cachedHistory);
            _historyLoaded = true;
          });
          _scrollToBottom();
        }
        
        // Request fresh history from server (will update if there are new messages)
        _requestHistory();
    }

  void _requestHistory() {
    print('[ChatScreen] Requesting history from server for ${widget.chatWith}');
    widget.historyHandler.requestHistory(widget.chatWith);  }

  void _setupListener() {
    _socketSubscription = widget.socket.stream.listen(
      (data) {
        // CRITICAL: Check if in file transfer mode
        if (_fileHandler.isReceivingFile) {
          _fileHandler.handleIncomingChunk(data);
          return;
        }
        
        // Normal JSON message handling
        _buffer += utf8.decode(data);
        
        while (_buffer.contains('\n')) {
          final index = _buffer.indexOf('\n');
          final message = _buffer.substring(0, index);
          _buffer = _buffer.substring(index + 1);
          
          if (message.trim().isEmpty) continue;
          
          try {
            final jsonData = jsonDecode(message);
            final type = jsonData['type'];

            // File transfer handling
            if (type == 'file_transfer_start') {
              setState(() => _transferFileName = jsonData['file_name']);
              _fileHandler.handleTransferStart(jsonData);
            } 
            else if (type == 'file_transfer_end') {
              _fileHandler.handleTransferEnd(jsonData);
            }
            // Typing indicator
            else if (type == 'typing') {
              final from = jsonData['from'];
              if (from == widget.chatWith || (widget.chatWith == 'group' && from != widget.username)) {
                _handleTypingIndicator();
              }
            }
            // History handling - ENCRYPTED
            else if (type == 'history') {
              _handleEncryptedHistory(jsonData);
            }
            // Group message handling
            else if (type == 'group' && widget.chatWith == 'group') {
              _handleIncomingGroupMessage(jsonData);
            } 
            // Direct message handling - ENCRYPTED
            else if (type == 'dm') {
              final from = jsonData['from'];
              final to = jsonData['to'];

              if ((from == widget.username && to == widget.chatWith) ||
                  (from == widget.chatWith)) {
                _handleIncomingDM(jsonData);
              }
            }
          } catch (e) {
            print('[ChatScreen] Parse error: $e');
          }
        }
      },
      cancelOnError: false,
    );
  }
  
  /// E2EE: Handle encrypted history
  Future<void> _handleEncryptedHistory(Map<String, dynamic> jsonData) async {
    try {
      final messages = jsonData['messages'] as List;
      final decryptedMessages = <Map<String, dynamic>>[];
      
      for (var msg in messages) {
        try {
          String displayMessage;
          final msgType = msg['type'] ?? 'dm';
          
          // ✅ FIX: Handle group messages specially
          if (msgType == 'group' || widget.chatWith == 'group') {
            // For group messages, the plaintext is stored in 'ciphertext' field
            // (because database schema uses that field)
            displayMessage = msg['ciphertext'] ?? msg['message'] ?? '[No message]';
            print('[ChatScreen] Group history message: $displayMessage');
          }
          // Check if message has encrypted_data (for DMs)
          else if (msg.containsKey('ciphertext') && _encryptionReady) {
            // Decrypt the message
            final encryptedData = {
              'ciphertext': msg['ciphertext'],
              'nonce': msg['nonce'],
              'mac': msg['mac'],
            };
            
            displayMessage = await widget.cryptoManager.decryptMessage(
              widget.chatWith,
              encryptedData,
            );
          } else {
            // Fallback for unencrypted messages
            displayMessage = msg['message'] ?? msg['ciphertext'] ?? '[Unable to decrypt]';
          }
          
          decryptedMessages.add({
            'from': msg['from'],
            'message': displayMessage,
            'isMe': msg['from'] == widget.username,
            'timestamp': msg['timestamp'],
            'type': msgType,
          });
        } catch (e) {
          print('[E2EE] Failed to decrypt history message: $e');
          // Add placeholder for failed decryption
          decryptedMessages.add({
            'from': msg['from'],
            'message': '[Decryption failed]',
            'isMe': msg['from'] == widget.username,
            'timestamp': msg['timestamp'],
            'type': msg['type'],
          });
        }
      }
      
      setState(() {
        _historyLoaded = true;
        _messages.clear();
        _messages.addAll(decryptedMessages);
      });
      _scrollToBottom();
      print('[ChatScreen] Loaded ${decryptedMessages.length} messages from history');
      widget.historyHandler.clearCache(widget.chatWith);
      for (var msg in decryptedMessages) {
        widget.historyHandler.addMessageToCache(widget.chatWith, msg);
      }
      
    } catch (e) {
      print('[E2EE] Error handling encrypted history: $e');
    }
  }
  
  /// E2EE: Handle incoming encrypted DM
  Future<void> _handleIncomingDM(Map<String, dynamic> jsonData) async {
    try {
      final from = jsonData['from'];
      String displayMessage;
      
      // Check if message is encrypted
      if (jsonData.containsKey('encrypted_data') && _encryptionReady) {
        final encryptedData = jsonData['encrypted_data'];
        displayMessage = await widget.cryptoManager.decryptMessage(
          widget.chatWith,
          encryptedData,
        );
      } else {
        // Fallback for unencrypted messages
        displayMessage = jsonData['message'] ?? '[No message]';
      }
      
      final newMessage = {
        'from': from,
        'message': displayMessage,
        'isMe': from == widget.username,
      };
      
      setState(() {
        _messages.add(newMessage);
      });
      widget.historyHandler.addMessageToCache(widget.chatWith, newMessage);
      _scrollToBottom();
      
    } catch (e) {
      print('[E2EE] Error handling incoming DM: $e');
      
      final newMessage = {
        'from': jsonData['from'],
        'message': '[Decryption failed - key mismatch?]',
        'isMe': jsonData['from'] == widget.username,
      };
      
      setState(() {
        _messages.add(newMessage);
      });
      _scrollToBottom();
    }
  }
  
  /// Handle incoming group message (not encrypted in this implementation)
  void _handleIncomingGroupMessage(Map<String, dynamic> jsonData) {
    final newMessage = {
      'from': jsonData['from'],
      'message': jsonData['message'],
      'isMe': jsonData['from'] == widget.username,
    };
    
    print('[ChatScreen] Group message from ${jsonData['from']}: ${jsonData['message']}');
    
    setState(() {
      _messages.add(newMessage);
    });
    widget.historyHandler.addMessageToCache('group', newMessage);
    _scrollToBottom();
  }

  // Handle typing indicator
  void _handleTypingIndicator() {
    setState(() => _otherUserTyping = true);
    _typingTimer?.cancel();
    _typingTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _otherUserTyping = false);
      }
    });
  }

  // Send typing indicator
  void _sendTypingIndicator() {
    _typingDebouncer?.cancel();
    _typingDebouncer = Timer(Duration(milliseconds: 500), () {
      final typingData = widget.chatWith == 'group'
          ? {'type': 'typing', 'from': widget.username, 'to': 'group'}
          : {'type': 'typing', 'from': widget.username, 'to': widget.chatWith};
      
      final msg = '${jsonEncode(typingData)}\n';
      widget.socket.write(utf8.encode(msg));
    });
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 150), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// ✅ FIXED: Send message with immediate UI update for group chat
  Future<void> _sendMessage() async {
    if (_messageController.text.trim().isEmpty) return;

    final plaintext = _messageController.text.trim();
    _messageController.clear();

    try {
      if (widget.chatWith == 'group') {
        // ✅ FIX: Add message to UI immediately for sender
        final localMessage = {
          'from': widget.username,
          'message': plaintext,
          'isMe': true,
          'timestamp': DateTime.now().toIso8601String(),
        };
        
        setState(() {
          _messages.add(localMessage);
        });
        widget.historyHandler.addMessageToCache('group', localMessage);
        _scrollToBottom();
        
        // Then send to server
        final groupData = {
          'type': 'group',
          'from': widget.username,
          'message': plaintext,
          'timestamp': DateTime.now().toIso8601String(),
        };
        
        final msg = '${jsonEncode(groupData)}\n';
        widget.socket.write(utf8.encode(msg));
        
        print('[ChatScreen] Sent group message: $plaintext');
        
      } else {
        // DM - encrypt the message
        if (!_encryptionReady) {
          throw Exception('Encryption not ready. Please wait...');
        }
        
        // Encrypt the message
        final encryptedData = await widget.cryptoManager.encryptMessage(
          widget.chatWith,
          plaintext,
        );
        
        // Send encrypted message
        final dmData = {
          'type': 'dm',
          'from': widget.username,
          'to': widget.chatWith,
          'message': '[Encrypted]',  // Placeholder text
          'encrypted_data': encryptedData,
          'timestamp': DateTime.now().toIso8601String(),
        };
        
        final msg = '${jsonEncode(dmData)}\n';
        widget.socket.write(utf8.encode(msg));
        
        // Optional: Ratchet session key for forward secrecy
        // Uncomment to enable key ratcheting after each message
        // await widget.cryptoManager.ratchetSessionKey(widget.chatWith);
      }
      
    } catch (e) {
      print('[E2EE] Error sending message: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send message: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      
      if (result == null || result.files.isEmpty) {
        return;
      }
      
      final file = File(result.files.single.path!);
      final fileName = result.files.single.name;
      final fileSize = await file.length();
      
      // Check file size (limit to 50MB)
      if (fileSize > 50 * 1024 * 1024) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File too large. Maximum size is 50MB.'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      
      if (widget.chatWith == 'group') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('File sharing in group chat not supported yet'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      
      setState(() {
        _showFileProgress = true;
        _transferFileName = fileName;
        _fileTransferProgress = 0.0;
      });
      
      await _fileHandler.sendFile(
        file: file,
        socket: widget.socket.socket,
        senderUsername: widget.username,
        recipientUsername: widget.chatWith,
      );
      
      setState(() {
        _messages.add({
          'from': widget.username,
          'message': 'Sent: $fileName',
          'isMe': true,
          'isFile': true,
          'fileName': fileName,
          'filePath': '',
        });
      });
      _scrollToBottom();
      
    } catch (e) {
      print('[FILE] Error picking/sending file: $e');
      setState(() => _showFileProgress = false);
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send file: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openFile(String filePath) async {
    try {
      final result = await OpenFile.open(filePath);
      if (result.type != ResultType.done) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file: ${result.message}'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      print('[FILE] Error opening file: $e');
    }
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _socketSubscription?.cancel();
    _typingTimer?.cancel();
    _typingDebouncer?.cancel();
    _fileHandler.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isGroup = widget.chatWith == 'group';
    final Color primaryColor = Color(0xFF6C63FF);
    final Color accentColor = Color(0xFF8B7FFF);
    
    return Scaffold(
      backgroundColor: Color(0xFFF8F9FA),
      appBar: AppBar(
        elevation: 0,
        backgroundColor: Colors.white,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_rounded, color: primaryColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            Hero(
              tag: 'avatar_${isGroup ? "group" : widget.chatWith}',
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [primaryColor, accentColor],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                ),
                child: CircleAvatar(
                  radius: 20,
                  backgroundColor: Colors.transparent,
                  child: isGroup
                      ? Icon(Icons.group_rounded, color: Colors.white, size: 24)
                      : Text(
                          widget.chatWith[0].toUpperCase(),
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isGroup ? 'Group Chat' : widget.chatWith,
                    style: GoogleFonts.poppins(
                      color: Colors.black87,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (!isGroup && _encryptionReady)
                    Row(
                      children: [
                        Icon(Icons.lock, size: 12, color: Color(0xFF26DE81)),
                        SizedBox(width: 4),
                        Text(
                          'End-to-end encrypted',
                          style: GoogleFonts.poppins(
                            color: Color(0xFF26DE81),
                            fontSize: 11,
                          ),
                        ),
                      ],
                    )
                  else if (isGroup)
                    Text(
                      'Everyone can see messages',
                      style: GoogleFonts.poppins(
                        color: Colors.grey[600],
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          // File transfer progress indicator
          if (_showFileProgress)
            Container(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: Color(0xFFF0EFFF),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(primaryColor),
                        ),
                      ),
                      SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Transferring: $_transferFileName',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${(_fileTransferProgress * 100).toInt()}%',
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: primaryColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _fileTransferProgress,
                      backgroundColor: Colors.grey[200],
                      valueColor: AlwaysStoppedAnimation(primaryColor),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),
          
          // Messages list
          Expanded(
            child: _messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          isGroup ? Icons.group_outlined : Icons.lock_outline,
                          size: 80,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          'No messages yet',
                          style: GoogleFonts.poppins(
                            fontSize: 20,
                            color: Colors.grey[500],
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isGroup ? 'Start the group conversation!' : 
                          (_encryptionReady ? 'Your messages are encrypted 🔐' : 'Say hello!'),
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            color: Colors.grey[400],
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    itemCount: _messages.length + (_otherUserTyping ? 1 : 0),
                    itemBuilder: (context, index) {
                      // Show typing indicator at end
                      if (_otherUserTyping && index == _messages.length) {
                        return _buildTypingIndicator(primaryColor);
                      }
                      
                      final msg = _messages[index];
                      // Fade-in animation
                      return TweenAnimationBuilder<double>(
                        duration: Duration(milliseconds: 300),
                        tween: Tween(begin: 0.0, end: 1.0),
                        builder: (context, value, child) {
                          return Opacity(
                            opacity: value,
                            child: Transform.translate(
                              offset: Offset(0, 20 * (1 - value)),
                              child: child,
                            ),
                          );
                        },
                        child: MessageBubble(
                          message: msg['message'],
                          isMe: msg['isMe'],
                          sender: msg['from'],
                          showSender: widget.chatWith == 'group' && !msg['isMe'],
                          isFile: msg['isFile'] ?? false,
                          fileName: msg['fileName'],
                          filePath: msg['filePath'],
                          isGroupChat: isGroup,
                          bubbleColor: primaryColor,
                          onFileTap: msg['isFile'] == true && 
                                     msg['filePath'] != null && 
                                     msg['filePath'].toString().isNotEmpty
                              ? () => _openFile(msg['filePath'])
                              : null,
                        ),
                      );
                    },
                  ),
          ),
          
          // Input bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 10,
                  offset: Offset(0, -4),
                ),
              ],
            ),
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.attach_file_rounded, color: primaryColor),
                    onPressed: !isGroup ? _pickAndSendFile : null,
                    tooltip: 'Send file',
                  ),
                  
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: Color(0xFFF5F5FA),
                        borderRadius: BorderRadius.circular(25),
                      ),
                      child: TextField(
                        controller: _messageController,
                        style: GoogleFonts.poppins(),
                        decoration: InputDecoration(
                          hintText: _encryptionReady && !isGroup 
                              ? 'Type an encrypted message...' 
                              : 'Type a message...',
                          hintStyle: GoogleFonts.poppins(color: Colors.grey[400]),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 12,
                          ),
                        ),
                        onChanged: (text) {
                          if (text.isNotEmpty) {
                            _sendTypingIndicator();
                          }
                        },
                        onSubmitted: (_) => _sendMessage(),
                      ),
                    ),
                  ),
                  
                  const SizedBox(width: 8),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [primaryColor, accentColor],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: primaryColor.withOpacity(0.3),
                          blurRadius: 8,
                          offset: Offset(0, 4),
                        ),
                      ],
                    ),
                    child: IconButton(
                      icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Typing indicator widget
  Widget _buildTypingIndicator(Color color) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 8, top: 4),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 5,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDot(color, 0),
                SizedBox(width: 4),
                _buildDot(color, 150),
                SizedBox(width: 4),
                _buildDot(color, 300),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDot(Color color, int delay) {
    return TweenAnimationBuilder<double>(
      duration: Duration(milliseconds: 600),
      tween: Tween(begin: 0.0, end: 1.0),
      builder: (context, value, child) {
        return Transform.translate(
          offset: Offset(0, -4 * (0.5 - (value - 0.5).abs())),
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color.withOpacity(0.6 + 0.4 * value),
              shape: BoxShape.circle,
            ),
          ),
        );
      },
      onEnd: () {
        if (mounted && _otherUserTyping) {
          setState(() {}); // Restart animation
        }
      },
    );
  }
}
