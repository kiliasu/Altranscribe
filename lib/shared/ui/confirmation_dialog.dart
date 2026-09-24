import 'package:material_ui/material_ui.dart';
import 'package:altranscribe/app/l10n/strings.dart';

Future<bool> confirmRemoval(
  BuildContext context,
  bool english,
  String title,
  String message,
  String key,
) async {
  String t(String key) => strings[key]![english ? 1 : 0];
  final colors = Theme.of(context).colorScheme;
  return await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          constraints: const BoxConstraints(maxWidth: 480),
          title: Text(t(title)),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('cancel')),
            ),
            FilledButton(
              key: Key(key),
              style: FilledButton.styleFrom(
                backgroundColor: colors.error,
                foregroundColor: colors.onError,
              ),
              onPressed: () => Navigator.pop(context, true),
              child: Text(t(title)),
            ),
          ],
        ),
      ) ??
      false;
}
