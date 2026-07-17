import 'package:flutter/material.dart';
import '../theme/control_room_theme.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: Colors.black,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                'Privacy Policy',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: Colors.white),
              ),
              SizedBox(height: 8),
              Text(
                'Last updated: July 2026',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
              SizedBox(height: 24),
              _Section('Data We Collect',
                'StationCast collects the following data to provide the service:\n\n'
                '• Camera and microphone feeds during live broadcasts\n'
                '• Account information (email address) for authentication\n'
                '• Broadcast configuration and settings (stored locally and in Firestore)\n'
                '• Stream performance statistics (bitrate, latency, packet loss)'),
              _Section('How We Use Data',
                '• Camera and microphone data is streamed to your configured SRT server\n'
                '• Account data is used for authentication and settings sync\n'
                '• Performance data is shown to you for monitoring and is not shared'),
              _Section('Data Storage',
                '• Settings are stored locally on your device and optionally synced to Firestore\n'
                '• Stream video/audio is NOT stored by StationCast — it is sent directly to your SRT server\n'
                '• We do not sell or share your data with third parties'),
              _Section('Contact',
                'For questions about this policy, contact your station administrator.'),
            ],
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section(this.title, this.body);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: ControlRoomColors.amber)),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(fontSize: 14, color: Colors.white70, height: 1.5)),
        ],
      ),
    );
  }
}
