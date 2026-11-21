import 'web_storage.dart';

class _StubWebStorage implements WebStorage {
  @override
  String? read(String key) => null;

  @override
  bool write(String key, String value) => true;

  @override
  void remove(String key) {}
}

WebStorage createWebStorage() => _StubWebStorage();
