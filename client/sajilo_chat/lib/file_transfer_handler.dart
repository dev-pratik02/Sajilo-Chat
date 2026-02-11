import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'package:crypto/crypto.dart';

/// Transfer states for better state management
enum TransferState {
  idle,
  preparing,
  waitingForAck,
  transferring,
  verifying,
  complete,
  failed
}

class FileTransferHandler {
  final Function(double) onProgress;
  final Function(String fileName, String filePath, bool isSender) onComplete;  // ✅ FIX: Added isSender parameter
  final Function(String) onError;
  
  // Receiving state
  TransferState _receiveState = TransferState.idle;
  Map<String, dynamic>? _currentTransferMetadata;
  IOSink? _fileSink;
  String? _currentFilePath;
  int _receivedBytes = 0;
  int _expectedBytes = 0;
  Timer? _receiveTimeout;
  
  // Checksum validation
  List<int> _receivedData = [];
  
  // Disposal flag to prevent callbacks after disposal
  bool _isDisposed = false;
  
  // StreamController for safe async operations
  final StreamController<void> _operationController = StreamController<void>.broadcast();
  
  // Constants
  static const int CHUNK_SIZE = 8192; // 8KB chunks for smoother transfer
  static const int TRANSFER_TIMEOUT_SECONDS = 60; // Increased timeout
  static const int ACK_TIMEOUT_SECONDS = 10;
  
  FileTransferHandler({
    required this.onProgress,
    required this.onComplete,
    required this.onError,
  });
  
  bool get isReceivingFile => _receiveState == TransferState.transferring;
  
  // ✅ CRITICAL FIX: Safe callback wrappers with try-catch and disposal checks
  void _safeOnProgress(double progress) {
    if (_isDisposed) return;
    
    // Schedule on next microtask to avoid zone errors
    scheduleMicrotask(() {
      if (_isDisposed) return;
      try {
        onProgress(progress);
      } catch (e, stack) {
        print('[FILE_HANDLER] ❌ Error in onProgress: $e');
        if (kDebugMode) print(stack);
      }
    });
  }
  
  void _safeOnComplete(String fileName, String filePath, bool isSender) {  // ✅ FIX: Added isSender parameter
    if (_isDisposed) return;
    
    scheduleMicrotask(() {
      if (_isDisposed) return;
      try {
        onComplete(fileName, filePath, isSender);  // ✅ FIX: Pass isSender
      } catch (e, stack) {
        print('[FILE_HANDLER] ❌ Error in onComplete: $e');
        if (kDebugMode) print(stack);
      }
    });
  }
  
  void _safeOnError(String error) {
    if (_isDisposed) return;
    
    scheduleMicrotask(() {
      if (_isDisposed) return;
      try {
        onError(error);
      } catch (e, stack) {
        print('[FILE_HANDLER] ❌ Error in onError: $e');
        if (kDebugMode) print(stack);
      }
    });
  }
  
