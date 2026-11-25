import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The app's one switch for network use: Settings → Offline mode.
///
/// Stores that work in the background (hazard sync, the map server's index)
/// read [online] to pause politely and listen to resume. As a backstop,
/// every HTTP client in the app is a [GatedClient], which refuses requests
/// while offline. So "offline mode uses no network" holds even for a code
/// path that forgets to check, including ones added later.
class NetworkGate extends ChangeNotifier {
  // A named parameter can't be private, so it can't initialise _online
  // directly.
  // ignore: prefer_initializing_formals
  NetworkGate({bool online = true}) : _online = online;

  bool _online;

  /// False in offline mode.
  bool get online => _online;
  set online(bool value) {
    if (value == _online) return;
    _online = value;
    notifyListeners();
  }
}

/// Thrown instead of making a request while the app is in offline mode.
class OfflineModeException implements Exception {
  const OfflineModeException();

  @override
  String toString() => 'Offline mode is on';
}

/// An [http.Client] that only reaches the network while [gate] is online.
class GatedClient extends http.BaseClient {
  GatedClient(this.gate, [http.Client? inner]) : _inner = inner ?? http.Client();

  final NetworkGate gate;
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (!gate.online) return Future.error(const OfflineModeException());
    return _inner.send(request);
  }

  @override
  void close() => _inner.close();
}
