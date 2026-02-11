import "package:flutter/material.dart";
import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:google_fonts/google_fonts.dart';

import 'package:sajilo_chat/utilities.dart';
import 'package:sajilo_chat/chat_list.dart';
import 'package:sajilo_chat/crypto_manager.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with TickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _serverController = TextEditingController(text: '192.168.0.100');
  final _portController = TextEditingController(text: '5050');

  bool _isLoading = false;
  bool _isRegisterMode = false;
  
  late AnimationController _logoAnimationController;
  late Animation<double> _logoAnimation;
  
  // E2EE: Crypto manager instance
  final CryptoManager _cryptoManager = CryptoManager();

  @override
  void initState() {
    super.initState();
    _logoAnimationController = AnimationController(
      duration: Duration(milliseconds: 1500),
      vsync: this,
    );
    _logoAnimation = CurvedAnimation(
      parent: _logoAnimationController,
      curve: Curves.elasticOut,
    );
    _logoAnimationController.forward();
  }

  @override
  void dispose() {
    _logoAnimationController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _serverController.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final host = _serverController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    try {
      // E2EE Step 1: Initialize crypto manager and generate keys
      print('[E2EE] Initializing crypto for new user: $username');
      await _cryptoManager.initialize(username);
      
      // E2EE Step 2: Get public key to send to server
      final publicKey = await _cryptoManager.getPublicIdentityKey();
      print('[E2EE] Generated public key for registration');
      
      // E2EE Step 3: Register with public key
      final response = await http.post(
        Uri.parse('http://$host:5001/auth/register'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'username': username,
          'password': password,
          'public_key': publicKey, 
        }),
      );

      if (response.statusCode == 201) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                Icon(Icons.check_circle, color: Colors.white),
                SizedBox(width: 12),
                Text('Registration successful!  E2EE enabled', 
                     style: GoogleFonts.poppins()),
              ],
            ),
            backgroundColor: Color(0xFF26DE81),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            duration: Duration(seconds: 3),
          ),
        );
        setState(() => _isRegisterMode = false);
      } else {
        final err = jsonDecode(response.body);
        throw Exception(err['error'] ?? 'Registration failed');
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              SizedBox(width: 12),
              Expanded(child: Text('Error: $e', style: GoogleFonts.poppins())),
            ],
          ),
          backgroundColor: Color(0xFFFF6B6B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loginAndConnect() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      final host = _serverController.text.trim();
      final port = 5050; // Port is   for socket connection
      final username = _usernameController.text.trim();
      final password = _passwordController.text.trim();

      // E2EE Step 1: Initialize crypto manager (loads existing keys or creates new)
      print('[E2EE] Initializing crypto for user: $username');
      await _cryptoManager.initialize(username);
      
      // E2EE Step 2: Get public key
      final publicKey = await _cryptoManager.getPublicIdentityKey();
      print('[E2EE] Loaded/Generated public key');
      
      // Login to Flask API
      final loginResponse = await http
          .post(
            Uri.parse('http://$host:5001/auth/login'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'username': username, 'password': password}),
          )
          .timeout(const Duration(seconds: 10));

      if (loginResponse.statusCode != 200) {
        final err = jsonDecode(loginResponse.body);
        throw Exception(err['error'] ?? 'Login failed');
      }

      final accessToken = jsonDecode(loginResponse.body)['access_token'];
      
      // E2EE Step 3: Upload/update public key to server
      print('[E2EE] Uploading public key to server');
      try {
        await http.post(
          Uri.parse('http://$host:5001/api/keys/upload'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'username': username,
            'public_key': publicKey,
          }),
        );
        print('[E2EE] Public key uploaded successfully');
      } catch (e) {
        print('[E2EE] Warning: Failed to upload public key: $e');
      }

      // Connect to socket server
      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 10),
      );

      final wrappedSocket = SocketWrapper(socket);

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
                PageRouteBuilder(
                  pageBuilder: (context, animation, secondaryAnimation) => ChatsListPage(
                    socket: wrappedSocket,
                    username: username,
                    serverHost: host,
                    serverPort: port,
                    accessToken: accessToken,
                    cryptoManager: _cryptoManager, 
                  ),
                  transitionsBuilder: (context, animation, secondaryAnimation, child) {
                    return FadeTransition(opacity: animation, child: child);
                  },
                  transitionDuration: Duration(milliseconds: 500),
                ),
              );
            }
          } catch (e) {
            debugPrint('JSON decode error: $e\nData: $line');
          }
        }
      });

      setState(() => _isLoading = false);
    } catch (e) {
      setState(() => _isLoading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              Icon(Icons.error_outline, color: Colors.white),
              SizedBox(width: 12),
              Expanded(child: Text('Error: $e', style: GoogleFonts.poppins())),
            ],
          ),
          backgroundColor: Color(0xFFFF6B6B),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Gradient background
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF6C63FF),
                  Color(0xFF8B7FFF),
                  Color(0xFF9D8FFF),
                ],
              ),
            ),
          ),
          
          // Floating circles decoration
          Positioned(
            top: -100,
            left: -100,
            child: Container(
              width: 300,
              height: 300,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),
          Positioned(
            bottom: -150,
            right: -100,
            child: Container(
              width: 400,
              height: 400,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withOpacity(0.1),
              ),
            ),
          ),
          
          // Main content
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Logo with animation
                      ScaleTransition(
                        scale: _logoAnimation,
                        child: Container(
                          padding: EdgeInsets.all(24),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.2),
                                blurRadius: 30,
                                offset: Offset(0, 15),
                              ),
                            ],
                          ),
                          child: Icon(
                            Icons.message_rounded,  
                            size: 60,
                            color: Color(0xFF6C63FF),
                          ),
                        ),
                      ),
                      const SizedBox(height: 40),
                      
                      Text(
                        'Sajilo Chat',
                        style: GoogleFonts.poppins(
                          fontSize: 40,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                          letterSpacing: 1.2,
                        ),
                      ),
                      const SizedBox(height: 8),
                      // E2EE badge
                      Container(
                        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: Colors.white.withOpacity(0.5)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(width: 6),
                            Text(
                              'End-to-End Encrypted',
                              style: GoogleFonts.poppins(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _isRegisterMode
                            ? 'Create your account'
                            : 'Welcome back!',
                        style: GoogleFonts.poppins(
                          fontSize: 16,
                          color: Colors.white.withOpacity(0.9),
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: 50),
                      
                      _buildTextField(
                        controller: _usernameController,
                        hintText: 'Username',
                        icon: Icons.person_rounded,
                        validator: (v) =>
                            v?.isEmpty ?? true ? 'Enter username' : null,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        controller: _passwordController,
                        hintText: 'Password',
                        icon: Icons.lock_rounded,
                        obscureText: true,
                        validator: (v) =>
                            (v?.length ?? 0) < 8 ? 'Password too short' : null,
                      ),
                      const SizedBox(height: 16),
                      _buildTextField(
                        controller: _serverController,
                        hintText: 'Server IP',
                        icon: Icons.dns_rounded,
                        validator: (v) =>
                            v?.isEmpty ?? true ? 'Enter server IP' : null,
                      ),
                      
                      const SizedBox(height: 32),
                      
                      SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: ElevatedButton(
                          onPressed: _isLoading
                              ? null
                              : (_isRegisterMode ? _register : _loginAndConnect),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Color(0xFF6C63FF),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            elevation: 8,
                            shadowColor: Colors.black.withOpacity(0.3),
                          ),
                          child: Text(
                            _isRegisterMode ? 'Create Account' : 'Login & Connect',
                            style: GoogleFonts.poppins(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      
                      GestureDetector(
                        onTap: _isLoading
                            ? null
                            : () {
                                setState(() => _isRegisterMode = !_isRegisterMode);
                              },
                        child: Text(
                          _isRegisterMode
                              ? 'Already have an account? Login'
                              : 'Don\'t have an account? Register',
                          style: GoogleFonts.poppins(
                            color: const Color.fromARGB(255, 252, 252, 252),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          
          // Loading overlay
          if (_isLoading)
            Container(
              color: Colors.black54,
              child: Center(
                child: Container(
                  padding: EdgeInsets.all(32),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(
                        valueColor: AlwaysStoppedAnimation(Color(0xFF6C63FF)),
                      ),
                      SizedBox(height: 20),
                      Text(
                        _isRegisterMode ? 'Creating account...' : 'Connecting...',
                        style: GoogleFonts.poppins(
                          color: Color(0xFF6C63FF),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (_isRegisterMode)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Generating encryption keys ',
                            style: GoogleFonts.poppins(
                              color: Colors.grey[600],
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
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
    bool obscureText = false,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: TextFormField(
        controller: controller,
        obscureText: obscureText,
        keyboardType: keyboardType,
        style: GoogleFonts.poppins(),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: GoogleFonts.poppins(color: Colors.grey[400]),
          prefixIcon: Icon(icon, color: Color(0xFF6C63FF)),
          border: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
        ),
        validator: validator,
      ),
    );
  }
}