  /// Send file with improved chunking and flow control
  Future<void> sendFile({
    required File file,
    required Socket socket,
    required String senderUsername,
    required String recipientUsername,
  }) async {
    if (_isDisposed) {
      print('[FILE_SEND] ⚠️ Handler disposed, aborting');
      return;
    }
    
    try {
      final fileSize = await file.length();
      final fileName = file.path.split('/').last;
      final fileId = const Uuid().v4();
      
      print('[FILE_SEND] 📤 Starting: $fileName ($fileSize bytes)');
      
      // Calculate checksum for verification
      final bytes = await file.readAsBytes();
      if (_isDisposed) return;
      
      final checksum = md5.convert(bytes).toString();
      
      // Step 1: Send metadata frame
      final metadata = {
        'type': 'file_transfer_start',
        'file_id': fileId,
        'file_name': fileName,
        'file_size': fileSize,
        'sender': senderUsername,
        'receiver': recipientUsername,
        'checksum': checksum,
        'chunk_size': CHUNK_SIZE,
      };
      
      final metadataFrame = '${jsonEncode(metadata)}\n';
      socket.add(utf8.encode(metadataFrame));
      await socket.flush();
      
      print('[FILE_SEND] ✓ Metadata sent, waiting 500ms...');
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (_isDisposed) return;
      
      // Step 2: Stream file in controlled chunks
      int bytesSent = 0;
      int chunkIndex = 0;
      final totalChunks = (fileSize / CHUNK_SIZE).ceil();
      
      for (int i = 0; i < bytes.length; i += CHUNK_SIZE) {
        if (_isDisposed) {
          print('[FILE_SEND] ⚠️ Handler disposed during transfer');
          return;
        }
        
        final end = (i + CHUNK_SIZE < bytes.length) ? i + CHUNK_SIZE : bytes.length;
        final chunk = bytes.sublist(i, end);
        
        // Send raw binary chunk
        socket.add(chunk);
        bytesSent += chunk.length;
        chunkIndex++;
        
        // Update progress
        final progress = bytesSent / fileSize;
        _safeOnProgress(progress);
        
        // Log progress every 10 chunks
        if (chunkIndex % 10 == 0 || chunkIndex == totalChunks) {
          print('[FILE_SEND] Progress: $bytesSent/$fileSize bytes (${(progress * 100).toInt()}%)');
        }
        
        // Flow control: Small delay every 10 chunks to prevent buffer overflow
        if (chunkIndex % 10 == 0) {
          await socket.flush();
          await Future.delayed(const Duration(milliseconds: 20));
        }
      }
      
      if (_isDisposed) return;
      
      // Final flush
      await socket.flush();
      
      print('[FILE_SEND] ✓ All chunks sent, waiting 500ms before end frame...');
      await Future.delayed(const Duration(milliseconds: 500));
      
      if (_isDisposed) return;
      
      // Step 3: Send end frame with checksum
      final endFrame = {
        'type': 'file_transfer_end',
        'file_id': fileId,
        'status': 'success',
        'checksum': checksum,
        'bytes_sent': bytesSent,
      };
      
      final endFrameJson = '${jsonEncode(endFrame)}\n';
      socket.add(utf8.encode(endFrameJson));
      await socket.flush();
      
      print('[FILE_SEND] ✅ Complete: $fileName ($bytesSent bytes)');
      print('[FILE_SEND] Checksum: $checksum');
      
      _safeOnComplete(fileName, '', true);  // ✅ FIX: Pass true for sender
      
    } catch (e, stackTrace) {
      print('[FILE_SEND] ❌ Error: $e');
      if (kDebugMode) print('[FILE_SEND] Stack trace: $stackTrace');
      _safeOnError('Failed to send file: $e');
    }
  }
  
  /// Handle transfer start with improved state management
  Future<void> handleTransferStart(Map<String, dynamic> metadata) async {
    if (_isDisposed) {
      print('[FILE_RECV] ⚠️ Handler disposed, ignoring transfer start');
      return;
    }
    
    try {
      // Cancel any existing timeout
      _receiveTimeout?.cancel();
      
      final fileName = metadata['file_name'];
      final fileSize = metadata['file_size'];
      final sender = metadata['sender'];
      final checksum = metadata['checksum'];
      
      print('[FILE_RECV] 📥 Starting: $fileName from $sender ($fileSize bytes)');
      print('[FILE_RECV] Expected checksum: $checksum');
      
      // Change state
      _receiveState = TransferState.preparing;
      
      // Prepare file for writing
      final directory = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final safeName = fileName.replaceAll(RegExp(r'[^\w\s\.-]'), '_');
      final filePath = '${directory.path}/${timestamp}_$safeName';
      final file = File(filePath);
      
      if (_isDisposed) return;
      
      // Ensure we can write
      try {
        await file.create(recursive: true);
      } catch (e) {
        print('[FILE_RECV] ❌ Cannot create file: $e');
        _receiveState = TransferState.failed;
        _safeOnError('Cannot save file: Permission denied');
        return;
      }
      
      if (_isDisposed) return;
      
      // Initialize receive state
      _currentTransferMetadata = metadata;
      _currentFilePath = filePath;
      _fileSink = file.openWrite();
      _receivedBytes = 0;
      _expectedBytes = fileSize;
      _receivedData = [];
      
      // Set timeout for transfer
      _receiveTimeout = Timer(Duration(seconds: TRANSFER_TIMEOUT_SECONDS), () {
        if (!_isDisposed) {
          print('[FILE_RECV] ⏱️ Transfer timeout!');
          _handleTransferTimeout();
        }
      });
      
      print('[FILE_RECV] ✓ Ready to receive, saving to: $filePath');
      _safeOnProgress(0.0);
      
    } catch (e, stackTrace) {
      print('[FILE_RECV] ❌ Setup error: $e');
      if (kDebugMode) print('[FILE_RECV] Stack trace: $stackTrace');
      _safeOnError('Failed to prepare file: $e');
      resetReceiveState();  // ✅ FIX: Use public method
    }
  }
  
