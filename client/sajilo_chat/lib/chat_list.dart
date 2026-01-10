import "package:flutter/material.dart";
import 'package:sajilo_chat/login_page.dart';
import 'dart:convert';
import 'dart:async';
import 'package:sajilo_chat/utilities.dart';
import 'chat_screen.dart';

// ============================================================================
// CHAT LIST PAGE
// ============================================================================
class ChatsListPage extends StatefulWidget {
  final SocketWrapper socket;
  final String username;

  const ChatsListPage({
    super.key,
    required this.socket,
    required this.username,
  });

  @override
  State<ChatsListPage> createState() => _ChatsListPageState();
}

class _ChatsListPageState extends State<ChatsListPage> {
  StreamSubscription? _socketSubscription;
  List<String> _onlineUsers = [];
  final Map<String, int> _unreadCounts = {'group': 0};
  final Map<String, String> _lastMessages = {'group': 'No messages yet'};
  bool _isConnected = true;
  String _buffer = '';

  @override
void initState() {
  super.initState();
  _setupSocketListener();
  
  // FIX: Request users after a brief delay to ensure the listener is active
  Future.delayed(Duration(milliseconds: 500), () {
    print('[ChatList] Requesting user list...');
    
        final request = '${jsonEncode({
       'type': 'request_users',
  '     message': 'Requesting list'
        })}\n';

  widget.socket.write(utf8.encode(request));
    
  });
}
  void _setupSocketListener() {
    print('[ChatList] Setting up listener');
    
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

            if (type == 'request_username') {
              final response = '${jsonEncode({'username': widget.username})}\n';
              widget.socket.write(utf8.encode(response));
              
            } else if (type == 'user_list') {
              setState(() {
                _onlineUsers = List<String>.from(jsonData['users'])
                  ..remove(widget.username);
              });
              
            } else if (type == 'group') {
              final from = jsonData['from'];
              final msg = jsonData['message'];

              


              setState(() {
                _lastMessages['group'] = '$from: $msg';
                _unreadCounts['group'] = (_unreadCounts['group'] ?? 0) + 1;
              });
              
              
            } else if (type == 'dm') {
              final from = jsonData['from'];
              final msg = jsonData['message'];
              if (from != widget.username) {
                setState(() {
                  _lastMessages[from] = msg;
                  _unreadCounts[from] = (_unreadCounts[from] ?? 0) + 1;
                });
              }
            }
          } catch (e) {
            print('[ChatList] Parse error: $e');
          }
        }
      },
      onError: (error) {
        setState(() => _isConnected = false);
        _showDisconnectDialog();
      },
      onDone: () {
        setState(() => _isConnected = false);
        _showDisconnectDialog();
      },
      cancelOnError: false,
    );
  }

  void _showDisconnectDialog() {
    if (!mounted) return;
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('Disconnected'),
        content: Text('Lost connection to server'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  void _openChat(String chatWith) {
    setState(() {
      _unreadCounts[chatWith] = 0;
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          socket: widget.socket,
          username: widget.username,
          chatWith: chatWith,
        ),
      ),
    ).then((_) {
      if (mounted) {
        setState(() {
          _unreadCounts[chatWith] = 0;
        });
      }
    });
  }

  Color _getAvatarColor(int index) {
    final colors = [
      Colors.pink, Colors.blue, Colors.green, Colors.orange,
      Colors.teal, Colors.purple, Colors.red, Colors.indigo,
    ];
    return colors[index % colors.length];
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final allChats = ['Group Chat', ..._onlineUsers];

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Color(0xFF075E54),
        title: Row(
          children: [
            Text(
              'Sajilo Chat',
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(width: 8),
            Container(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _isConnected ? Colors.green : Colors.red,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _isConnected ? 'Online' : 'Offline',
                style: TextStyle(fontSize: 10, color: Colors.white),
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: Colors.white),
            onSelected: (value) {
              if (value == 'Logout') {
                widget.socket.close();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => LoginPage()),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(value: 'Logout', child: Text('Logout')),
            ],
          ),
        ],
      ),
      body: allChats.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Waiting for users...',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                ],
              ),
            )
          : ListView.builder(
              itemCount: allChats.length,
              itemBuilder: (context, index) {
                final chatName = allChats[index];
                final isGroup = chatName == 'Group Chat';
                final chatKey = isGroup ? 'group' : chatName;
                final unreadCount = _unreadCounts[chatKey] ?? 0;
                final lastMessage = _lastMessages[chatKey] ??
                    (isGroup ? 'No messages' : 'Start chat!');

                return ChatListTile(
                  name: chatName,
                  message: lastMessage,
                  time: 'Now',
                  unreadCount: unreadCount,
                  avatarColor: _getAvatarColor(index),
                  isGroup: isGroup,
                  onTap: () => _openChat(chatKey),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        backgroundColor: Color(0xFF25D366),
        onPressed: () {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Tap a user to chat!')),
          );
        },
        child: Icon(Icons.chat, color: Colors.white),
      ),
    );
  }
}

// ============================================================================
// CHAT LIST TILE
// ============================================================================
class ChatListTile extends StatelessWidget {
  final String name;
  final String message;
  final String time;
  final int unreadCount;
  final Color avatarColor;
  final bool isGroup;
  final VoidCallback onTap;

  const ChatListTile({super.key, 
    required this.name,
    required this.message,
    required this.time,
    required this.unreadCount,
    required this.avatarColor,
    required this.isGroup,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: Colors.grey[200]!, width: 1),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 28,
              backgroundColor: avatarColor,
              child: isGroup
                  ? Icon(Icons.group, color: Colors.white, size: 28)
                  : Text(
                      name[0].toUpperCase(),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
            ),
            SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.black87,
                        ),
                      ),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 12,
                          color: unreadCount > 0
                              ? Color(0xFF25D366)
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey[600],
                          ),
                        ),
                      ),
                      if (unreadCount > 0)
                        Container(
                          margin: EdgeInsets.only(left: 8),
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Color(0xFF25D366),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '$unreadCount',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
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