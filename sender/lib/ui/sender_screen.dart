import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../audio/audio_service.dart';
import '../discovery/discovery_service.dart';
import 'theme.dart';

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
    final isDj = _mode == CaptureMode.dj;
    return Scaffold(
      backgroundColor: NeonColors.bg,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: ShaderMask(
          shaderCallback: (bounds) =>
              brandGradient.createShader(Rect.fromLTWH(0, 0, bounds.width, bounds.height)),
          child: Text(
            'EVERDJ',
            style: wordmarkStyle.copyWith(fontSize: 26, letterSpacing: 8),
          ),
        )
            .animate(onPlay: (c) => c.repeat())
            .shimmer(
              duration: const Duration(seconds: 3),
              color: NeonColors.cyan.withValues(alpha: 0.5),
            ),
      ),
      body: Stack(
        children: [
          // Animated neon background blobs
          const _NeonBackground(),
          SafeArea(
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
                  ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.15, duration: 350.ms),
                  const SizedBox(height: 12),
                  Text(
                    'IP del teléfono: $_myIp',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: NeonColors.cyan.withValues(alpha: 0.7),
                        ),
                  ).animate().fadeIn(duration: 350.ms, delay: 60.ms),
                  const SizedBox(height: 20),
                  _DiscoveryBanner(
                    streaming: _streaming,
                    connecting: _connecting,
                    receiver: _receiver,
                  ).animate().fadeIn(duration: 350.ms, delay: 120.ms).slideY(begin: 0.15, duration: 350.ms, delay: 120.ms),
                  if (_streaming) ...[
                    const SizedBox(height: 16),
                    _MicLevel(
                      level: _level,
                      label: isDj ? 'SALIDA' : 'ENTRADA MIC',
                      hint: isDj ? 'pon música y habla…' : 'habla al teléfono…',
                    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.1, duration: 300.ms),
                  ],
                  const SizedBox(height: 16),
                  // Mode toggle — disabled while streaming or connecting
                  _ModeToggle(
                    mode: _mode,
                    enabled: !_streaming && !_connecting,
                    onChanged: (m) => setState(() => _mode = m),
                  ).animate().fadeIn(duration: 350.ms, delay: 180.ms),
                  const SizedBox(height: 16),
                  _MainButton(
                    streaming: _streaming,
                    connecting: _connecting,
                    receiver: _receiver,
                    isDj: isDj,
                    onPressed: (_streaming || _receiver != null) && !_connecting
                        ? _onMainButton
                        : null,
                  ).animate().fadeIn(duration: 350.ms, delay: 240.ms).slideY(begin: 0.15, duration: 350.ms, delay: 240.ms),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => setState(() => _showManual = !_showManual),
                    child: Text(
                      _showManual ? 'Ocultar conexión manual' : 'Conexión manual',
                      style: TextStyle(
                        color: NeonColors.cyan.withValues(alpha: 0.8),
                        letterSpacing: 0.5,
                      ),
                    ),
                  ).animate().fadeIn(duration: 350.ms, delay: 300.ms),
                  if (_showManual) _buildManual(),
                  const SizedBox(height: 12),
                  Text(
                    'Ambos dispositivos deben estar en la misma red Wi-Fi.\nLa app encuentra el receptor automáticamente.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Colors.white.withValues(alpha: 0.35),
                        ),
                  ).animate().fadeIn(duration: 350.ms, delay: 360.ms),
                ],
              ),
            ),
          ),
        ],
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
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'IP del receptor',
              labelStyle: TextStyle(color: NeonColors.cyan.withValues(alpha: 0.8)),
              hintText: '192.168.1.100',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.3)),
              filled: true,
              fillColor: NeonColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.violet.withValues(alpha: 0.4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.cyan, width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.violet.withValues(alpha: 0.4)),
              ),
              prefixIcon: Icon(Icons.computer, color: NeonColors.cyan.withValues(alpha: 0.7)),
              errorText: _ipError,
              errorStyle: const TextStyle(color: NeonColors.magenta),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _portCtrl,
            enabled: !_streaming,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              labelText: 'Puerto UDP',
              labelStyle: TextStyle(color: NeonColors.cyan.withValues(alpha: 0.8)),
              filled: true,
              fillColor: NeonColors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.violet.withValues(alpha: 0.4)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.cyan, width: 1.5),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: NeonColors.violet.withValues(alpha: 0.4)),
              ),
              prefixIcon: Icon(Icons.settings_ethernet, color: NeonColors.cyan.withValues(alpha: 0.7)),
              errorText: _portError,
              errorStyle: const TextStyle(color: NeonColors.magenta),
            ),
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _streaming ? null : _connectManual,
            style: OutlinedButton.styleFrom(
              side: BorderSide(color: NeonColors.cyan.withValues(alpha: 0.7)),
              foregroundColor: NeonColors.cyan,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
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

// ── Animated neon background ──────────────────────────────────────────────────

class _NeonBackground extends StatelessWidget {
  const _NeonBackground();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: SizedBox.expand(
        child: Stack(
          children: [
            // Top-left magenta blob
            Positioned(
              top: -80,
              left: -60,
              child: _NeonBlob(
                color: NeonColors.magenta,
                size: 280,
                duration: const Duration(seconds: 7),
              ),
            ),
            // Bottom-right cyan blob
            Positioned(
              bottom: -60,
              right: -80,
              child: _NeonBlob(
                color: NeonColors.cyan,
                size: 240,
                duration: const Duration(seconds: 9),
                delay: const Duration(seconds: 2),
              ),
            ),
            // Center violet accent
            Positioned(
              top: 200,
              right: -40,
              child: _NeonBlob(
                color: NeonColors.violet,
                size: 180,
                duration: const Duration(seconds: 11),
                delay: const Duration(seconds: 4),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NeonBlob extends StatelessWidget {
  const _NeonBlob({
    required this.color,
    required this.size,
    required this.duration,
    this.delay = Duration.zero,
  });

  final Color color;
  final double size;
  final Duration duration;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            color.withValues(alpha: 0.18),
            color.withValues(alpha: 0.0),
          ],
        ),
      ),
    )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          begin: const Offset(0.85, 0.85),
          end: const Offset(1.15, 1.15),
          duration: duration,
          delay: delay,
          curve: Curves.easeInOut,
        )
        .fadeIn(duration: const Duration(seconds: 2), delay: delay);
  }
}

// ── Discovery banner ──────────────────────────────────────────────────────────

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
    Widget content;
    Color glowColor;

    if (streaming && receiver != null) {
      glowColor = NeonColors.cyan;
      content = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline, color: NeonColors.cyan, size: 16),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              'Conectado a ${receiver!.name}',
              style: const TextStyle(
                color: NeonColors.cyan,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      );
    } else if (connecting) {
      glowColor = NeonColors.violet;
      content = const _SpinnerRow(text: 'Conectando…');
    } else if (receiver != null) {
      glowColor = NeonColors.magenta;
      content = Text(
        'Encontrado ${receiver!.name}  ·  ${receiver!.host}',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: NeonColors.magenta.withValues(alpha: 0.9),
          letterSpacing: 0.3,
        ),
      );
    } else {
      glowColor = NeonColors.violet;
      content = const _SpinnerRow(text: 'Buscando un receptor en la red…');
    }

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      decoration: BoxDecoration(
        color: NeonColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: glowColor.withValues(alpha: 0.35),
          width: 1,
        ),
        boxShadow: [neonGlow(glowColor, blur: 12, spread: 0)],
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
        SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            valueColor: AlwaysStoppedAnimation<Color>(
              NeonColors.cyan.withValues(alpha: 0.85),
            ),
          ),
        )
            .animate(onPlay: (c) => c.repeat(reverse: true))
            .fadeIn(
              duration: const Duration(milliseconds: 700),
              curve: Curves.easeInOut,
            ),
        const SizedBox(width: 12),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.8)),
          ),
        ),
      ],
    );
  }
}

