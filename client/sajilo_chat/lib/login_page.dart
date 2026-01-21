import "package:flutter/material.dart";
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;

import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_list.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _serverController = TextEditingController(text: '192.168.0.100');
  final _portController = TextEditingController(text: '5050');

  bool _isLoading = false;
  bool _isRegisterMode = false;

  // ---------------------------------------------------------------------------
  // REGISTER
  // ---------------------------------------------------------------------------
  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final host = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    try {
      final response = await http.post(
        Uri.parse('http://$host:5000/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'username': username, 'password': password}),
      );

      if (response.statusCode == 201) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('✅ Registration successful! You can now login.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
        setState(() => _isRegisterMode = false);
      } else {
        final err = jsonDecode(response.body);
        throw Exception(err['error'] ?? 'Registration failed');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // LOGIN + SOCKET CONNECT
  // ---------------------------------------------------------------------------
  Future<void> _loginAndConnect() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      final host = _serverController.text.trim();
      final port = int.parse(_portController.text.trim());
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      // LOGIN VIA FLASK
      final loginResponse = await http
          .post(
            Uri.parse('http://$host:5000/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (loginResponse.statusCode != 200) {
        final err = jsonDecode(loginResponse.body);
        throw Exception(err['error'] ?? 'Login failed');
      }

      final accessToken = jsonDecode(loginResponse.body)['access_token'];

      // CONNECT TO CHAT SERVER
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );

      final wrappedSocket = SocketWrapper(socket);

      // HANDLE AUTH HANDSHAKE
      late StreamSubscription sub;
      String buffer = '';

      sub = wrappedSocket.stream.listen((data) {
        buffer += utf8.decode(data);
        while (buffer.contains('\n')) {
          final lineEnd = buffer.indexOf('\n');
          final line = buffer.substring(0, lineEnd).trim();
          buffer = buffer.substring(lineEnd + 1);
          if (line.isEmpty) continue;

          try {
            final decoded = jsonDecode(line);

            if (decoded['type'] == 'request_auth') {
              wrappedSocket.write(
                utf8.encode(jsonEncode({'token': accessToken}) + '\n'),
              );
            }

            if (decoded['type'] == 'system' &&
                decoded['message'] != null &&
                decoded['message'].toString().contains('Welcome')) {
              sub.cancel();
              if (!mounted) return;
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      ChatsListPage(socket: wrappedSocket, username: username),
                ),
              );
            }
          } catch (e) {
            debugPrint('⚠️ JSON decode error: $e\nData: $line');
          }
        }
      });

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ Error: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // =========================================================================
  // UI
  // =========================================================================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF667eea), Color(0xFF764ba2)],
              ),
            ),
            child: SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 32.0),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black26,
                                blurRadius: 20,
                                offset: Offset(0, 10),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.chat_bubble_outline,
                            size: 60,
                            color: Color(0xFF667eea),
                          ),
                        ),
                        const SizedBox(height: 30),
                        const Text(
                          'Sajilo Chat',
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                            letterSpacing: 1.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _isRegisterMode
                              ? 'Create a new account'
                              : 'Connect to start chatting!',
                          style: const TextStyle(
                              fontSize: 18, color: Colors.white70),
                        ),
                        const SizedBox(height: 50),
                        _buildTextField(
                          controller: _usernameController,
                          hintText: 'Username',
                          icon: Icons.person,
                          validator: (v) =>
                              v?.isEmpty ?? true ? 'Enter username' : null,
                        ),
                        const SizedBox(height: 20),
                        _buildTextField(
                          controller: _passwordController,
                          hintText: 'Password',
                          icon: Icons.lock,
                          obscureText: true,
                          validator: (v) =>
                              (v?.length ?? 0) < 8 ? 'Password too short' : null,
                        ),
                        const SizedBox(height: 20),
                        _buildTextField(
                          controller: _serverController,
                          hintText: 'Server IP',
                          icon: Icons.dns,
                          validator: (v) =>
                              v?.isEmpty ?? true ? 'Enter server IP' : null,
                        ),
                        const SizedBox(height: 20),
                        _buildTextField(
                          controller: _portController,
                          hintText: 'Port',
                          icon: Icons.power,
                          keyboardType: TextInputType.number,
                          validator: (v) => v?.isEmpty ?? true ? 'Enter port' : null,
                        ),
                        const SizedBox(height: 30),
                        SizedBox(
                          width: double.infinity,
                          height: 55,
                          child: ElevatedButton(
                            onPressed: _isLoading
                                ? null
                                : (_isRegisterMode ? _register : _loginAndConnect),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: const Color(0xFF667eea),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(15),
                              ),
                              elevation: 5,
                            ),
                            child: Text(
                              _isRegisterMode ? 'Register' : 'Login & Connect',
                              style: const TextStyle(
                                  fontSize: 18, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        GestureDetector(
                          onTap: _isLoading
                              ? null
                              : () {
                                  setState(() => _isRegisterMode = !_isRegisterMode);
                                },
                          child: Text(
                            _isRegisterMode
                                ? 'Already have an account? Login'
                                : 'Don’t have an account? Register',
                            style: const TextStyle(
                              color: Colors.white,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ),
                        const SizedBox(height: 20),
                        if (!_isRegisterMode)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Column(
                              children: const [
                                Text(
                                  '💡 Quick Start',
                                  style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
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
              child: const Center(
                child: CircularProgressIndicator(color: Colors.white),
              ),
            ),
        ],
      ),
    );
  }

  // =========================================================================
  // INPUT FIELD DECORATOR
  // =========================================================================
  Widget _buildTextField({
    required TextEditingController controller,
    required String hintText,
    required IconData icon,
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(15),
        boxShadow: const [
          BoxShadow(
            color: Colors.black12,
            blurRadius: 10,
            offset: Offset(0, 5),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          hintText: hintText,
          prefixIcon: Icon(icon, color: const Color(0xFF667eea)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        validator: validator,
      ),
    );
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _serverController.dispose();
    _portController.dispose();
    super.dispose();
  }
}