  /// Handle incoming chunk with improved byte counting
  void handleIncomingChunk(List<int> chunk) {
    if (_isDisposed) return;
    
    if (_receiveState != TransferState.transferring || _fileSink == null) {
      print('[FILE_RECV] ⚠️ Received chunk but not in transferring state (state: $_receiveState)');
      return;
    }
    
    try {
      // Reset timeout on each chunk
      _receiveTimeout?.cancel();
      _receiveTimeout = Timer(Duration(seconds: TRANSFER_TIMEOUT_SECONDS), () {
        if (!_isDisposed) {
          print('[FILE_RECV] ⏱️ Transfer timeout during transfer!');
          _handleTransferTimeout();
        }
      });
      
      // Calculate remaining bytes
      final remaining = _expectedBytes - _receivedBytes;
      
      if (remaining <= 0) {
        print('[FILE_RECV] ⚠️ Received chunk after completion, ignoring');
        return;
      }
      
      // Determine how much of this chunk is file data
      final bytesToWrite = chunk.length <= remaining ? chunk.length : remaining;
      
      if (bytesToWrite > 0) {
        final dataToWrite = chunk.sublist(0, bytesToWrite);
        
        // Write to file
        _fileSink!.add(dataToWrite);
        
        // Store for checksum verification
        _receivedData.addAll(dataToWrite);
        
        _receivedBytes += bytesToWrite;
        
        // Update progress
        final progress = _receivedBytes / _expectedBytes;
        _safeOnProgress(progress);
        
        // Log progress every 25%
        final progressPct = (progress * 100).toInt();
        if (progressPct % 25 == 0 || _receivedBytes >= _expectedBytes) {
          print('[FILE_RECV] Progress: $_receivedBytes/$_expectedBytes bytes ($progressPct%)');
        }
      }
      
      // Check if transfer complete by byte count
      if (_receivedBytes >= _expectedBytes) {
        print('[FILE_RECV] ✓ All bytes received ($_receivedBytes/$_expectedBytes)');
        _receiveState = TransferState.verifying;
        // Don't finalize yet - wait for end frame with checksum
      }
      
    } catch (e, stackTrace) {
      print('[FILE_RECV] ❌ Error writing chunk: $e');
      if (kDebugMode) print('[FILE_RECV] Stack trace: $stackTrace');
      _safeOnError('Failed to write file: $e');
      resetReceiveState();  // ✅ FIX: Use public method
    }
  }
  
  /// Handle transfer end with checksum verification
  void handleTransferEnd(Map<String, dynamic> data) {
    if (_isDisposed) return;
    
    final status = data['status'];
    final expectedChecksum = data['checksum'];
    final bytesSent = data['bytes_sent'];
    
    print('[FILE_RECV] 📋 End frame received: status=$status, bytes=$bytesSent');
    
    if (status != 'success') {
      print('[FILE_RECV] ❌ Transfer failed on sender side');
      _safeOnError('Transfer failed: $status');
      resetReceiveState();  // ✅ FIX: Use public method
      return;
    }
    
    // Only finalize if we're in the right state
    if (_receiveState == TransferState.verifying || 
        _receiveState == TransferState.transferring) {
      
      // Verify checksum if provided
      if (expectedChecksum != null && _receivedData.isNotEmpty) {
        final actualChecksum = md5.convert(_receivedData).toString();
        print('[FILE_RECV] 🔐 Checksum verification:');
        print('[FILE_RECV]   Expected: $expectedChecksum');
        print('[FILE_RECV]   Actual:   $actualChecksum');
        
        if (actualChecksum != expectedChecksum) {
          print('[FILE_RECV] ❌ Checksum mismatch!');
          _safeOnError('File corrupted: Checksum verification failed');
          resetReceiveState();  // ✅ FIX: Use public method
          return;
        }
        
        print('[FILE_RECV] ✓ Checksum verified!');
      }
      
      _finalizeTransfer();
    } else {
      print('[FILE_RECV] ⚠️ Ignoring end frame - wrong state: $_receiveState');
    }
  }
  
