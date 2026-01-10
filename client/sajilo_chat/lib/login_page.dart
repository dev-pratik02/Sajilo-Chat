import "package:flutter/material.dart";
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_list.dart';


// ============================================================================
// LOGIN PAGE
// ============================================================================
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _serverController = TextEditingController(text: '192.168.0.100');
  final _portController = TextEditingController(text: '5050');
  bool _isLoading = false;

  Future<void> _connect() async {
    if (_formKey.currentState!.validate()) {
      setState(() => _isLoading = true);

      try {
        final host = _serverController.text;
        final port = int.parse(_portController.text);
        final username = _usernameController.text;
        
        final socket = await Socket.connect(
          host,
          port,
          timeout: Duration(seconds: 10),
        );

        final wrappedSocket = SocketWrapper(socket);
        final intro = '${jsonEncode({
        'type': 'set_username',
        'username': username,
          })}\n';

      wrappedSocket.write(utf8.encode(intro));
        
        setState(() => _isLoading = false);

        if (!mounted) return;

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (context) => ChatsListPage(
              socket: wrappedSocket,
              username: username,
            ),
          ),
        );
      } catch (e) {
        setState(() => _isLoading = false);
        debugPrint('❌ Error: $e');
        
        if (!mounted) return;
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 5),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF667eea), Color(0xFF764ba2)],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(horizontal: 32.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 20,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.chat_bubble_outline,
                            size: 60,
                            color: Color(0xFF667eea),
                          ),
                        ),
                        SizedBox(height: 30),
                        Text(
                          'Sajilo Chat',
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.5,
                          ),
                        ),
                        SizedBox(height: 10),
                        Text(
                          'Connect to start chatting!',
                          style: TextStyle(fontSize: 18, color: Colors.white70),
                        ),
                        SizedBox(height: 50),
                        
                        _buildTextField(
                          controller: _usernameController,
                          hintText: 'Username',
                          icon: Icons.person,
                          validator: (v) => v?.isEmpty ?? true ? 'Enter username' : null,
                        ),
                        SizedBox(height: 20),
                        
                        _buildTextField(
                          controller: _serverController,
                          hintText: 'Server IP',
                          icon: Icons.dns,
                          validator: (v) => v?.isEmpty ?? true ? 'Enter IP' : null,
                        ),
                        SizedBox(height: 20),
                        
                        _buildTextField(
                          controller: _portController,
                          hintText: 'Port',
                          icon: Icons.power,
                          keyboardType: TextInputType.number,
                          validator: (v) => v?.isEmpty ?? true ? 'Enter port' : null,
                        ),
                        SizedBox(height: 30),
                        
                        SizedBox(
                          width: double.infinity,
                          height: 55,
                          child: ElevatedButton(
                            onPressed: _isLoading ? null : _connect,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Color(0xFF667eea),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15),
                              ),
                              elevation: 5,
                            ),
                            child: Text(
                              'Connect',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(height: 20),
                        
                        Container(
                          padding: EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Column(
                            children: [
                              Text(
                                '💡 Quick Start',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              SizedBox(height: 5),
                              Text(
                                '1. Start server: python chatroom_server.py',
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                              Text(
                                '2. Use "localhost" for same PC',
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                              Text(
                                '3. Port: 5050',
                                style: TextStyle(color: Colors.white70, fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 16),
                    Text(
                      'Connecting...',
                      style: TextStyle(color: Colors.white, fontSize: 16),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Icon(icon, color: Color(0xFF667eea)),
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        validator: validator,
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _serverController.dispose();
    _portController.dispose();
    super.dispose();
  }
}
