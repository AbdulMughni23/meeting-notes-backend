import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';

void main() => runApp(const WatchApp());

class WatchApp extends StatelessWidget {
  const WatchApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meeting Watch',
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.blue,
        scaffoldBackgroundColor: Colors.black,
      ),
      home: const WatchSetupScreen(),
    );
  }
}

class WatchSetupScreen extends StatefulWidget {
  const WatchSetupScreen({super.key});
  @override
  State<WatchSetupScreen> createState() => _WatchSetupScreenState();
}

class _WatchSetupScreenState extends State<WatchSetupScreen> {
  static const Duration _chunkDuration = Duration(seconds: 30);

  int _participantCount = 2;
  List<TextEditingController> _roleControllers = [];
  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingSeconds = 0;
  String _status = 'Setup';

  final String _serviceId = 'meeting_notes_sync';
  String? _phoneEndpointId;
  Timer? _discoveryTimeoutTimer;

  int _chunkIndex = 0;
  Completer<void>? _chunkCompleter;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _init();
  }

  Future<void> _init() async {
    final granted = await _requestPermissions();
    if (!granted) {
      setState(() => _status = 'Permissions required for mic and nearby');
      return;
    }
    await _recorder.hasPermission();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.microphone,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  void _initializeControllers() {
    List<String> existingRoles = _roleControllers.map((c) => c.text).toList();
    _roleControllers = List.generate(_participantCount, (index) {
      TextEditingController controller = TextEditingController();
      if (index < existingRoles.length) {
        controller.text = existingRoles[index];
      }
      return controller;
    });
  }

  // ---- Connect first, then start the chunked recording loop ----

  Future<void> _startMeeting() async {
    List<String> roles = _roleControllers.map((c) => c.text.trim()).toList();
    if (roles.any((role) => role.isEmpty)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Fill all roles!')));
      return;
    }

    setState(() => _status = 'Finding Phone...');

    final granted = await _requestPermissions();
    if (!granted) {
      setState(() => _status = 'Permissions required to find Phone');
      return;
    }

    _startDiscoveryTimeout();

    await Nearby().startDiscovery(
      'WatchClient',
      Strategy.P2P_CLUSTER,
      serviceId: _serviceId,
      onEndpointFound: (String id, String name, String serviceId) {
        _discoveryTimeoutTimer?.cancel();
        _phoneEndpointId = id;
        setState(() => _status = 'Phone Found! Connecting...');
        Nearby().stopDiscovery();
        _connectThenRecord(roles);
      },
      onEndpointLost: (_) {},
    );
  }

  void _startDiscoveryTimeout() {
    _discoveryTimeoutTimer?.cancel();
    _discoveryTimeoutTimer = Timer(const Duration(seconds: 20), () {
      if (_phoneEndpointId == null) {
        Nearby().stopDiscovery();
        setState(() => _status = 'Phone not found. Try again.');
      }
    });
  }

  Future<void> _connectThenRecord(List<String> roles) async {
    if (_phoneEndpointId == null) return;

    await Nearby().requestConnection(
      'WatchClient',
      _phoneEndpointId!,
      onConnectionInitiated: (id, info) {
        // Both sides must accept - this is required, not optional.
        Nearby().acceptConnection(
          id,
          onPayLoadRecieved: (endpointId, payload) {},
        );
      },
      onConnectionResult: (id, status) async {
        if (status != Status.CONNECTED) {
          setState(() => _status = 'Connection failed. Try again.');
          return;
        }

        // Tell the phone how many participants / what roles up front,
        // once per meeting - not repeated per chunk.
        final sessionMsg = jsonEncode({
          'type': 'session_start',
          'participant_count': _participantCount,
          'roles': roles,
        });
        await Nearby().sendBytesPayload(id, utf8.encode(sessionMsg));

        setState(() {
          _isRecording = true;
          _recordingSeconds = 0;
          _status = 'Recording';
        });
        _startTimer();
        _recordingLoop(id);
      },
      onDisconnected: (id) {
        setState(() {
          _isRecording = false;
          _status = 'Disconnected';
        });
      },
    );
  }

  // ---- Chunked recording loop ----

  Future<void> _recordingLoop(String endpointId) async {
    _chunkIndex = 0;
    while (_isRecording) {
      final path = await _recordOneChunk();
      if (path == null) break;

      final isFinal = !_isRecording;
      setState(
        () => _status = isFinal
            ? 'Sending final chunk...'
            : 'Recording (sent ${_chunkIndex + 1})',
      );

      // Await fully before recording the next chunk, so chunk metadata
      // and its file always arrive at the phone strictly in order.
      await _sendChunk(endpointId, path, _chunkIndex, isFinal);
      _chunkIndex++;

      if (isFinal) break;
    }
    setState(() => _status = 'Meeting Sent. Processing on Phone...');
  }

  Future<String?> _recordOneChunk() async {
    final dir = await getApplicationDocumentsDirectory();
    final path =
        '${dir.path}/chunk_${_chunkIndex}_${DateTime.now().millisecondsSinceEpoch}.opus';

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.opus,
        bitRate: 32000,
        sampleRate: 48000,
      ),
      path: path,
    );

    _chunkCompleter = Completer<void>();
    final timer = Timer(_chunkDuration, () {
      if (!(_chunkCompleter?.isCompleted ?? true)) _chunkCompleter!.complete();
    });
    await _chunkCompleter!.future;
    timer.cancel();

    return _recorder.stop();
  }

  Future<void> _sendChunk(
    String endpointId,
    String filePath,
    int chunkIndex,
    bool isFinal,
  ) async {
    try {
      final meta = jsonEncode({
        'type': 'chunk',
        'chunk_index': chunkIndex,
        'is_final': isFinal,
      });
      await Nearby().sendBytesPayload(endpointId, utf8.encode(meta));
      await Nearby().sendFilePayload(endpointId, filePath);
    } catch (_) {
      // Best-effort: if a chunk fails to send, we still move on so the
      // recording doesn't get stuck. The phone will just be missing
      // that chunk's text in the final transcript.
    }
  }

  void _stopRecording() {
    _isRecording = false;
    // Unblocks whichever chunk is currently mid-recording so the loop
    // can wrap it up as the final chunk immediately, instead of
    // waiting out the rest of the 30s window.
    if (!(_chunkCompleter?.isCompleted ?? true)) {
      _chunkCompleter!.complete();
    }
  }

  void _startTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (_isRecording) {
        setState(() => _recordingSeconds++);
        return true;
      }
      return false;
    });
  }

  void _resetToSetup() {
    _discoveryTimeoutTimer?.cancel();
    _phoneEndpointId = null;
    setState(() {
      _status = 'Setup';
      _recordingSeconds = 0;
    });
  }

  @override
  void dispose() {
    for (var c in _roleControllers) {
      c.dispose();
    }
    _recorder.dispose();
    _discoveryTimeoutTimer?.cancel();
    Nearby().stopDiscovery();
    Nearby().stopAllEndpoints();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool showRetry =
        _status == 'Phone not found. Try again.' ||
        _status == 'Connection failed. Try again.' ||
        _status == 'Disconnected' ||
        _status == 'Meeting Sent. Processing on Phone...';

    return Scaffold(
      appBar: AppBar(
        title: Text(_status, style: const TextStyle(fontSize: 14)),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(
          top: 16,
          bottom: 55,
          left: 16,
          right: 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (!_isRecording && _status == 'Setup') ...[
              const Text(
                'Participants',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: () {
                      if (_participantCount > 1) {
                        setState(() {
                          _participantCount--;
                          _initializeControllers();
                        });
                      }
                    },
                    child: const Icon(Icons.remove, size: 32),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      '$_participantCount',
                      style: const TextStyle(
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue,
                      ),
                    ),
                  ),
                  InkWell(
                    onTap: () {
                      if (_participantCount < 5) {
                        setState(() {
                          _participantCount++;
                          _initializeControllers();
                        });
                      }
                    },
                    child: const Icon(Icons.add, size: 32),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _participantCount,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: _roleControllers[index],
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      hintText: 'Person ${index + 1}',
                      border: const OutlineInputBorder(),
                      isDense: true,
                      filled: true,
                      fillColor: Colors.grey[900],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _startMeeting,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('START'),
                ),
              ),
            ] else if (_isRecording) ...[
              const Icon(Icons.mic, size: 64, color: Colors.red),
              const SizedBox(height: 24),
              Text(
                '$_recordingSeconds s',
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _stopRecording,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  child: const Text('STOP & SEND'),
                ),
              ),
            ] else ...[
              if (!showRetry) const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(_status, textAlign: TextAlign.center),
              if (showRetry) ...[
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _resetToSetup,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                    child: const Text('Back to Setup'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
