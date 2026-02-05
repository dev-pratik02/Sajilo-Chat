import "package:flutter/material.dart";
import 'package:sajilo_chat/login_page.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_history_handler.dart';
import 'chat_screen.dart';

class ChatsListPage extends StatefulWidget {
  final SocketWrapper? socket;
  final String? username;
  final String serverHost;
  final int serverPort;
  final String? accessToken;

  const ChatsListPage({
    super.key,
    this.socket,
    this.username,
    this.serverHost = '127.0.0.1',
    this.serverPort = 5050,
    this.accessToken,
  });

  @override
  State<ChatsListPage> createState() => _ChatsListPageState();
}

class _ChatsListPageState extends State<ChatsListPage> with RouteAware {
  StreamSubscription? _socketSubscription;
  List<String> _onlineUsers = [];
  final Map<String, int> _unreadCounts = {'group': 0};
  final Map<String, String> _lastMessages = {'group': 'No messages yet'};
  bool _isConnected = true;
  String _buffer = '';
  
  late ChatHistoryHandler _historyHandler;
  
  // FIXED: Track if we're currently in a chat to pause processing
  bool _isInChat = false;
  String? _currentChatWith;

  @override
  void initState() {
    super.initState();
    // If required connection info is missing, redirect to Login
    if (widget.socket == null || widget.username == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => LoginPage()),
        );
      });
      return;
    }

    _historyHandler = ChatHistoryHandler(
      socket: widget.socket!,
      username: widget.username!,
    );

    _setupSocketListener();
    
    Future.delayed(Duration(milliseconds: 500), () {
      if (!mounted) return;
      print('[ChatList] Requesting user list...');
      final request = '${jsonEncode({
        'type': 'request_users',
        'message': 'Requesting list'
      })}\n';
      widget.socket!.write(utf8.encode(request));
      
    });
  }

  // Attempt to reconnect to server and re-authenticate using stored token
  Future<bool> _attemptReconnect() async {
    try {
      print('[ChatList] Attempting reconnect to ${widget.serverHost}:${widget.serverPort}');
      final navigator = Navigator.of(context);
      final socket = await Socket.connect(widget.serverHost, widget.serverPort, timeout: Duration(seconds: 8));
      final wrapped = SocketWrapper(socket);

      // Wait for request_auth and send token
      final completer = Completer<bool>();
      String buffer = '';
      late StreamSubscription sub;
      sub = wrapped.stream.listen((data) {
        try {
          buffer += utf8.decode(data);
        } catch (_) {
          return;
        }

        while (buffer.contains('\n')) {
          final i = buffer.indexOf('\n');
          final line = buffer.substring(0, i).trim();
          buffer = buffer.substring(i + 1);
          if (line.isEmpty) continue;
          try {
            final j = jsonDecode(line);
            if (j['type'] == 'request_auth') {
              wrapped.write(utf8.encode(jsonEncode({'token': widget.accessToken}) + '\n'));
            }
            if (j['type'] == 'system' && j['message'] != null && j['message'].toString().contains('Welcome')) {
              // Auth successful
              completer.complete(true);
            }
          } catch (e) {
            // ignore
          }
        }
      }, onError: (e) {
        if (!completer.isCompleted) completer.complete(false);
      }, onDone: () {
        if (!completer.isCompleted) completer.complete(false);
      });

      final ok = await completer.future.timeout(Duration(seconds: 6), onTimeout: () => false);
      await sub.cancel();
      if (!ok) {
        try { wrapped.close(); } catch (_) {}
        return false;
      }

      // Replace page with new socket instance
      if (!mounted) return false;
      navigator.pushReplacement(
        MaterialPageRoute(
          builder: (context) => ChatsListPage(
            socket: wrapped,
            username: widget.username,
            serverHost: widget.serverHost,
            serverPort: widget.serverPort,
            accessToken: widget.accessToken,
          ),
        ),
      );

      return true;
    } catch (e) {
      print('[ChatList] Reconnect failed: $e');
      return false;
    }
  }

  void _setupSocketListener() {
    print('[ChatList] Setting up listener');
    
    _socketSubscription = widget.socket!.stream.listen(
      (data) {
        // FIXED: Check buffer size to prevent overflow
        if (_buffer.length > 20480) {  // 20KB limit
          print('[ChatList] Buffer overflow, clearing');
          _buffer = '';
        }
        
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
              widget.socket!.write(utf8.encode(response));
              
            } else if (type == 'user_list') {
              if (!mounted) return;
              setState(() {
                _onlineUsers = List<String>.from(jsonData['users'])
                  ..remove(widget.username);
              });
              
            } else if (type == 'group') {
              final from = jsonData['from'];
              final msg = jsonData['message'];

              // FIXED: Don't update unread if currently in group chat
              if (!_isInChat || _currentChatWith != 'group') {
                if (!mounted) return;
                setState(() {
                  _lastMessages['group'] = '$from: $msg';
                  _unreadCounts['group'] = (_unreadCounts['group'] ?? 0) + 1;
                });
              } else {
                // Just update last message without incrementing unread
                if (!mounted) return;
                setState(() {
                  _lastMessages['group'] = '$from: $msg';
                });
              }
              
            } else if (type == 'dm') {
              final from = jsonData['from'];
              final msg = jsonData['message'];
              
              if (from != widget.username) {
                // FIXED: Don't update unread if currently in this DM
                if (!_isInChat || _currentChatWith != from) {
                  if (!mounted) return;
                  setState(() {
                    _lastMessages[from] = msg;
                    _unreadCounts[from] = (_unreadCounts[from] ?? 0) + 1;
                  });
                } else {
                  // Just update last message without incrementing unread
                  if (!mounted) return;
                  setState(() {
                    _lastMessages[from] = msg;
                  });
                }
              }
            } else if (type == 'error') {
              // FIXED: Handle error messages from server
              final errorMsg = jsonData['message'] ?? 'Unknown error';
              print('[ChatList] Server error: $errorMsg');
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Server: $errorMsg'),
                  backgroundColor: Colors.orange,
                ),
              );
            }
          } catch (e) {
            print('[ChatList] Parse error: $e');
          }
        }
      },
      onError: (error) {
        print('[ChatList] Socket error: $error');
        if (!mounted) return;
        setState(() => _isConnected = false);
        _showDisconnectDialog();
      },
      onDone: () {
        print('[ChatList] Socket closed');
        if (!mounted) return;
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
          // Option to retry connection
          TextButton(
            onPressed: () async {
              if (!mounted) return;
              Navigator.of(context).pop();
              // show temporary progress dialog
              final navigator = Navigator.of(context);
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => const AlertDialog(
                  content: SizedBox(
                    height: 60,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
              );

              final messenger = ScaffoldMessenger.of(context);
              final ok = await _attemptReconnect();
              navigator.pop(); // remove progress dialog

              if (!ok) {
                if (!mounted) return;
                messenger.showSnackBar(const SnackBar(content: Text('Reconnect failed')));
                // return to login
                navigator.pop();
              }
            },
            child: Text('Retry'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              Navigator.of(context).pop();
            },
            child: Text('Exit'),
          ),
        ],
      ),
    );
  }

  void _openChat(String chatWith) {
    // FIXED: Mark that we're entering a chat
    _isInChat = true;
    _currentChatWith = chatWith;
    
    setState(() {
      _unreadCounts[chatWith] = 0;
    });

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ChatScreen(
          socket: widget.socket!,
          username: widget.username!,
          chatWith: chatWith,
          historyHandler: _historyHandler,
        ),
      ),
    ).then((_) {
      // FIXED: Mark that we've left the chat
      _isInChat = false;
      _currentChatWith = null;
      
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
                _socketSubscription?.cancel();  // FIXED: Cancel subscription before closing
                widget.socket?.close();
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

class ChatListTile extends StatelessWidget {
  final String name;
  final String message;
  final String time;
  final int unreadCount;
  final Color avatarColor;
  final bool isGroup;
  final VoidCallback onTap;

  const ChatListTile({
    super.key, 
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
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
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
                          constraints: BoxConstraints(minWidth: 20),
                          decoration: BoxDecoration(
                            color: Color(0xFF25D366),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unreadCount > 99 ? '99+' : '$unreadCount',  // FIXED: Cap display at 99+
                            textAlign: TextAlign.center,
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
