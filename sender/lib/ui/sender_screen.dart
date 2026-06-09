import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_service.dart';
import '../discovery/discovery_service.dart';

enum CaptureMode { mic, dj }

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
  String _status = 'Listo';
  int _packetsSent = 0;
  double _level = 0;           // input level 0..1 for the VU meter
  String _myIp = 'cargando…';
  DiscoveredReceiver? _receiver;
  String? _ipError;
  String? _portError;
  CaptureMode _mode = CaptureMode.mic;

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
        _level = (m['level'] as num?)?.toDouble() ?? _level;
      });
    });
  }

  Future<void> _loadIp() async {
    final ip = await NetworkInfo().getWifiIP();
    if (mounted) setState(() => _myIp = ip ?? 'desconocida');
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
    // Only auto-connect in MIC mode. In DJ mode the user must press Start
    // explicitly — auto-connecting would fire the system screen-capture consent
    // dialog without any user gesture, which is intrusive.
    if (_mode == CaptureMode.mic && !_streaming && !_userStopped && !_connecting) {
      _connect(r);                       // zero-config auto-connect (mic only)
    } else if (isNew && mounted) {
      setState(() {});                   // refresh the "found" banner
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('SocketException') || msg.contains('NetworkUnreachable')) {
      return 'No se encuentra el receptor. Revisa el Wi-Fi.';
    }
    if (msg.toLowerCase().contains('permission')) {
      return 'Se requiere permiso de micrófono.';
    }
    return 'Algo salió mal. Inténtalo de nuevo.';
  }

  Future<void> _connect(DiscoveredReceiver r) async {
    if (_connecting || _streaming) return;
    setState(() => _connecting = true);

    final granted = await Permission.microphone.request();
    if (!granted.isGranted) {
      setState(() {
        _connecting = false;
        _userStopped = true;
        _status = 'Permiso de micrófono denegado';
      });
      return;
    }

    try {
      if (_mode == CaptureMode.dj) {
        await _service.startDj(host: r.host, port: r.port);
        // startDj returns before the system consent dialog resolves; streaming
        // state is optimistic. If the user denies screen capture no packets will
        // arrive (counter stays 0) and they can Stop and retry.
        await WakelockPlus.enable();
        setState(() {
          _streaming = true;
          _connecting = false;
          _packetsSent = 0;
          _status = 'Iniciando DJ — acepta el permiso de captura de pantalla';
        });
      } else {
        await _service.startStreaming(host: r.host, port: r.port);
        await WakelockPlus.enable();
        setState(() {
          _streaming = true;
          _connecting = false;
          _packetsSent = 0;
          _status = 'Conectado a ${r.name}';
        });
      }
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
      _status = 'Detenido';
      _packetsSent = 0;
      _level = 0;
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
      setState(() => _ipError = 'Introduce una IPv4 válida (ej. 192.168.1.100)');
      return;
    }
    final port = int.tryParse(_portCtrl.text);
    if (port == null || port < 1 || port > 65535) {
      setState(() => _portError = 'El puerto debe estar entre 1 y 65535');
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
    final isDj = _mode == CaptureMode.dj;
    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: const Text('EVERDJ'),
        backgroundColor: cs.surfaceContainerHighest,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(
                streaming: _streaming,
                status: _status,
                packets: _packetsSent,
                mode: _mode,
              ),
              const SizedBox(height: 12),
              Text(
                'IP del teléfono: $_myIp',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              _DiscoveryBanner(
                streaming: _streaming,
                connecting: _connecting,
                receiver: _receiver,
              ),
              if (_streaming) ...[
                const SizedBox(height: 16),
                _MicLevel(
                  level: _level,
                  label: isDj ? 'SALIDA' : 'ENTRADA MIC',
                  hint: isDj ? 'pon música y habla…' : 'habla al teléfono…',
                ),
              ],
              const SizedBox(height: 16),
              // Mode toggle — disabled while streaming or connecting
              SegmentedButton<CaptureMode>(
                segments: const [
                  ButtonSegment(
                    value: CaptureMode.mic,
                    icon: Icon(Icons.mic),
                    label: Text('Micrófono'),
                  ),
                  ButtonSegment(
                    value: CaptureMode.dj,
                    icon: Icon(Icons.album),
                    label: Text('DJ'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (_streaming || _connecting)
                    ? null
                    : (s) => setState(() => _mode = s.first),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: (_streaming || _receiver != null) && !_connecting
                    ? _onMainButton
                    : null,
                icon: Icon(_streaming ? Icons.stop : (isDj ? Icons.album : Icons.mic)),
                label: Text(
                  _streaming
                      ? (isDj ? 'Detener DJ' : 'Detener')
                      : _receiver != null
                          ? (isDj ? 'Empezar DJ' : 'Empezar')
                          : 'Buscando…',
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
                child: Text(_showManual ? 'Ocultar conexión manual' : 'Conexión manual'),
              ),
              if (_showManual) _buildManual(),
              const SizedBox(height: 12),
              Text(
                'Ambos dispositivos deben estar en la misma red Wi-Fi.\nLa app encuentra el receptor automáticamente.',
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
              labelText: 'IP del receptor',
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
              labelText: 'Puerto UDP',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.settings_ethernet),
              errorText: _portError,
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _streaming ? null : _connectManual,
            child: const Text('Conectar'),
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
      content = Text('Conectado a ${receiver!.name}',
          style: const TextStyle(color: Colors.greenAccent));
    } else if (connecting) {
      content = const _SpinnerRow(text: 'Conectando…');
    } else if (receiver != null) {
      content = Text(
        'Encontrado ${receiver!.name}  ·  ${receiver!.host}',
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onSurface),
      );
    } else {
      content = const _SpinnerRow(text: 'Buscando un receptor en la red…');
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

/// Segmented input-level meter (VU style) with peak-hold.
///
/// Fed by the `level` field of the metrics stream (~20 Hz while streaming).
/// Uses a perceptual sqrt curve so normal speech lights a useful range, fast
/// attack so transients show instantly, and slow release + a peak dot so the
/// motion reads cleanly.
class _MicLevel extends StatefulWidget {
  const _MicLevel({
    required this.level,
    required this.label,
    required this.hint,
  });
  final double level;
  final String label;
  final String hint;

  @override
  State<_MicLevel> createState() => _MicLevelState();
}

class _MicLevelState extends State<_MicLevel> {
  static const _segments = 28;
  double _smooth = 0;
  double _peak = 0;

  @override
  void didUpdateWidget(covariant _MicLevel old) {
    super.didUpdateWidget(old);
    final shaped = math.sqrt(widget.level.clamp(0.0, 1.0));
    // Fast attack (jump up), slow release (ease down). build() runs right after.
    _smooth = shaped > _smooth ? shaped : _smooth * 0.72 + shaped * 0.28;
    _peak = shaped > _peak ? shaped : _peak * 0.90;
  }

  Color _zone(double frac) {
    if (frac < 0.60) return Colors.greenAccent;
    if (frac < 0.85) return Colors.amber;
    return Colors.redAccent;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final active = (_smooth * _segments).round();
    final peakIdx = (_peak * _segments).clamp(0, _segments - 1).round();
    final silent = _peak < 0.015;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.graphic_eq, size: 14, color: cs.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              widget.label,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: cs.onSurfaceVariant,
                    letterSpacing: 1.5,
                  ),
            ),
            const Spacer(),
            if (silent)
              Text(
                widget.hint,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 22,
          child: Row(
            children: List.generate(_segments, (i) {
              final frac = i / (_segments - 1);
              final color = _zone(frac);
              final lit = i < active || i == peakIdx;
              return Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(
                    color: lit ? color : color.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.streaming,
    required this.status,
    required this.packets,
    required this.mode,
  });

  final bool streaming;
  final String status;
  final int packets;
  final CaptureMode mode;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    if (mode == CaptureMode.dj) {
      icon = streaming ? Icons.album : Icons.album_outlined;
    } else {
      icon = streaming ? Icons.mic : Icons.mic_off;
    }
    return Card(
      color: streaming
          ? Colors.green.shade900.withValues(alpha: 0.6)
          : Colors.grey.shade900.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Icon(
              icon,
              size: 56,
              color: streaming ? Colors.greenAccent : Colors.grey,
            ),
            const SizedBox(height: 8),
            Text(status, textAlign: TextAlign.center),
            if (streaming) ...[
              const SizedBox(height: 4),
              Text(
                '$packets paquetes  ·  ${(packets * (mode == CaptureMode.dj ? 5 : 10) / 1000).toStringAsFixed(1)}s',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
