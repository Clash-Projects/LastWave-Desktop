import 'package:fluent_ui/fluent_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../components/buttons.dart';
import '../theme/tokens.dart';

const _lastFmApiAccountUrl = 'https://www.last.fm/api/account/create';

/// Collapsible "how do I get Last.fm keys?" walkthrough. Shared by the
/// welcome screen and Settings so both explain the same steps.
class LastFmKeyGuide extends StatelessWidget {
  const LastFmKeyGuide({super.key});

  static const _steps = [
    'Sign in to Last.fm in your browser, then open the API account page '
        '(button below).',
    'Fill in a contact email, an application name such as “LastWave” and '
        'a short description. Callback URL and homepage can stay empty.',
    'Submit the form. Last.fm then shows an “API key” and a “Shared '
        'secret”.',
    'Copy both into the fields here and press Save keys.',
    'Press Connect with Last.fm and approve LastWave in the browser tab '
        'that opens.',
  ];

  Future<void> _open() async {
    final uri = Uri.parse(_lastFmApiAccountUrl);
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final secondary = waveIsDark(context)
        ? WaveColors.textSecondary
        : WaveColors.lightTextSecondary;
    return Expander(
      header: const Text('How do I get these keys?', style: WaveType.label),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _steps.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 20,
                    child: Text('${i + 1}.',
                        style: WaveType.meta.copyWith(color: secondary)),
                  ),
                  Expanded(
                    child: Text(_steps[i],
                        style: WaveType.meta.copyWith(color: secondary)),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          WaveButton(
            onPressed: _open,
            child: const Text('Open Last.fm'),
          ),
          const SizedBox(height: 6),
          Text(
            'The keys stay on this device and are only used to talk to '
            'Last.fm.',
            style: WaveType.meta.copyWith(color: secondary),
          ),
        ],
      ),
    );
  }
}
