import 'dart:async';
import 'dart:convert';
import 'package:sajilo_chat/utilities.dart';

/// Manages chat history loading and caching
class ChatHistoryHandler {
  final SocketWrapper socket;
  final String username;
  
  // Cache for loaded histories
  final Map<String, List<Map<String, dynamic>>> _historyCache = {};
  final Map<String, bool> _loadingStates = {};
  
  // Track when history was last loaded
  final Map<String, DateTime> _lastLoadTime = {};
  
  ChatHistoryHandler({
    required this.socket,
    required this.username,
  });
  
  /// Request chat history from server
  /// forceReload: if true, ignores cache and always requests from server
  Future<void> requestHistory(String chatWith, {bool forceReload = false}) async {
    // Check if already actively loading (prevent duplicate simultaneous requests)
    if (_loadingStates[chatWith] == true) {
      print('[ChatHistory] Already loading history for $chatWith');
      return;
    }
    
    // Check if we should use cached data (loaded within last 30 seconds)
    if (!forceReload && _lastLoadTime.containsKey(chatWith)) {
      final timeSinceLoad = DateTime.now().difference(_lastLoadTime[chatWith]!);
      if (timeSinceLoad.inSeconds < 30) {
        print('[ChatHistory] Using cached history for $chatWith (${timeSinceLoad.inSeconds}s old)');
        return;
      }
    }
    
    _loadingStates[chatWith] = true;
    print('[ChatHistory] Requesting history for $chatWith ${forceReload ? "(force reload)" : ""}');
    
    final request = jsonEncode({
      'type': 'request_history',
      'chat_with': chatWith,
    }) + '\n';
    
    socket.write(utf8.encode(request));
  }
  
  /// Process incoming history data
  List<Map<String, dynamic>> processHistoryData(Map<String, dynamic> data) {
    final chatWith = data['chat_with'] as String;
    final messages = data['messages'] as List;
    
    final processedMessages = <Map<String, dynamic>>[];
    
    for (var msg in messages) {
      processedMessages.add({
        'from': msg['from'],
        'message': msg['message'],
        'isMe': msg['from'] == username,
        'timestamp': msg['timestamp'],
        'type': msg['type'],
      });
    }
    
    // Cache the history and record load time
    _historyCache[chatWith] = processedMessages;
    _loadingStates[chatWith] = false;
    _lastLoadTime[chatWith] = DateTime.now();
    
    print('[ChatHistory] Loaded ${processedMessages.length} messages for $chatWith');
    return processedMessages;
  }
  
  /// Get cached history if available
  List<Map<String, dynamic>>? getCachedHistory(String chatWith) {
    return _historyCache[chatWith];
  }
  
  /// Check if history is currently loading
  bool isLoading(String chatWith) {
    return _loadingStates[chatWith] ?? false;
  }
  
  /// Clear cache for a specific chat (forces reload on next request)
  void clearCache(String chatWith) {
    _historyCache.remove(chatWith);
    _loadingStates.remove(chatWith);
    _lastLoadTime.remove(chatWith);
  }
  
  /// Clear all cached histories
  void clearAllCache() {
    _historyCache.clear();
    _loadingStates.clear();
    _lastLoadTime.clear();
  }
  
  /// Add a new message to cache
  void addMessageToCache(String chatWith, Map<String, dynamic> message) {
    if (_historyCache.containsKey(chatWith)) {
      _historyCache[chatWith]!.add(message);
      // Update last load time so cache stays fresh
      _lastLoadTime[chatWith] = DateTime.now();
    }
  }
  
  /// Reset loading state (call this if history request fails or times out)
  void resetLoadingState(String chatWith) {
    _loadingStates[chatWith] = false;
  }
}

/// Extension methods for message formatting
extension MessageFormatting on Map<String, dynamic> {
  /// Format message for display
  String getDisplayMessage() {
    final from = this['from'] as String;
    final message = this['message'] as String;
    final type = this['type'] as String;
    
    if (type == 'group') {
      return '$from: $message';
    }
    return message;
  }
  
  /// Get formatted timestamp
  String getFormattedTime() {
    final timestamp = this['timestamp'] as String?;
    if (timestamp == null) return 'Now';
    
    try {
      final dateTime = DateTime.parse(timestamp);
      final now = DateTime.now();
      final difference = now.difference(dateTime);
      
      if (difference.inMinutes < 1) {
        return 'Just now';
      } else if (difference.inHours < 1) {
        return '${difference.inMinutes}m ago';
      } else if (difference.inDays < 1) {
        return '${difference.inHours}h ago';
      } else if (difference.inDays < 7) {
        return '${difference.inDays}d ago';
      } else {
        return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
      }
    } catch (e) {
      return 'Now';
    }
  }
}
