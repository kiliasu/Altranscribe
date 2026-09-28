import 'package:material_ui/material_ui.dart';

import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/services/cloud/cloud_provider.dart';
import 'package:altranscribe/data/services/cloud/credential_store.dart';

/// Saves one API key: a fixed cloud provider's, or a named key such as the one
/// for an OpenAI-compatible service.
class CloudKeyEditor extends StatefulWidget {
  const CloudKeyEditor({
    super.key,
    this.provider,
    this.name,
    this.label,
    required this.credentials,
    required this.english,
    required this.enabled,
    this.onSaved,
    this.onChanged,
  }) : assert(provider != null || name != null);
  final CloudProvider? provider;
  final String? name;
  final String? label;
  final CredentialStore credentials;
  final bool english, enabled;
  final Future<void> Function()? onSaved;
  final VoidCallback? onChanged;
  String get credentialName => name ?? provider!.name;
  @override
  State<CloudKeyEditor> createState() => CloudKeyEditorState();
}

class CloudKeyEditorState extends State<CloudKeyEditor> {
  final input = TextEditingController();
  bool configured = false, busy = false;
  String? error;
  String t(String key) => strings[key]![widget.english ? 1 : 0];
  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(CloudKeyEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.credentialName != widget.credentialName) {
      input.clear();
      configured = false;
      error = null;
      load();
    }
  }

  Future<void> load() async {
    final name = widget.credentialName;
    try {
      final value = (await widget.credentials.readNamed(name)).isNotEmpty;
      if (mounted && name == widget.credentialName) {
        setState(() => configured = value);
      }
    } catch (_) {
      if (mounted) setState(() => error = t('cloudKeyReadFailed'));
    }
  }

  /// Used by the containing dialog before saving or checking its configuration.
  Future<void> savePending() async {
    if (input.text.trim().isEmpty) return;
    if (busy) throw StateError('cloudKeySavePending');
    await persist(input.text);
  }

  Future<void> persist(String value) async {
    final name = widget.credentialName;
    await widget.credentials.writeNamed(name, value);
    if (!mounted || name != widget.credentialName) return;
    input.clear();
    await load();
  }

  Future<void> save({bool remove = false}) async {
    if (!widget.enabled || busy || (!remove && input.text.trim().isEmpty)) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await persist(remove ? '' : input.text);
      if (mounted) widget.onChanged?.call();
      if (mounted && !remove) await widget.onSaved?.call();
    } catch (_) {
      if (mounted) setState(() => error = t('cloudKeySaveFailed'));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: Key('api-key-${widget.credentialName}'),
          controller: input,
          onChanged: (_) => widget.onChanged?.call(),
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          enabled: widget.enabled && !busy,
          decoration: InputDecoration(
            labelText: widget.label ?? '${widget.provider!.label} API Key',
            helperText: t(configured ? 'cloudKeySaved' : 'cloudKeyNotSaved'),
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: widget.enabled && !busy ? save : null,
              child: Text(t('cloudSaveKey')),
            ),
            if (configured)
              TextButton(
                onPressed: widget.enabled && !busy
                    ? () => save(remove: true)
                    : null,
                child: Text(t('cloudRemoveKey')),
              ),
          ],
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
  );
}
