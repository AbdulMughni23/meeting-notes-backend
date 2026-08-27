import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MeetingNotesApp());

class MeetingNotesApp extends StatelessWidget {
  const MeetingNotesApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Meeting Notes',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomeScreen(),
    );
  }
}

/// Per-connected-endpoint state for one in-progress meeting.
class _MeetingSession {
  int participantCount = 2;
  List<String> roles = [];
  final Map<int, String> chunkTranscripts = {};
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _status = 'Waiting for Watch...';
  String _result = '';
  bool _isProcessing = false;
  final String _serviceId = 'meeting_notes_sync';
  final String _baseUrl = const String.fromEnvironment("baseUrl");
  final List<String> _log = [];

  // Endpoint -> the session_start / chunk metadata expected next.
  final Map<String, Map<String, dynamic>> _pendingChunkMetaByEndpoint = {};
  // Endpoint -> accumulated meeting state.
  final Map<String, _MeetingSession> _sessions = {};

  @override
  void initState() {
    super.initState();
    _init();
  }

  void _addLog(String line) {
    setState(() => _log.insert(0, line));
  }

  Future<void> _init() async {
    final granted = await _requestPermissions();
    if (!granted) {
      setState(() => _status = 'Permissions required to receive from Watch');
      return;
    }
    await _startAdvertising();
  }

