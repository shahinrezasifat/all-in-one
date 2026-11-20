import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_update_service.dart';

class StartupUpdateGate extends StatefulWidget {
  const StartupUpdateGate({
    super.key,
    required this.child,
    this.checkForUpdate = checkForAppUpdate,
  });

  final Widget child;
  final Future<AppUpdate?> Function() checkForUpdate;

  @override
  State<StartupUpdateGate> createState() => _StartupUpdateGateState();
}

class _StartupUpdateGateState extends State<StartupUpdateGate> {
  late final _check = widget.checkForUpdate();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<AppUpdate?>(
      future: _check,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(
                semanticsLabel: 'Checking for updates',
              ),
            ),
          );
        }
        final update = snapshot.data;
        return update == null ? widget.child : _RequiredUpdateDialog(update);
      },
    );
  }
}

class _RequiredUpdateDialog extends StatefulWidget {
  const _RequiredUpdateDialog(this.update);

  final AppUpdate update;

  @override
  State<_RequiredUpdateDialog> createState() => _RequiredUpdateDialogState();
}

class _RequiredUpdateDialogState extends State<_RequiredUpdateDialog> {
  bool _opening = false;
  bool _launchFailed = false;

  Future<bool> _launch(Uri url) async {
    try {
      return await launchUrl(url, mode: LaunchMode.externalApplication);
    } on Exception {
      return false;
    }
  }

  Future<void> _openUpdate() async {
    setState(() {
      _opening = true;
      _launchFailed = false;
    });
    final update = widget.update;
    final apk = update.apkUrl;
    final opened =
        (apk != null && await _launch(apk)) || await _launch(update.releaseUrl);
    if (!mounted) return;
    setState(() {
      _opening = false;
      _launchFailed = !opened;
    });
  }

  @override
  Widget build(BuildContext context) {
    // The main app is unmounted while the mandatory update is visible.
    return PopScope(
      canPop: false,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape):
              DoNothingAndStopPropagationIntent(),
        },
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              const ModalBarrier(color: Colors.black54, dismissible: false),
              SafeArea(
                child: Center(
                  child: AlertDialog(
                    scrollable: true,
                    title: Text('Update required · v${widget.update.version}'),
                    content: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Install the latest version of All in One to continue.',
                        ),
                        if (widget.update.notes.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Text(widget.update.notes),
                        ],
                        if (_launchFailed) ...[
                          const SizedBox(height: 16),
                          const Text('Could not open the update. Try again.'),
                        ],
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => SystemNavigator.pop(),
                        child: const Text('Exit App'),
                      ),
                      FilledButton(
                        autofocus: true,
                        onPressed: _opening ? null : _openUpdate,
                        child: Text(_opening ? 'Opening…' : 'Update Now'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
