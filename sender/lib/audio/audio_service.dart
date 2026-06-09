import 'package:flutter/services.dart';

class AudioService {
  static const _method = MethodChannel('com.wirelessmic/audio');
  static const _events = EventChannel('com.wirelessmic/audio_events');

  // Emits Map with keys: sequenceNumber (int), timestampMs (int)
  Stream<Map<Object?, Object?>> get metricsStream =>
      _events.receiveBroadcastStream().cast<Map<Object?, Object?>>();

  Future<void> startStreaming({required String host, required int port}) {
    return _method.invokeMethod('start', {'host': host, 'port': port});
  }

  Future<void> stopStreaming() {
    return _method.invokeMethod('stop');
  }

  Future<void> startDj({required String host, required int port}) {
    return _method.invokeMethod('startDj', {'host': host, 'port': port});
  }
}
