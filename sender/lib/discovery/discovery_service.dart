import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

/// A receiver found on the LAN via its broadcast beacon.
class DiscoveredReceiver {
  const DiscoveredReceiver({
    required this.host,
    required this.port,
    required this.name,
  });

  final String host;
  final int port;
  final String name;
}

/// Listens for EVERMIC receiver beacons so the sender connects with zero config.
///
/// The desktop receiver broadcasts to 255.255.255.255:[discoveryPort] every
/// second. Beacon layout: "EVERMIC1" (8 bytes) + audio port (uint16 BE) +
/// name length (uint8) + UTF-8 name.
class DiscoveryService {
  static const int discoveryPort = 7356;
  static const List<int> _magic = [69, 86, 69, 82, 77, 73, 67, 49]; // "EVERMIC1"
  static const MethodChannel _control = MethodChannel('com.wirelessmic/audio');

  RawDatagramSocket? _socket;
  final _controller = StreamController<DiscoveredReceiver>.broadcast();

  /// Emits each time a beacon is received (roughly once per second per receiver).
  Stream<DiscoveredReceiver> get receivers => _controller.stream;

  Future<void> start() async {
    if (_socket != null) return;
    // Hold a multicast lock so Wi-Fi doesn't filter inbound broadcast beacons.
    try {
      await _control.invokeMethod('acquireMulticastLock');
    } catch (_) {/* not on Android, or already held — ignore */}
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      discoveryPort,
      reuseAddress: true,
    );
    _socket = socket;
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final dg = socket.receive();
      if (dg == null) return;
      final r = _parse(dg.data, dg.address.address);
      if (r != null) _controller.add(r);
    });
  }

  DiscoveredReceiver? _parse(List<int> d, String sourceIp) {
    if (d.length < 11) return null;
    for (var i = 0; i < 8; i++) {
      if (d[i] != _magic[i]) return null;
    }
    final port = (d[8] << 8) | d[9];
    final nameLen = d[10];
    final name = d.length >= 11 + nameLen
        ? utf8.decode(d.sublist(11, 11 + nameLen), allowMalformed: true)
        : sourceIp;
    return DiscoveredReceiver(host: sourceIp, port: port, name: name);
  }

  void stop() {
    _socket?.close();
    _socket = null;
    _control.invokeMethod('releaseMulticastLock').catchError((_) {});
  }

  void dispose() {
    stop();
    _controller.close();
  }
}
