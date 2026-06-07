import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_service.dart';
import '../discovery/discovery_service.dart';

class SenderScreen extends StatefulWidget {
  const SenderScreen({super.key});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  final _service = AudioService();
  final _discovery = DiscoveryService();
  final _hostCtrl = TextEditingController();
  final _portCtrl = TextEditingController(text: '7355');
  StreamSubscription<Map<Object?, Object?>>? _metricsSub;
  StreamSubscription<DiscoveredReceiver>? _discSub;

  bool _streaming = false;
  bool _connecting = false;
  bool _userStopped = false;   // after a manual Stop, don't auto-reconnect
  bool _showManual = false;
  String _status = 'Ready';
  int _packetsSent = 0;
  String _myIp = 'loading…';
  DiscoveredReceiver? _receiver;
  String? _ipError;
  String? _portError;

  static const _ipPattern = r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$';

  @override
  void initState() {
    super.initState();
    _loadIp();
    _startDiscovery();
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

  Future<void> _startDiscovery() async {
    try {
      await _discovery.start();
      _discSub = _discovery.receivers.listen(_onReceiverFound);
    } catch (_) {
      if (mounted) setState(() => _showManual = true);
    }
  }

  void _onReceiverFound(DiscoveredReceiver r) {
    final isNew = _receiver?.host != r.host || _receiver?.port != r.port;
    _receiver = r;
    if (!_streaming && !_userStopped && !_connecting) {
      _connect(r);                       // zero-config auto-connect
    } else if (isNew && mounted) {
      setState(() {});                   // refresh the "found" banner
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('SocketException') || msg.contains('NetworkUnreachable')) {
      return "Can't reach the receiver. Check Wi-Fi.";
    }
    if (msg.toLowerCase().contains('permission')) {
      return 'Microphone permission required.';
    }
    return 'Something went wrong. Try again.';
  }

  Future<void> _connect(DiscoveredReceiver r) async {
    if (_connecting || _streaming) return;
    setState(() => _connecting = true);

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      setState(() {
        _connecting = false;
        _userStopped = true;
        _status = 'Microphone permission denied';
      });
      return;
    }

    try {
      await _service.startStreaming(host: r.host, port: r.port);
      await WakelockPlus.enable();
      setState(() {
        _streaming = true;
        _connecting = false;
        _packetsSent = 0;
        _status = 'Connected to ${r.name}';
      });
    } on Exception catch (e) {
      setState(() {
        _connecting = false;
        _status = _friendlyError(e);
      });
    }
  }

  Future<void> _stop() async {
    await _service.stopStreaming();
    await WakelockPlus.disable();
    setState(() {
      _streaming = false;
      _userStopped = true;            // wait for an explicit Start before reconnecting
      _status = 'Stopped';
      _packetsSent = 0;
    });
  }

  void _onMainButton() {
    if (_streaming) {
      _stop();
    } else if (_receiver != null) {
      setState(() => _userStopped = false);
      _connect(_receiver!);
    }
  }

  Future<void> _connectManual() async {
    final host = _hostCtrl.text.trim();
    if (!RegExp(_ipPattern).hasMatch(host)) {
      setState(() => _ipError = 'Enter a valid IPv4 (e.g. 192.168.1.100)');
      return;
    }
    final port = int.tryParse(_portCtrl.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _portError = 'Port must be 1–65535');
      return;
    }
    setState(() {
      _ipError = null;
      _portError = null;
      _userStopped = false;
    });
    await _connect(DiscoveredReceiver(host: host, port: port, name: host));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('EVERMIC'),
        backgroundColor: cs.surfaceContainerHighest,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
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
              const SizedBox(height: 20),
              _DiscoveryBanner(
                streaming: _streaming,
                connecting: _connecting,
                receiver: _receiver,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: (_streaming || _receiver != null) && !_connecting
                    ? _onMainButton
                    : null,
                icon: Icon(_streaming ? Icons.stop : Icons.mic),
                label: Text(
                  _streaming
                      ? 'Stop Streaming'
                      : _receiver != null
                          ? 'Start Streaming'
                          : 'Searching…',
                ),
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor:
                      _streaming ? Colors.red.shade700 : Colors.green.shade700,
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => setState(() => _showManual = !_showManual),
                child: Text(_showManual ? 'Hide manual setup' : 'Connect manually'),
              ),
              if (_showManual) _buildManual(),
              const SizedBox(height: 12),
              Text(
                'Both devices must be on the same Wi-Fi.\nThe app finds the receiver automatically.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildManual() {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _hostCtrl,
            enabled: !_streaming,
            decoration: InputDecoration(
              labelText: 'Receiver IP Address',
              hintText: '192.168.1.100',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.computer),
              errorText: _ipError,
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portCtrl,
            enabled: !_streaming,
            decoration: InputDecoration(
              labelText: 'UDP Port',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.settings_ethernet),
              errorText: _portError,
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _streaming ? null : _connectManual,
            child: const Text('Connect'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _metricsSub?.cancel();
    _discSub?.cancel();
    _discovery.dispose();
    _hostCtrl.dispose();
    _portCtrl.dispose();
    super.dispose();
  }
}

class _DiscoveryBanner extends StatelessWidget {
  const _DiscoveryBanner({
    required this.streaming,
    required this.connecting,
    required this.receiver,
  });

  final bool streaming;
  final bool connecting;
  final DiscoveredReceiver? receiver;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget content;
    if (streaming && receiver != null) {
      content = Text('Connected to ${receiver!.name}',
          style: TextStyle(color: Colors.greenAccent));
    } else if (connecting) {
      content = const _SpinnerRow(text: 'Connecting…');
    } else if (receiver != null) {
      content = Text(
        'Found ${receiver!.name}  ·  ${receiver!.host}',
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onSurface),
      );
    } else {
      content = const _SpinnerRow(text: 'Searching for a receiver on Wi-Fi…');
    }
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Center(child: content),
    );
  }
}

class _SpinnerRow extends StatelessWidget {
  const _SpinnerRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Flexible(child: Text(text, textAlign: TextAlign.center)),
      ],
    );
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
          ? Colors.green.shade900.withValues(alpha: 0.6)
          : Colors.grey.shade900.withValues(alpha: 0.4),
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