// ── VU meter ──────────────────────────────────────────────────────────────────

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

  /// Neon zone colors: cyan (low) → magenta (mid) → magenta bright (hot)
  Color _zoneColor(double frac) {
    if (frac < 0.60) return NeonColors.cyan;
    if (frac < 0.85) return NeonColors.magenta;
    return const Color(0xFFFF6BDB); // hot pink / overload
  }

  @override
  Widget build(BuildContext context) {
    final active = (_smooth * _segments).round();
    final peakIdx = (_peak * _segments).clamp(0, _segments - 1).round();
    final silent = _peak < 0.015;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: NeonColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: NeonColors.violet.withValues(alpha: 0.3),
          width: 1,
        ),
        boxShadow: [neonGlow(NeonColors.violet, blur: 10, spread: 0)],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.graphic_eq, size: 14, color: NeonColors.cyan.withValues(alpha: 0.8)),
              const SizedBox(width: 6),
              Text(
                widget.label,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: NeonColors.cyan.withValues(alpha: 0.9),
                      letterSpacing: 1.5,
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              if (silent)
                Text(
                  widget.hint,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 22,
            child: Row(
              children: List.generate(_segments, (i) {
                final frac = i / (_segments - 1);
                final color = _zoneColor(frac);
                final isActive = i < active;
                final isPeak = i == peakIdx;
                final lit = isActive || isPeak;
                return Expanded(
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 1),
                    decoration: BoxDecoration(
                      color: lit ? color : color.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: lit
                          ? [
                              BoxShadow(
                                color: color.withValues(alpha: isPeak ? 0.9 : 0.55),
                                blurRadius: isPeak ? 6 : 3,
                                spreadRadius: 0,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Status card ───────────────────────────────────────────────────────────────

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

    final glowColor = streaming ? NeonColors.cyan : NeonColors.violet;

    return Container(
      decoration: BoxDecoration(
        color: NeonColors.surface.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: glowColor.withValues(alpha: streaming ? 0.55 : 0.25),
          width: 1,
        ),
        boxShadow: [
          neonGlow(glowColor, blur: streaming ? 24 : 12, spread: streaming ? 2 : 0),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          // Icon — pulses with scale+glow while streaming
          _StatusIcon(icon: icon, streaming: streaming, glowColor: glowColor),
          const SizedBox(height: 8),
          Text(
            status,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: streaming
                      ? NeonColors.cyan
                      : Colors.white.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
          ),
          if (streaming) ...[
            const SizedBox(height: 4),
            Text(
              '$packets paquetes  ·  ${(packets * (mode == CaptureMode.dj ? 5 : 10) / 1000).toStringAsFixed(1)}s',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({
    required this.icon,
    required this.streaming,
    required this.glowColor,
  });

  final IconData icon;
  final bool streaming;
  final Color glowColor;

  @override
  Widget build(BuildContext context) {
    final iconWidget = Icon(
      icon,
      size: 56,
      color: streaming ? glowColor : Colors.white.withValues(alpha: 0.4),
    );

    if (!streaming) return iconWidget;

    // Continuously pulse scale + glow while streaming.
    // Both effects share the same duration so they run in tandem.
    return iconWidget
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .scale(
          begin: const Offset(1.0, 1.0),
          end: const Offset(1.15, 1.15),
          duration: const Duration(milliseconds: 900),
          curve: Curves.easeInOut,
        )
        .custom(
          // delay: 0 keeps this effect aligned to the same start time as .scale()
          delay: Duration.zero,
          duration: const Duration(milliseconds: 900),
          builder: (context, value, child) {
            final glow = (0.5 + 0.5 * value).clamp(0.0, 1.0);
            return DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: glowColor.withValues(alpha: glow * 0.55),
                    blurRadius: 16 + glow * 12,
                    spreadRadius: 0,
                  ),
                ],
              ),
              child: child!,
            );
          },
        );
  }
}

// ── Mode toggle ───────────────────────────────────────────────────────────────

class _ModeToggle extends StatelessWidget {
  const _ModeToggle({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final CaptureMode mode;
  final bool enabled;
  final ValueChanged<CaptureMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: NeonColors.surface.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: NeonColors.violet.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Row(
        children: [
          _ModePill(
            icon: Icons.mic,
            label: 'Micrófono',
            selected: mode == CaptureMode.mic,
            enabled: enabled,
            onTap: enabled ? () => onChanged(CaptureMode.mic) : null,
          ),
          _ModePill(
            icon: Icons.album,
            label: 'DJ',
            selected: mode == CaptureMode.dj,
            enabled: enabled,
            onTap: enabled ? () => onChanged(CaptureMode.dj) : null,
          ),
        ],
      ),
    );
  }
}

class _ModePill extends StatelessWidget {
  const _ModePill({
    required this.icon,
    required this.label,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final activeColor = NeonColors.magenta;
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            gradient: selected
                ? LinearGradient(
                    colors: [
                      NeonColors.magenta.withValues(alpha: 0.85),
                      NeonColors.violet.withValues(alpha: 0.85),
                    ],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  )
                : null,
            borderRadius: BorderRadius.circular(8),
            boxShadow: selected
                ? [neonGlow(activeColor, blur: 10, spread: 0)]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 16,
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: enabled ? 0.5 : 0.25),
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: enabled ? 0.5 : 0.25),
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Main action button ────────────────────────────────────────────────────────

class _MainButton extends StatelessWidget {
  const _MainButton({
    required this.streaming,
    required this.connecting,
    required this.receiver,
    required this.isDj,
    required this.onPressed,
  });

  final bool streaming;
  final bool connecting;
  final DiscoveredReceiver? receiver;
  final bool isDj;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final bool disabled = onPressed == null;

    final IconData icon = streaming
        ? Icons.stop_rounded
        : (isDj ? Icons.album : Icons.mic);

    final String label = streaming
        ? (isDj ? 'Detener DJ' : 'Detener')
        : receiver != null
            ? (isDj ? 'Empezar DJ' : 'Empezar')
            : 'Buscando…';

    // Core button body
    Widget button = GestureDetector(
      onTap: onPressed,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        padding: const EdgeInsets.symmetric(vertical: 18),
        decoration: BoxDecoration(
          gradient: disabled
              ? null
              : streaming
                  ? LinearGradient(
                      colors: [
                        const Color(0xFFCC0044),
                        NeonColors.magenta,
                      ],
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                    )
                  : brandGradient,
          color: disabled ? NeonColors.surface : null,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: disabled
                ? Colors.white.withValues(alpha: 0.1)
                : streaming
                    ? NeonColors.magenta.withValues(alpha: 0.6)
                    : NeonColors.cyan.withValues(alpha: 0.4),
            width: 1,
          ),
          boxShadow: disabled
              ? null
              : [
                  neonGlow(
                    streaming ? NeonColors.magenta : NeonColors.cyan,
                    blur: 18,
                    spread: 1,
                  ),
                ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 22,
              color: disabled
                  ? Colors.white.withValues(alpha: 0.3)
                  : Colors.white,
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
                color: disabled
                    ? Colors.white.withValues(alpha: 0.3)
                    : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );

    // Pulsing glow ring around the button while streaming
    if (streaming) {
      button = Stack(
        alignment: Alignment.center,
        children: [
          // Outer pulsing ring
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
              ),
            )
                .animate(onPlay: (c) => c.repeat(reverse: true))
                .custom(
                  duration: const Duration(milliseconds: 1100),
                  builder: (context, value, child) => DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: NeonColors.magenta.withValues(alpha: 0.15 + value * 0.35),
                          blurRadius: 20 + value * 16,
                          spreadRadius: 2 + value * 4,
                        ),
                      ],
                    ),
                    child: child,
                  ),
                ),
          ),
          button,
        ],
      );
    }

    return button;
  }
}
