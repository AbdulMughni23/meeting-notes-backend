import 'package:flutter/material.dart';
import 'package:record/record.dart';

void main() {
  runApp(const WatchApp());
}

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
  int _participantCount = 2;
  List<TextEditingController> _roleControllers = [];

  final AudioRecorder _recorder = AudioRecorder();
  bool _isRecording = false;
  int _recordingSeconds = 0;

  @override
  void initState() {
    super.initState();
    _initializeControllers();
    _checkPermission();
  }

  Future<void> _checkPermission() async {
    await _recorder.hasPermission(); // Request permission early
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

  void _incrementCount() {
    if (_participantCount < 5) {
      setState(() {
        _participantCount++;
        _initializeControllers();
      });
    }
  }

  void _decrementCount() {
    if (_participantCount > 1) {
      setState(() {
        _participantCount--;
        _initializeControllers();
      });
    }
  }

  Future<void> _startMeeting() async {
    List<String> roles = _roleControllers.map((c) => c.text.trim()).toList();

    if (roles.any((role) => role.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Fill all roles!', textAlign: TextAlign.center),
          padding: EdgeInsets.only(bottom: 45),
        ),
      );
      return;
    }

    setState(() {
      _isRecording = true;
      _recordingSeconds = 0;
    });

    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.aacLc,
        bitRate: 64000,
        sampleRate: 44100,
      ),
      path:
          '/sdcard/Download/meeting_${DateTime.now().millisecondsSinceEpoch}.m4a',
    );

    _startTimer();
  }

  void _startTimer() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 1));
      if (_isRecording) {
        setState(() {
          _recordingSeconds++;
        });
        return true;
      }
      return false;
    });
  }

  Future<void> _stopRecording() async {
    String? path = await _recorder.stop();
    setState(() {
      _isRecording = false;
    });

    print("=========================================");
    print("RECORDING COMPLETE!");
    print("Path: $path");
    print("Duration: $_recordingSeconds s");
    print("Roles: ${_roleControllers.map((c) => c.text.trim()).toList()}");
    print("=========================================");
  }

  @override
  void dispose() {
    for (var controller in _roleControllers) {
      controller.dispose();
    }
    _recorder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Minimal app bar for round screens
      appBar: AppBar(
        title: Text(
          _isRecording ? 'Recording' : 'Setup',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      // Generous horizontal padding prevents text from hitting the curved edges
      body: SingleChildScrollView(
        padding: const EdgeInsets.only(
          top: 16,
          bottom: 55,
          left: 16,
          right: 16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center, // Center everything!
          children: [
            if (!_isRecording) ...[
              const Text(
                'Participants',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 8),

              // Large, centered counter
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  InkWell(
                    onTap: _decrementCount,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.remove,
                        size: 32,
                        color: _participantCount <= 1
                            ? Colors.grey
                            : Colors.white,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20.0),
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
                    onTap: _incrementCount,
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.all(8),
                      child: Icon(
                        Icons.add,
                        size: 32,
                        color: _participantCount >= 5
                            ? Colors.grey
                            : Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              const Text(
                'Enter Roles',
                style: TextStyle(fontSize: 14, color: Colors.grey),
              ),
              const SizedBox(height: 12),

              // Centered, compact text fields
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _participantCount,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12.0),
                    child: TextField(
                      controller: _roleControllers[index],
                      textAlign: TextAlign
                          .center, // Looks much better on round screens
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Person ${index + 1}',
                        hintStyle: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(
                            20,
                          ), // Rounded corners match the watch
                        ),
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        filled: true,
                        fillColor: Colors.grey[900],
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),

              // Large, rounded start button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _startMeeting,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 25),
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text(
                    'START RECORDING',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ] else ...[
              // Recording Screen: Giant, centered, easy to read
              const SizedBox(height: 40),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.red.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.mic, size: 64, color: Colors.red),
              ),
              const SizedBox(height: 24),
              Text(
                '$_recordingSeconds s',
                style: const TextStyle(
                  fontSize: 48,
                  fontWeight: FontWeight.bold,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'Recording in progress...',
                style: TextStyle(color: Colors.grey, fontSize: 14),
              ),
              const SizedBox(height: 40),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _stopRecording,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    backgroundColor: Colors.red,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text(
                    'STOP',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