  Future<bool> _requestPermissions() async {
    final statuses = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  Future<void> _startAdvertising() async {
    setState(() => _status = 'Advertising to Watch...');

    try {
      await Nearby().startAdvertising(
        'PhoneHost',
        Strategy.P2P_CLUSTER,
        serviceId: _serviceId,
        onConnectionInitiated: (String endpointId, ConnectionInfo info) {
          Nearby().acceptConnection(
            endpointId,
            onPayLoadRecieved: (String epId, Payload payload) {
              if (payload.type == PayloadType.BYTES && payload.bytes != null) {
                _handleBytesPayload(epId, payload.bytes!);
              }
            },
            onPayloadTransferUpdate:
                (String epId, PayloadTransferUpdate update) {
                  if (update.status == PayloadStatus.FAILURE) {
                    _addLog('A payload transfer failed - continuing.');
                  }
                  // BYTES payloads arrive whole in onPayLoadRecieved above,
                  // so there's nothing to do here on SUCCESS.
                },
          );
        },
        onConnectionResult: (String endpointId, Status status) {
          if (status == Status.CONNECTED) {
            setState(() => _status = 'Watch Connected!');
            _sessions[endpointId] = _MeetingSession();
            _log.clear();
            _addLog('Connected to watch.');
          }
        },
        onDisconnected: (String endpointId) {
          _sessions.remove(endpointId);
          _pendingChunkMetaByEndpoint.remove(endpointId);
          setState(() => _status = 'Watch Disconnected. Listening again...');
          _startAdvertising();
        },
      );
    } catch (e) {
      setState(() => _status = 'Failed to start advertising: $e');
    }
  }

  // A BYTES payload is either the small JSON metadata message, or the
  // raw audio chunk itself. JSON.decode on real audio bytes throws
  // (they're not valid UTF-8/JSON), so that failure is exactly the
  // signal that this payload is audio, not metadata.
  void _handleBytesPayload(String epId, List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded['type'] == 'session_start') {
        final session = _sessions.putIfAbsent(epId, () => _MeetingSession());
        session.participantCount = decoded['participant_count'] ?? 2;
        session.roles =
            (decoded['roles'] as List?)?.map((r) => r.toString()).toList() ??
            [];
        setState(() => _status = 'Recording in progress...');
        _addLog(
          'Meeting info received: ${session.participantCount} participants.',
        );
      } else if (decoded['type'] == 'chunk') {
        debugPrint('[phone] chunk metadata received from $epId: $decoded');
        _pendingChunkMetaByEndpoint[epId] = {
          'chunk_index': decoded['chunk_index'],
          'is_final': decoded['is_final'] ?? false,
        };
      }
    } catch (_) {
      // Not valid JSON => this is the audio chunk itself.
      debugPrint(
        '[phone] audio bytes received from $epId: ${bytes.length} bytes',
      );
      _handleChunkAudio(epId, bytes);
    }
  }

  Future<void> _handleChunkAudio(String epId, List<int> bytes) async {
    final meta = _pendingChunkMetaByEndpoint.remove(epId);
    if (meta == null) {
      debugPrint('[phone] audio bytes arrived with NO metadata');
      _addLog('A chunk arrived but had no matching info - dropped.');
      return;
    }
    debugPrint('[phone] pairing ${bytes.length} audio bytes with meta $meta');

    final chunkIndex = meta['chunk_index'] as int;
    final isFinal = meta['is_final'] as bool;

    setState(() => _isProcessing = true);
    _addLog('Chunk $chunkIndex received - transcribing...');

    final transcript = await _transcribeChunk(bytes, chunkIndex);
    final session = _sessions.putIfAbsent(epId, () => _MeetingSession());
    if (transcript != null) {
      session.chunkTranscripts[chunkIndex] = transcript;
      _addLog('Chunk $chunkIndex transcribed.');
    } else {
      _addLog('Chunk $chunkIndex failed to transcribe - skipped.');
    }
    // Nothing was ever written to disk on the phone - the bytes just
    // go out of scope here once transcription is done.

    if (isFinal) {
      await _finalizeMeeting(session);
      _sessions.remove(epId);
    } else {
      setState(() => _isProcessing = false);
    }
  }

  Future<String?> _transcribeChunk(List<int> bytes, int chunkIndex) async {
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('$_baseUrl/transcribe-chunk'),
      );
      request.fields['chunk_index'] = chunkIndex.toString();
      request.files.add(
        http.MultipartFile.fromBytes(
          'audio',
          bytes,
          filename: 'chunk_$chunkIndex.opus',
        ),
      );

      var response = await request.send();
      var responseData = await response.stream.bytesToString();

      if (response.statusCode == 200) {
        final data = jsonDecode(responseData);
        return data['transcript'] as String?;
      }
      return null;
    } catch (e) {
      debugPrint('[phone] transcribe chunk $chunkIndex failed: $e');
      return null;
    }
  }

  Future<void> _finalizeMeeting(_MeetingSession session) async {
    setState(() => _status = 'Generating formatted notes...');
    _addLog('All chunks in - combining transcript.');

    final orderedKeys = session.chunkTranscripts.keys.toList()..sort();
    final fullText = orderedKeys
        .map((k) => session.chunkTranscripts[k])
        .join('\n');

    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/process-meeting'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': fullText,
          'participant_count': session.participantCount,
          'roles': session.roles,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final notes = data['notes'] as String;
        setState(() {
          _result = notes;
          _isProcessing = false;
          _status = 'Meeting Notes Ready';
        });
        _addLog('Notes ready.');
        await _saveToHistory(notes);
      } else {
        setState(() {
          _result = 'Cloud Error: ${response.statusCode}';
          _isProcessing = false;
        });
      }
    } catch (e) {
      setState(() {
        _result = 'Network Error: $e';
        _isProcessing = false;
      });
    }
  }

  Future<void> _saveToHistory(String notes) async {
    final prefs = await SharedPreferences.getInstance();
    final history = prefs.getStringList('meeting_history') ?? [];
    history.insert(
      0,
      jsonEncode({
        'timestamp': DateTime.now().toIso8601String(),
        'notes': notes,
      }),
    );
    await prefs.setStringList('meeting_history', history);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meeting Notes (Phone)'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HistoryScreen()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    if (_isProcessing)
                      const Padding(
                        padding: EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    else
                      const Icon(Icons.bluetooth_searching, color: Colors.blue),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _status,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_result.isNotEmpty) ...[
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _result,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _result = '';
                    _log.clear();
                    _status = 'Waiting for Watch...';
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                child: const Text('Reset / New Meeting'),
              ),
            ] else
              Expanded(
                child: _log.isEmpty
                    ? const Center(
                        child: Text(
                          'No activity yet.',
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _log.length,
                        itemBuilder: (context, i) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Text(
                            '• ${_log[i]}',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    Nearby().stopAdvertising();
    Nearby().stopAllEndpoints();
    super.dispose();
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _entries = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('meeting_history') ?? [];
    setState(() {
      _entries = raw.map((e) => jsonDecode(e) as Map<String, dynamic>).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Past Meetings')),
      body: _entries.isEmpty
          ? const Center(child: Text('No saved meetings yet.'))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final entry = _entries[i];
                final ts = DateTime.tryParse(entry['timestamp'] ?? '');
                final notes = entry['notes'] as String? ?? '';
                return ListTile(
                  title: Text(ts?.toLocal().toString() ?? 'Unknown date'),
                  subtitle: Text(
                    notes,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  onTap: () => showDialog(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: Text(ts?.toLocal().toString() ?? ''),
                      content: SingleChildScrollView(child: Text(notes)),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close'),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
