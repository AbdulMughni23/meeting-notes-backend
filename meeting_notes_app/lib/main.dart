import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'dart:convert';

void main() {
  runApp(const MeetingNotesApp());
}

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

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String _result = '';
  bool _isLoading = false;
  bool _hasMeeting = false;

  // ⚠️ IMPORTANT: Replace with your computer's actual IPv4 Address!
  final String baseUrl = 'http://192.168.1.XXX:8000';

  // For now, we simulate receiving data from the watch
  // In the real app, this will be triggered by Bluetooth/Wi-Fi transfer
  Future<void> _simulateWatchTransfer() async {
    setState(() {
      _isLoading = true;
      _result = 'Receiving data from watch...';
    });

    // Simulate network delay
    await Future.delayed(const Duration(seconds: 2));

    // For testing, we'll use a sample transcript
    // In production, this data comes from the watch
    final sampleTranscript =
        "Before we get going, I just wanted you to know. Did you notice I'm wearing blue? Because I saw your company has blue logo. So I wore the blue. I mean, that's a nice shirt. But actually, our logo is red, just for information. It's red. Yeah, but I like it. Oh, wait. Oh, no, it's another company. Sorry, I mixed it up. Gotcha. Gotcha. I understand.";

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/process-meeting'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'text': sampleTranscript,
          'participant_count': 2,
          'roles': ['Manager', 'Client'],
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          _result = data['notes'];
          _isLoading = false;
          _hasMeeting = true;
        });
      } else {
        setState(() {
          _result = 'Error processing meeting';
          _isLoading = false;
        });
      }
    } catch (e) {
      setState(() {
        _result = 'Network Error: $e\n\nIs the backend running?';
        _isLoading = false;
      });
    }
  }

  void _clearMeeting() {
    setState(() {
      _result = '';
      _hasMeeting = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Meeting Notes'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (!_hasMeeting && !_isLoading) ...[
              const Spacer(),
              const Icon(Icons.watch, size: 80, color: Colors.grey),
              const SizedBox(height: 24),
              const Text(
                'Waiting for Watch...',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'Start a meeting on your watch to see notes here',
                style: TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              ElevatedButton.icon(
                onPressed: _simulateWatchTransfer,
                icon: const Icon(Icons.download),
                label: const Text('Simulate Watch Transfer (Test)'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
              ),
              const Spacer(),
            ] else if (_isLoading) ...[
              const Spacer(),
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              const Text(
                'Processing Meeting...',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _result,
                style: const TextStyle(fontSize: 16, color: Colors.grey),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
            ] else ...[
              const Text(
                'Meeting Notes',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _result,
                      style: const TextStyle(fontSize: 16, height: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _clearMeeting,
                icon: const Icon(Icons.refresh),
                label: const Text('New Meeting'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: Colors.blue,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
