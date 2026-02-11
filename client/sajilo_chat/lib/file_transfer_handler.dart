import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class FileTransferHandler {
  final Function(double) onProgress;
  final Function(String fileName, String filePath) onComplete;
  final Function(String) onError;
  
  // State for receiving files
  bool _isReceivingFile = false;
  Map<String, dynamic>? _currentTransferMetadata;
  IOSink? _fileSink;
  String? _currentFilePath;
  int _receivedBytes = 0;
  int _expectedBytes = 0; 
  
  FileTransferHandler({
    required this.onProgress,
    required this.onComplete,
    required this.onError,
  });
  
  bool get isReceivingFile => _isReceivingFile;
  
  //stream file to the receiver
  
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
      
      //Sends only the metadata first
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
      
      //  Longer delay to ensure metadata is processed
      await Future.delayed(const Duration(milliseconds: 200));
      
      // Stream file chunks (raw binary)
      final stream = file.openRead();
      int bytesSent = 0;
      
      await for (final chunk in stream) {
        socket.add(chunk);
        bytesSent += chunk.length;
        onProgress(bytesSent / fileSize);
        
        //  Small delay between chunks to prevent buffer overflow
        if (bytesSent % (BufferSize * 10) == 0) {
          await Future.delayed(const Duration(milliseconds: 10));
        }
      }
      
      await socket.flush();
      
      // Longer delay before end frame
      await Future.delayed(const Duration(milliseconds: 200));
      
      
      
      print('[FILE_SEND] ✓ Completed: $fileName ($bytesSent bytes)');
      onComplete(fileName, ''); // Empty path for sender
      
    } catch (e) {
      print('[FILE_SEND] ✗ Error: $e');
      onError('Failed to send file: $e');
    }
  }
  
  static const int BufferSize = 4096;
  
  //FOR THE RECEIVING ENDDD

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
      
      //   FIX #5: Check if we can write to this location
      try {
        await file.create(recursive: true);
      } catch (e) {
        print('[FILE_RECV] ✗ Cannot create file: $e');
        onError('Cannot save file: No permission');
        return;
      }
      
      _isReceivingFile = true;
      _currentTransferMetadata = metadata;
      _currentFilePath = filePath;
      _fileSink = file.openWrite();
      _receivedBytes = 0;
      _expectedBytes = fileSize;  //   FIX #6: Store expected size
      
      print('[FILE_RECV] Saving to: $filePath');
      onProgress(0.0);
      
    } catch (e) {
      print('[FILE_RECV] ✗ Setup error: $e');
      onError('Failed to prepare file: $e');
      _resetReceiveState();
    }
  }
  
  //INCOMING CHUNK HANDLER

  void handleIncomingChunk(List<int> chunk) {
    if (!_isReceivingFile || _fileSink == null) {
      print('[FILE_RECV] ⚠️ Received chunk but not in receive mode');
      return;
    }
    
 
    
    try {
      // Calculate how much bytes still needed as compared to expected size
      final remaining = _expectedBytes - _receivedBytes;
      
      if (remaining <= 0) {
        // After getting all the bytes, this must be the end frame
        print('[FILE_RECV] Received end frame');
        return;
      }
      
      // Determine how much of this chunk is file data
      final bytesToWrite = chunk.length <= remaining ? chunk.length : remaining;
      
      // Write only the file portion
      if (bytesToWrite > 0) {
        _fileSink!.add(chunk.sublist(0, bytesToWrite));
        _receivedBytes += bytesToWrite;
        
        // Update progress
        onProgress(_receivedBytes / _expectedBytes);
        
        // Log progress
        if (_receivedBytes % (BufferSize * 25) == 0 || _receivedBytes >= _expectedBytes) {
          final pct = ((_receivedBytes / _expectedBytes) * 100).toInt();
          print('[FILE_RECV] Progress: $_receivedBytes/$_expectedBytes bytes ($pct%)');
        }
      }
      
      //   Checking completion by byte count, not end frame detection
      if (_receivedBytes >= _expectedBytes) {
        print('[FILE_RECV] All bytes received, finalizing...');
        _finalizeTransfer();
      }
      
    } catch (e) {
      print('[FILE_RECV] ✗ Error writing chunk: $e');
      onError('Failed to write file: $e');
      _resetReceiveState();
    }
  }
  
 //FOR THE END OF TRANSFER

  void handleTransferEnd(Map<String, dynamic> data) {
    final status = data['status'];
    print('[FILE_RECV] Received end frame: status=$status');
    
    if (status == 'success') {
      // Only finalize if we haven't already
      if (_isReceivingFile) {
        _finalizeTransfer();
      }
    } else {
      onError('Transfer failed on server');
      _resetReceiveState();
    }
  }
  
  Future<void> _finalizeTransfer() async {
    if (!_isReceivingFile) return;
    
    try {
      await _fileSink?.flush();
      await _fileSink?.close();
      
      final fileName = _currentTransferMetadata?['file_name'] ?? 'unknown';
      final filePath = _currentFilePath ?? '';
      
      //  Verify file was saved correctly
      final file = File(filePath);
      final actualSize = await file.length();
      
      if (actualSize != _expectedBytes) {
        print('[FILE_RECV] ⚠️ Size mismatch: expected $_expectedBytes, got $actualSize');
        onError('File incomplete: expected $_expectedBytes bytes, got $actualSize');
        await file.delete();
        _resetReceiveState();
        return;
      }
      
      print('[FILE_RECV] ✓ Completed: $fileName ($_receivedBytes bytes)');
      print('[FILE_RECV] Saved to: $filePath');
      print('[FILE_RECV] Verified: $actualSize bytes on disk');
      
      onComplete(fileName, filePath);
      _resetReceiveState();
      
    } catch (e) {
      print('[FILE_RECV] ✗ Finalization error: $e');
      onError('Failed to save file: $e');
      _resetReceiveState();
    }
  }
  
  void _resetReceiveState() {
    _isReceivingFile = false;
    _currentTransferMetadata = null;
    _currentFilePath = null;
    _fileSink = null;
    _receivedBytes = 0;
    _expectedBytes = 0;
  }
  
  void dispose() {
    _fileSink?.close();
    _resetReceiveState();
  }
}