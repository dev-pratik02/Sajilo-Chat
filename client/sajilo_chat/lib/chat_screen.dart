import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'package:sajilo_chat/utilities.dart';
import 'message_bubble.dart';

class ChatScreen extends StatefulWidget {
  final SocketWrapper socket;
  final String username;
  final String chatWith;

  const ChatScreen({
    super.key,
    required this.socket,
    required this.username,
    required this.chatWith,
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

  @override
  void initState() {
    super.initState();
    _setupListener();
  }

  void _setupListener() {
    _socketSubscription = widget.socket.stream.listen(
      (data) {
        _buffer += utf8.decode(data);
        
        while (_buffer.contains('\n')) {
          final index = _buffer.indexOf('\n');
          final message = _buffer.substring(0, index);
          _buffer = _buffer.substring(index + 1);
          
          if (message.trim().isEmpty) continue;
          
          try {
            final jsonData = jsonDecode(message);
            final type = jsonData['type'];

            if (type == 'group' && widget.chatWith == 'group') {
              setState(() {
                _messages.add({
                  'from': jsonData['from'],
                  'message': jsonData['message'],
                  'isMe': jsonData['from'] == widget.username,
                });
              });
              _scrollToBottom();
              
            } else if (type == 'dm') {
              final from = jsonData['from'];
              final to = jsonData['to'];

              if ((from == widget.username && to == widget.chatWith) ||
                  (from == widget.chatWith)) {
                setState(() {
                  _messages.add({
                    'from': from,
                    'message': jsonData['message'],
                    'isMe': from == widget.username,
                  });
                });
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
    Future.delayed(Duration(milliseconds: 100), () {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
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

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Color(0xFF075E54),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: Colors.white,
              child: widget.chatWith == 'group'
                  ? Icon(Icons.group, color: Color(0xFF075E54))
                  : Text(
                      widget.chatWith[0].toUpperCase(),
                      style: TextStyle(color: Color(0xFF075E54)),
                    ),
            ),
            SizedBox(width: 12),
            Text(
              widget.chatWith == 'group' ? 'Group Chat' : widget.chatWith,
              style: TextStyle(color: Colors.white),
            ),
          ],
        ),
      ),
      body: Container(
        color: Color(0xFFECE5DD),
        child: Column(
          children: [
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
                          SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey[600],
                            ),
                          ),
                          SizedBox(height: 8),
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
                      padding: EdgeInsets.all(8),
                      itemCount: _messages.length,
                      itemBuilder: (context, index) {
                        final msg = _messages[index];
                        return MessageBubble(
                          message: msg['message'],
                          isMe: msg['isMe'],
                          sender: msg['from'],
                          showSender: widget.chatWith == 'group' && !msg['isMe'],
                        );
                      },
                    ),
            ),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: InputDecoration(
                        hintText: 'Type a message',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(25),
                        ),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  SizedBox(width: 8),
                  CircleAvatar(
                    backgroundColor: Color(0xFF25D366),
                    child: IconButton(
                      icon: Icon(Icons.send, color: Colors.white, size: 20),
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
