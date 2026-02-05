import "package:flutter/material.dart";
import 'package:google_fonts/google_fonts.dart';
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

class _ChatsListPageState extends State<ChatsListPage> with RouteAware, TickerProviderStateMixin {
  StreamSubscription? _socketSubscription;
  List<String> _onlineUsers = [];
  final Map<String, int> _unreadCounts = {'group': 0};
  final Map<String, String> _lastMessages = {'group': 'No messages yet'};
  bool _isConnected = true;
  String _buffer = '';
  
  late ChatHistoryHandler _historyHandler;
  
  bool _isInChat = false;
  String? _currentChatWith;

  @override
  void initState() {
    super.initState();
    
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

  Future<bool> _attemptReconnect() async {
    try {
      print('[ChatList] Attempting reconnect to ${widget.serverHost}:${widget.serverPort}');
      final navigator = Navigator.of(context);
      final socket = await Socket.connect(widget.serverHost, widget.serverPort, timeout: Duration(seconds: 8));
      final wrapped = SocketWrapper(socket);

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
        if (_buffer.length > 20480) {
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

              if (!_isInChat || _currentChatWith != 'group') {
                if (!mounted) return;
                setState(() {
                  _lastMessages['group'] = '$from: $msg';
                  _unreadCounts['group'] = (_unreadCounts['group'] ?? 0) + 1;
                });
              } else {
                if (!mounted) return;
                setState(() {
                  _lastMessages['group'] = '$from: $msg';
                });
              }
              
            } else if (type == 'dm') {
              final from = jsonData['from'];
              final msg = jsonData['message'];
              
              if (from != widget.username) {
                if (!_isInChat || _currentChatWith != from) {
                  if (!mounted) return;
                  setState(() {
                    _lastMessages[from] = msg;
                    _unreadCounts[from] = (_unreadCounts[from] ?? 0) + 1;
                  });
                } else {
                  if (!mounted) return;
                  setState(() {
                    _lastMessages[from] = msg;
                  });
                }
              }
            } else if (type == 'error') {
              final errorMsg = jsonData['message'] ?? 'Unknown error';
              print('[ChatList] Server error: $errorMsg');
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('Server: $errorMsg'),
                  backgroundColor: Color(0xFFFF6B6B),
                  behavior: SnackBarBehavior.floating,
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
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Connection Lost',
          style: GoogleFonts.poppins(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Would you like to reconnect?',
          style: GoogleFonts.poppins(),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => LoginPage()),
              );
            },
            child: Text('Logout', style: GoogleFonts.poppins(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(context);
              final reconnected = await _attemptReconnect();
              if (!reconnected && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Reconnection failed'),
                    backgroundColor: Color(0xFFFF6B6B),
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Color(0xFF6C63FF),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text('Reconnect', style: GoogleFonts.poppins(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _openChat(String chatWith) async {
    setState(() {
      _isInChat = true;
      _currentChatWith = chatWith;
    });

    await Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => ChatScreen(
          socket: widget.socket!,
          username: widget.username!,
          chatWith: chatWith,
          historyHandler: _historyHandler,
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeInOutCubic;
          var tween = Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: Duration(milliseconds: 300),
      ),
    );

    setState(() {
      _isInChat = false;
      _currentChatWith = null;
    });

    if (mounted) {
      setState(() {
        _unreadCounts[chatWith] = 0;
      });
    }
  }

  Color _getAvatarColor(int index) {
    final colors = [
      Color(0xFF6C63FF), // Purple
      Color(0xFF4ECDC4), // Teal
      Color(0xFFFF6B6B), // Red
      Color(0xFFFFA502), // Orange
      Color(0xFF26DE81), // Green
      Color(0xFFFC5C65), // Pink
      Color(0xFF45AAF2), // Blue
      Color(0xFFA55EEA), // Violet
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
      backgroundColor: Color(0xFFF5F5FA),
      appBar: AppBar(
        backgroundColor: Color(0xFF6C63FF),
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.chat_bubble_rounded, color: Colors.white, size: 24),
            ),
            SizedBox(width: 12),
            Text(
              'Sajilo Chat',
              style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
            SizedBox(width: 12),
            AnimatedContainer(
              duration: Duration(milliseconds: 300),
              padding: EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _isConnected ? Color(0xFF26DE81) : Color(0xFFFF6B6B),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                  SizedBox(width: 6),
                  Text(
                    _isConnected ? 'Online' : 'Offline',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert_rounded, color: Colors.white),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
            onSelected: (value) {
              if (value == 'Logout') {
                _socketSubscription?.cancel();
                widget.socket?.close();
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(builder: (context) => LoginPage()),
                );
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'Logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Color(0xFF6C63FF), size: 20),
                    SizedBox(width: 10),
                    Text('Logout', style: GoogleFonts.poppins()),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: allChats.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TweenAnimationBuilder<double>(
                    duration: Duration(seconds: 2),
                    tween: Tween(begin: 0.0, end: 1.0),
                    builder: (context, value, child) {
                      return Transform.rotate(
                        angle: value * 2 * 3.14159,
                        child: child,
                      );
                    },
                    onEnd: () => setState(() {}),
                    child: CircularProgressIndicator(
                      valueColor: AlwaysStoppedAnimation(Color(0xFF6C63FF)),
                      strokeWidth: 3,
                    ),
                  ),
                  SizedBox(height: 24),
                  Text(
                    'Connecting to server...',
                    style: GoogleFonts.poppins(
                      fontSize: 16,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w500,
                    ),
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

                return TweenAnimationBuilder<double>(
                  duration: Duration(milliseconds: 300 + (index * 50)),
                  tween: Tween(begin: 0.0, end: 1.0),
                  builder: (context, value, child) {
                    return Opacity(
                      opacity: value,
                      child: Transform.translate(
                        offset: Offset(0, 50 * (1 - value)),
                        child: child,
                      ),
                    );
                  },
                  child: ChatListTile(
                    name: chatName,
                    message: lastMessage,
                    time: 'Now',
                    unreadCount: unreadCount,
                    avatarColor: _getAvatarColor(index),
                    isGroup: isGroup,
                    onTap: () => _openChat(chatKey),
                  ),
                );
              },
            ),
      floatingActionButton: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF6C63FF), Color(0xFF8B7FFF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Color(0xFF6C63FF).withOpacity(0.4),
              blurRadius: 15,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: FloatingActionButton(
          backgroundColor: Colors.transparent,
          elevation: 0,
          onPressed: () {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Tap a chat to start messaging!', style: GoogleFonts.poppins()),
                backgroundColor: Color(0xFF6C63FF),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Icon(Icons.chat_bubble_rounded, color: Colors.white),
        ),
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
        margin: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        padding: EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 10,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Hero(
              tag: 'avatar_${isGroup ? "group" : name}',
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [avatarColor, avatarColor.withOpacity(0.7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: avatarColor.withOpacity(0.3),
                      blurRadius: 8,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: CircleAvatar(
                  radius: 28,
                  backgroundColor: Colors.transparent,
                  child: isGroup
                      ? Icon(Icons.group_rounded, color: Colors.white, size: 28)
                      : Text(
                          name[0].toUpperCase(),
                          style: GoogleFonts.poppins(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
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
                          style: GoogleFonts.poppins(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.black87,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        time,
                        style: GoogleFonts.poppins(
                          fontSize: 12,
                          color: unreadCount > 0
                              ? Color(0xFF6C63FF)
                              : Colors.grey[400],
                          fontWeight: unreadCount > 0 ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          message,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            color: unreadCount > 0 ? Colors.black87 : Colors.grey[600],
                            fontWeight: unreadCount > 0 ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ),
                      if (unreadCount > 0)
                        Container(
                          margin: EdgeInsets.only(left: 8),
                          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          constraints: BoxConstraints(minWidth: 24),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Color(0xFF6C63FF), Color(0xFF8B7FFF)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(12),
                            boxShadow: [
                              BoxShadow(
                                color: Color(0xFF6C63FF).withOpacity(0.3),
                                blurRadius: 8,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Text(
                            unreadCount > 99 ? '99+' : '$unreadCount',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.poppins(
                              color: Colors.white,
                              fontSize: 11,
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