  /// Finalize transfer with verification
  Future<void> _finalizeTransfer() async {
    if (_isDisposed) return;
    
    if (_receiveState == TransferState.complete || 
        _receiveState == TransferState.idle) {
      print('[FILE_RECV] Already finalized or idle, skipping');
      return;
    }
    
    _receiveState = TransferState.complete;
    
    try {
      // Close file
      await _fileSink?.flush();
      await _fileSink?.close();
      _fileSink = null;
      
      if (_isDisposed) return;
      
      final fileName = _currentTransferMetadata?['file_name'] ?? 'unknown';
      final filePath = _currentFilePath ?? '';
      
      // Verify file exists and size matches
      final file = File(filePath);
      if (!await file.exists()) {
        print('[FILE_RECV] ❌ File does not exist after write!');
        _safeOnError('File save failed: File not created');
        resetReceiveState();  // ✅ FIX: Use public method
        return;
      }
      
      final actualSize = await file.length();
      
      if (_isDisposed) return;
      
      if (actualSize != _expectedBytes) {
        print('[FILE_RECV] ⚠️ Size mismatch: expected $_expectedBytes, got $actualSize');
        
        // Small size differences (< 1%) might be OK due to buffering
        final difference = (_expectedBytes - actualSize).abs();
        final percentDiff = (difference / _expectedBytes) * 100;
        
        if (percentDiff > 1.0) {
          print('[FILE_RECV] ❌ Size difference too large (${percentDiff.toStringAsFixed(2)}%)');
          _safeOnError('File incomplete: expected $_expectedBytes bytes, got $actualSize');
          await file.delete();
          resetReceiveState();  // ✅ FIX: Use public method
          return;
        } else {
          print('[FILE_RECV] ⚠️ Minor size difference (${percentDiff.toStringAsFixed(2)}%), accepting');
        }
      }
      
      print('[FILE_RECV] ✅ Transfer complete: $fileName');
      print('[FILE_RECV]    Size: $actualSize bytes');
      print('[FILE_RECV]    Path: $filePath');
      
      _safeOnComplete(fileName, filePath, false);  // ✅ FIX: Pass false for receiver
      resetReceiveState();  // ✅ FIX: Use public method
      
    } catch (e, stackTrace) {
      print('[FILE_RECV] ❌ Finalization error: $e');
      if (kDebugMode) print('[FILE_RECV] Stack trace: $stackTrace');
      _safeOnError('Failed to save file: $e');
      resetReceiveState();  // ✅ FIX: Use public method
    }
  }
  
  /// Handle transfer timeout
  void _handleTransferTimeout() {
    if (_isDisposed) return;
    
    print('[FILE_RECV] ⏱️ Transfer timed out after $TRANSFER_TIMEOUT_SECONDS seconds');
    print('[FILE_RECV]    Received: $_receivedBytes/$_expectedBytes bytes');
    
    _safeOnError('Transfer timed out after $TRANSFER_TIMEOUT_SECONDS seconds');
    resetReceiveState();  // ✅ FIX: Use public method
  }
  
  /// Reset receive state with proper cleanup - ✅ FIX: Made public
  void resetReceiveState() {
    print('[FILE_RECV] 🔄 Resetting state (was: $_receiveState)');
    
    _receiveTimeout?.cancel();
    _receiveTimeout = null;
    
    // Close file sink safely
    try {
      _fileSink?.close();
    } catch (e) {
      print('[FILE_RECV] Error closing file sink: $e');
    }
    _fileSink = null;
    
    _receiveState = TransferState.idle;
    _currentTransferMetadata = null;
    _currentFilePath = null;
    _receivedBytes = 0;
    _expectedBytes = 0;
    _receivedData = [];
  }
  
  /// Dispose handler - CRITICAL for preventing crashes
  void dispose() {
    print('[FILE_RECV] 🗑️ Disposing handler');
    
    _isDisposed = true;
    
    _receiveTimeout?.cancel();
    _receiveTimeout = null;
    
    try {
      _fileSink?.close();
    } catch (e) {
      print('[FILE_RECV] Error closing file sink during dispose: $e');
    }
    _fileSink = null;
    
    _operationController.close();
    
    resetReceiveState(); 
  }
}