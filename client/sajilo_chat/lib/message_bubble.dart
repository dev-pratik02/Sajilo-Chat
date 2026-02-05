import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class MessageBubble extends StatelessWidget {
  final String message;
  final bool isMe;
  final String sender;
  final bool showSender;
  final bool isFile;
  final String? fileName;
  final String? filePath;
  final VoidCallback? onFileTap;
  final bool isGroupChat; // ✨ NEW: Distinguish group vs DM
  final Color bubbleColor; // ✨ NEW: Custom bubble color

  const MessageBubble({
    super.key, 
    required this.message,
    required this.isMe,
    required this.sender,
    required this.showSender,
    this.isFile = false,
    this.fileName,
    this.filePath,
    this.onFileTap,
    this.isGroupChat = false, // ✨ NEW
    this.bubbleColor = const Color(0xFF6C63FF), // ✨ NEW
  });

  @override
  Widget build(BuildContext context) {
    // ✨ Distinct colors for group chat vs DM
    final Color myBubbleColor = isGroupChat 
        ? Color(0xFFE3E0FF)  // Light purple for my group messages
        : Color(0xFFD5D0FF);  // Slightly different purple for my DMs
    
    final Color otherBubbleColor = Colors.white;
    
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        child: Column(
          crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Sender name (for group chats when showing other users)
            if (showSender)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, left: 12, right: 12),
                child: Text(
                  sender,
                  style: GoogleFonts.poppins(
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                    color: bubbleColor,
                  ),
                ),
              ),
            
            // Message bubble
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: isMe ? myBubbleColor : otherBubbleColor,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(20),
                  topRight: const Radius.circular(20),
                  bottomLeft: isMe ? const Radius.circular(20) : const Radius.circular(4),
                  bottomRight: isMe ? const Radius.circular(4) : const Radius.circular(20),
                ),
                boxShadow: [
                  BoxShadow(
                    color: isMe 
                        ? bubbleColor.withOpacity(0.15)
                        : Colors.black.withOpacity(0.05),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
                // ✨ Subtle gradient for my messages
                gradient: isMe ? LinearGradient(
                  colors: [
                    myBubbleColor,
                    myBubbleColor.withOpacity(0.9),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ) : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // File message with tap functionality
                  if (isFile)
                    InkWell(
                      onTap: onFileTap,
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isMe 
                              ? Colors.white.withOpacity(0.5)
                              : bubbleColor.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                color: bubbleColor.withOpacity(0.15),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.insert_drive_file_rounded,
                                size: 24,
                                color: bubbleColor,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    fileName ?? message,
                                    style: GoogleFonts.poppins(
                                      fontSize: 14,
                                      color: bubbleColor,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.download_rounded,
                                        size: 14,
                                        color: Colors.grey[600],
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        'Tap to open',
                                        style: GoogleFonts.poppins(
                                          fontSize: 11,
                                          color: Colors.grey[600],
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
                    )
                  else
                    // Regular text message
                    Text(
                      message,
                      style: GoogleFonts.poppins(
                        fontSize: 15,
                        color: isMe ? Color(0xFF2D2D2D) : Colors.black87,
                        height: 1.4,
                      ),
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