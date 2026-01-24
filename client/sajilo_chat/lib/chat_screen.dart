import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:open_file/open_file.dart';
import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_history_handler.dart'; // NEW: History handler
import 'message_bubble.dart';
import 'file_transfer_handler.dart';

class ChatScreen extends StatefulWidget {
  final SocketWrapper socket;
  final String username;
  final String chatWith;
  final ChatHistoryHandler historyHandler; // NEW: History handler parameter

  const ChatScreen({
    super.key,
    required this.socket,
    required this.username,
    required this.chatWith,
    required this.historyHandler, // NEW: Required parameter
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
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
  
  // NEW: History loading state
  bool _historyLoaded = false;

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
              action: SnackBarAction(
                label: 'OPEN',
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
          SnackBar(content: Text('File transfer error: $error')),
        );
      },
    );
    
    _setupListener();
    _requestHistory(); // NEW: Request history on init
  }

  // NEW: Request chat history
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
            // NEW: History handling
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
              // NEW: Add to history cache
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
                // NEW: Add to history cache
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

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 100), () {
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
        ),
      );
    }
  }
  
  Future<void> _pickAndSendFile() async {
    if (widget.chatWith == 'group') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File sharing only available in direct messages')),
      );
      return;
    }
    
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles();
      
      if (result != null) {
        final file = File(result.files.single.path!);
        final fileSize = await file.length();
        final fileName = result.files.single.name;
        
        if (fileSize > 50 * 1024 * 1024) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('File too large (max 50MB)')),
          );
          return;
        }
        
        if (!mounted) return;
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Send File?'),
            content: Text(
              'Send "$fileName" (${(fileSize / 1024).toStringAsFixed(1)} KB) to ${widget.chatWith}?\n\n'
              'Note: Recipient must be online.'
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Send'),
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF075E54),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.white,
              child: widget.chatWith == 'group'
                  ? const Icon(Icons.group, color: Color(0xFF075E54))
                  : Text(
                      widget.chatWith[0].toUpperCase(),
                      style: const TextStyle(color: Color(0xFF075E54)),
                    ),
            ),
            const SizedBox(width: 12),
            Text(
              widget.chatWith == 'group' ? 'Group Chat' : widget.chatWith,
              style: const TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
      body: Container(
        color: const Color(0xFFECE5DD),
        child: Column(
          children: [
            // NEW: History loading indicator
            if (!_historyLoaded)
              Container(
                padding: const EdgeInsets.all(8),
                color: Colors.amber[100],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: const [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('Loading history...', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            
            // File transfer progress
            if (_showFileProgress)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.blue[50],
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Icon(Icons.file_upload, size: 20, color: Colors.blue),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _transferFileName,
                            style: const TextStyle(fontSize: 14),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '${(_fileTransferProgress * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: _fileTransferProgress),
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
                            Icons.chat_bubble_outline,
                            size: 80,
                            color: Colors.grey[400],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[600],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Start the conversation!',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey[400],
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.all(8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        return MessageBubble(
                          message: msg['message'],
                          isMe: msg['isMe'],
                          sender: msg['from'],
                          showSender: widget.chatWith == 'group' && !msg['isMe'],
                          isFile: msg['isFile'] ?? false,
                          fileName: msg['fileName'],
                          filePath: msg['filePath'],
                          onFileTap: msg['isFile'] == true && 
                                     msg['filePath'] != null && 
                                     msg['filePath'].toString().isNotEmpty
                              ? () => _openFile(msg['filePath'])
                              : null,
                        );
                      },
                    ),
            ),
            
            // Input bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: Colors.white,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file, color: Color(0xFF075E54)),
                    onPressed: _pickAndSendFile,
                    tooltip: 'Send file',
                  ),
                  
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  
                  const SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: const Color(0xFF25D366),
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 20),
                      onPressed: _sendMessage,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}