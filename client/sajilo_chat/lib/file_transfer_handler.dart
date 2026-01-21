// ============================================================================
// NEW FILE: lib/file_transfer_handler.dart
// Handles TCP-based file streaming (no disk storage on server)
// ============================================================================

import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class FileTransferHandler {
  final Function(double) onProgress;
  final Function(String) onComplete;
  final Function(String) onError;
  
  // State for receiving files
  bool _isReceivingFile = false;
  Map<String, dynamic>? _currentTransferMetadata;
  IOSink? _fileSink;
  int _receivedBytes = 0;
  
  FileTransferHandler({
    required this.onProgress,
    required this.onComplete,
    required this.onError,
  });
  
  bool get isReceivingFile => _isReceivingFile;
  
  // ============================================================================
  // SENDER: Stream file to recipient
  // ============================================================================
  Future<void> sendFile({
    required File file,
    required Socket socket,
    required String senderUsername,
    required String recipientUsername,
  }) async {
    try {
      final fileSize = await file.length();
      final fileName = file.path.split('/').last;
      final fileId = const Uuid().v4();
      
      print('[FILE_SEND] Starting transfer: $fileName ($fileSize bytes)');
      
      // 1. Send metadata frame (JSON)
      final metadata = {
        'type': 'file_transfer_start',
        'file_id': fileId,
        'file_name': fileName,
        'file_size': fileSize,
        'sender': senderUsername,
        'receiver': recipientUsername,
      };
      
      final metadataFrame = '${jsonEncode(metadata)}\n';
      socket.add(utf8.encode(metadataFrame));
      await socket.flush();
      await Future.delayed(const Duration(milliseconds: 100));
      
      // 2. Stream file chunks (raw binary)
      final stream = file.openRead();
      int bytesSent = 0;
      
      await for (final chunk in stream) {
        socket.add(chunk); // Raw binary data
        bytesSent += chunk.length;
        onProgress(bytesSent / fileSize);
      }
      
      await socket.flush();
      
      // 3. Send end frame (JSON)
      final endFrame = '${jsonEncode({
        'type': 'file_transfer_end',
        'file_id': fileId,
        'status': 'success'
      })}\n';
      
      socket.add(utf8.encode(endFrame));
      await socket.flush();
      
      print('[FILE_SEND] ✓ Completed: $fileName ($bytesSent bytes)');
      onComplete(fileName);
      
    } catch (e) {
      print('[FILE_SEND] ✗ Error: $e');
      onError(e.toString());
    }
  }
  
  // ============================================================================
  // RECEIVER: Handle incoming transfer start
  // ============================================================================
  Future<void> handleTransferStart(Map<String, dynamic> metadata) async {
    try {
      final fileName = metadata['file_name'];
      final fileSize = metadata['file_size'];
      final sender = metadata['sender'];
      
      print('[FILE_RECV] Starting: $fileName from $sender ($fileSize bytes)');
      
      // Prepare file for writing
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = fileName.replaceAll(RegExp(r'[^\w\s\.-]'), '_');
      final filePath = '${directory.path}/${timestamp}_$safeName';
      final file = File(filePath);
      
      _isReceivingFile = true;
      _currentTransferMetadata = metadata;
      _fileSink = file.openWrite();
      _receivedBytes = 0;
      
      onProgress(0.0);
      
    } catch (e) {
      print('[FILE_RECV] ✗ Setup error: $e');
      onError(e.toString());
      _resetReceiveState();
    }
  }
  
  // ============================================================================
  // RECEIVER: Handle incoming chunk
  // ============================================================================
  void handleIncomingChunk(List<int> chunk) {
    if (!_isReceivingFile || _fileSink == null) return;
    
    // Check if this is the end frame (JSON)
    try {
      final decoded = utf8.decode(chunk);
      if (decoded.contains('file_transfer_end')) {
        final jsonData = jsonDecode(decoded.trim());
        handleTransferEnd(jsonData);
        return;
      }
    } catch (_) {
      // Not JSON, it's binary - continue
    }
    
    // Write chunk to file
    _fileSink!.add(chunk);
    _receivedBytes += chunk.length;
    
    // Update progress
    final fileSize = _currentTransferMetadata?['file_size'] ?? 1;
    onProgress(_receivedBytes / fileSize);
    
    // Check completion
    if (_receivedBytes >= fileSize) {
      _finalizeTransfer();
    }
  }
  
  // ============================================================================
  // RECEIVER: Handle transfer end
  // ============================================================================
  void handleTransferEnd(Map<String, dynamic> data) {
    _finalizeTransfer();
  }
  
  Future<void> _finalizeTransfer() async {
    if (!_isReceivingFile) return;
    
    await _fileSink?.flush();
    await _fileSink?.close();
    
    final fileName = _currentTransferMetadata?['file_name'] ?? 'unknown';
    print('[FILE_RECV] ✓ Completed: $fileName ($_receivedBytes bytes)');
    
    onComplete(fileName);
    _resetReceiveState();
  }
  
  void _resetReceiveState() {
    _isReceivingFile = false;
    _currentTransferMetadata = null;
    _fileSink = null;
    _receivedBytes = 0;
  }
  
  void dispose() {
    _fileSink?.close();
    _resetReceiveState();
  }
}