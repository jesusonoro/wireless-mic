import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import '../audio/audio_service.dart';

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final _service = AudioService();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '7355');
  StreamSubscription<Map<Object?, Object?>>? _metricsSub;

  bool _streaming = false;
  String _status = 'Ready';
  int _packetsSent = 0;
  String _myIp = 'loading…';

  @override
  void initState() {
    super.initState();
    _loadIp();
    _metricsSub = _service.metricsStream.listen((m) {
      if (!mounted) return;
      setState(() {
        _packetsSent = (m['sequenceNumber'] as int?) ?? _packetsSent;
      });
    });
  }

  Future<void> _loadIp() async {
    final ip = await NetworkInfo().getWifiIP();
    if (mounted) setState(() => _myIp = ip ?? 'unknown');
  }

  Future<void> _toggle() async {
    if (_streaming) {
      await _service.stopStreaming();
      setState(() {
        _streaming = false;
        _status = 'Stopped';
      });
      return;
    }

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      setState(() => _status = 'Microphone permission denied');
      return;
    }

    final host = _hostCtrl.text.trim();
    if (host.isEmpty) {
      setState(() => _status = 'Enter the receiver IP address');
      return;
    }
    final port = int.tryParse(_portCtrl.text) ?? 7355;

    try {
      await _service.startStreaming(host: host, port: port);
      setState(() {
        _streaming = true;
        _packetsSent = 0;
        _status = 'Streaming to $host:$port';
      });
    } on Exception catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('Wireless Microphone'),
        backgroundColor: cs.surfaceContainerHighest,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(streaming: _streaming, status: _status, packets: _packetsSent),
              const SizedBox(height: 12),
              Text(
                'Phone Wi-Fi IP: $_myIp',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _hostCtrl,
                enabled: !_streaming,
                decoration: const InputDecoration(
                  labelText: 'Receiver IP Address',
                  hintText: '192.168.1.100',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.computer),
                ),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _portCtrl,
                enabled: !_streaming,
                decoration: const InputDecoration(
                  labelText: 'UDP Port',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.settings_ethernet),
                ),
                keyboardType: TextInputType.number,
              ),
              const SizedBox(height: 28),
              FilledButton.icon(
                onPressed: _toggle,
                icon: Icon(_streaming ? Icons.stop : Icons.mic),
                label: Text(_streaming ? 'Stop Streaming' : 'Start Streaming'),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: _streaming ? Colors.red.shade700 : Colors.green.shade700,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Keep screen on while streaming.\nBoth devices must be on the same Wi-Fi.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _metricsSub?.cancel();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.streaming,
    required this.status,
    required this.packets,
  });

  final bool streaming;
  final String status;
  final int packets;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: streaming
          ? Colors.green.shade900.withOpacity(0.6)
          : Colors.grey.shade900.withOpacity(0.4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              streaming ? Icons.mic : Icons.mic_off,
              size: 56,
              color: streaming ? Colors.greenAccent : Colors.grey,
            ),
            const SizedBox(height: 8),
            Text(status, textAlign: TextAlign.center),
            if (streaming) ...[
              const SizedBox(height: 4),
              Text(
                '$packets packets sent  ·  ${(packets * 10 / 1000).toStringAsFixed(1)}s',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
