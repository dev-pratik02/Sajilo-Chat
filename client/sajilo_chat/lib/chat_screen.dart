import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_history_handler.dart';
import 'message_bubble.dart';
import 'file_transfer_handler.dart';

class ChatScreen extends StatefulWidget {
  final SocketWrapper socket;
  final String username;
  final String chatWith;
  final ChatHistoryHandler historyHandler;

  const ChatScreen({
    super.key,
    required this.socket,
    required this.username,
    required this.chatWith,
    required this.historyHandler,
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
  
  //    NEW: Typing indicator state
  bool _otherUserTyping = false;
  Timer? _typingTimer;
  Timer? _typingDebouncer;

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
    _requestHistory();
  }

  void _requestHistory() {
    print('[ChatScreen] Requesting history for ${widget.chatWith}');
    widget.historyHandler.requestHistory(widget.chatWith);
  }

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
            //    Typing indicator
            else if (type == 'typing') {
              final from = jsonData['from'];
              if (from == widget.chatWith || (widget.chatWith == 'group' && from != widget.username)) {
                _handleTypingIndicator();
              }
            }
            // History handling
            else if (type == 'history') {
              final historyMessages = widget.historyHandler.processHistoryData(jsonData);
              setState(() {
                _historyLoaded = true;
                _messages.clear();
                _messages.addAll(historyMessages);
              });
              _scrollToBottom();
              print('[ChatScreen] Loaded ${historyMessages.length} messages from history');
            }
            // Group message handling
            else if (type == 'group' && widget.chatWith == 'group') {
              final newMessage = {
                'from': jsonData['from'],
                'message': jsonData['message'],
                'isMe': jsonData['from'] == widget.username,
              };
              setState(() {
                _messages.add(newMessage);
              });
              widget.historyHandler.addMessageToCache('group', newMessage);
              _scrollToBottom();
            } 
            // Direct message handling
            else if (type == 'dm') {
              final from = jsonData['from'];
              final to = jsonData['to'];

              if ((from == widget.username && to == widget.chatWith) ||
                  (from == widget.chatWith)) {
                final newMessage = {
                  'from': from,
                  'message': jsonData['message'],
                  'isMe': from == widget.username,
                };
                setState(() {
                  _messages.add(newMessage);
                });
                widget.historyHandler.addMessageToCache(widget.chatWith, newMessage);
                _scrollToBottom();
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

  //    NEW: Handle typing indicator
  void _handleTypingIndicator() {
    setState(() => _otherUserTyping = true);
    _typingTimer?.cancel();
    _typingTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _otherUserTyping = false);
      }
    });
  }

  //    NEW: Send typing indicator
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

  void _sendMessage() {
    if (_messageController.text.trim().isEmpty) return;

    final messageData = widget.chatWith == 'group'
        ? {
            'type': 'group',
            'message': _messageController.text,
          }
        : {
            'type': 'dm',
            'to': widget.chatWith,
            'message': _messageController.text,
          };

    final msg = '${jsonEncode(messageData)}\n';
    widget.socket.write(utf8.encode(msg));
    _messageController.clear();
  }
  
  Future<void> _openFile(String filePath) async {
    try {
      print('[OPEN_FILE] Attempting to open: $filePath');
      final result = await OpenFile.open(filePath);
      
      if (result.type != ResultType.done) {
        print('[OPEN_FILE] Error: ${result.message}');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open file: ${result.message}'),
            backgroundColor: Colors.orange,
            behavior: SnackBarBehavior.floating,
          ),
        );
      } else {
        print('[OPEN_FILE] ✓ File opened successfully');
      }
    } catch (e) {
      print('[OPEN_FILE] Exception: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error opening file: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _pickAndSendFile() async {
    try {
      final result = await FilePicker.platform.pickFiles();
      
      if (result != null && result.files.isNotEmpty) {
        final platformFile = result.files.first;
        final filePath = platformFile.path;
        
        if (filePath == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not access file')),
          );
          return;
        }
        
        final file = File(filePath);
        final fileSize = await file.length();
        final fileName = platformFile.name;
        
        const maxSize = 50 * 1024 * 1024; // 50 MB
        if (fileSize > maxSize) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('File too large. Maximum size: 50 MB'),
              backgroundColor: Colors.red,
            ),
          );
          return;
        }
        
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('Send File?', style: GoogleFonts.poppins(fontWeight: FontWeight.w600)),
            content: Text(
              'Send "$fileName" (${(fileSize / 1024).toStringAsFixed(1)} KB) to ${widget.chatWith}?\n\n'
              'Note: Recipient must be online.',
              style: GoogleFonts.poppins(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('Cancel', style: GoogleFonts.poppins(color: Colors.grey)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text('Send', style: GoogleFonts.poppins(color: Color(0xFF6C63FF), fontWeight: FontWeight.w600)),
              ),
            ],
          ),
        );
        
        if (confirmed == true) {
          setState(() {
            _transferFileName = fileName;
            _showFileProgress = true;
            _fileTransferProgress = 0.0;
          });
          
          await _fileHandler.sendFile(
            file: file,
            socket: widget.socket.socket,
            senderUsername: widget.username,
            recipientUsername: widget.chatWith,
          );
        }
      }
    } catch (e) {
      print('[FILE_PICKER] Error: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error picking file: $e')),
      );
    }
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    _fileHandler.dispose();
    _typingTimer?.cancel();
    _typingDebouncer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    //    Distinct colors for Group vs DM
    final bool isGroup = widget.chatWith == 'group';
    final Color primaryColor = isGroup ? Color(0xFF6C63FF) : Color(0xFF8B7FFF);
    final Color accentColor = isGroup ? Color(0xFF5A52D5) : Color(0xFF9D8FFF);
    
    return Scaffold(
      backgroundColor: Color(0xFFF5F5FA),
      appBar: AppBar(
        backgroundColor: primaryColor,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            //    Animated avatar
            Hero(
              tag: 'avatar_${widget.chatWith}',
              child: CircleAvatar(
                radius: 20,
                backgroundColor: Colors.white,
                child: widget.chatWith == 'group'
                    ? Icon(Icons.group, color: primaryColor, size: 24)
                    : Text(
                        widget.chatWith[0].toUpperCase(),
                        style: GoogleFonts.poppins(
                          color: primaryColor,
                          fontWeight: FontWeight.bold,
                          fontSize: 18,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.chatWith == 'group' ? 'Group Chat' : widget.chatWith,
                    style: GoogleFonts.poppins(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  //    Typing indicator in appbar
                  if (_otherUserTyping)
                    Text(
                      'typing...',
                      style: GoogleFonts.poppins(
                        color: Colors.white70,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
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
          // History loading indicator
          if (!_historyLoaded)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: accentColor.withOpacity(0.1),
                border: Border(
                  bottom: BorderSide(color: accentColor.withOpacity(0.2)),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(primaryColor),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Loading history...',
                    style: GoogleFonts.poppins(fontSize: 13, color: primaryColor),
                  ),
                ],
              ),
            ),
          
          // File transfer progress
          if (_showFileProgress)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: primaryColor.withOpacity(0.1),
                    blurRadius: 10,
                    offset: Offset(0, 4),
                  ),
                ],
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      Icon(Icons.file_upload_outlined, size: 24, color: primaryColor),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _transferFileName,
                              style: GoogleFonts.poppins(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Sending file...',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.grey[600],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${(_fileTransferProgress * 100).toStringAsFixed(0)}%',
                        style: GoogleFonts.poppins(
                          fontWeight: FontWeight.bold,
                          color: primaryColor,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
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
                          isGroup ? Icons.group_outlined : Icons.chat_bubble_outline,
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
                          isGroup ? 'Start the group conversation!' : 'Say hello!',
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
                      //    Show typing indicator at end
                      if (_otherUserTyping && index == _messages.length) {
                        return _buildTypingIndicator(primaryColor);
                      }
                      
                      final msg = _messages[index];
                      //    Fade-in animation
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
                    onPressed: _pickAndSendFile,
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
                          hintText: 'Type a message',
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

  //    Typing indicator widget
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