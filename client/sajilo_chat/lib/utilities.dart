import 'dart:async';
import 'dart:io';

class SocketWrapper {
  final Socket _socket;
  late final StreamController<List<int>> _controller;
  StreamSubscription? _subscription;
  
  SocketWrapper(this._socket) {
    _controller = StreamController<List<int>>.broadcast();
    
    _subscription = _socket.listen(
      (data) => _controller.add(data),
      onError: (error) => _controller.addError(error),
      onDone: () => _controller.close(),
      cancelOnError: false,
    );
  }
  
  Stream<List<int>> get stream => _controller.stream;
  
  Socket get socket => _socket;
  
  void write(List<int> data) {
    _socket.add(data);
  }
  
  Future<void> flush() async {
    await _socket.flush();
  }
  
  void close() {
    _subscription?.cancel();
    _controller.close();
    _socket.close();
  }
}