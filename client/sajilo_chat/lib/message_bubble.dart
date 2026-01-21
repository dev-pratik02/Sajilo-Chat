import 'package:flutter/material.dart';


class MessageBubble extends StatelessWidget {
  final String message;
  final bool isMe;
  final String sender;
  final bool showSender;
  final bool isFile; // NEW: Flag for file messages
  final String? fileName; // NEW: File name for file messages

  const MessageBubble({
    super.key, 
    required this.message,
    required this.isMe,
    required this.sender,
    required this.showSender,
    this.isFile = false, // NEW: Default to false
    this.fileName, // NEW: Optional file name
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFFDCF8C6) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: isMe ? const Radius.circular(12) : const Radius.circular(0),
            bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(12),
          ),
          boxShadow: const [
            BoxShadow(
              color: Colors.black12,
              blurRadius: 2,
              offset: Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showSender)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  '',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Color(0xFF075E54),
                  ),
                ),
              ),
            if (showSender)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  sender,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Color(0xFF075E54),
                  ),
                ),
              ),
            
            // NEW: File message styling
            if (isFile)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file, size: 20, color: Colors.blue),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      fileName ?? message,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.blue,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
                ],
              )
            // EXISTING: Text message styling
            else
              Text(
                message,
                style: const TextStyle(fontSize: 16, color: Colors.black87),
              ),
          ],
        ),
      ),
    );
  }
}