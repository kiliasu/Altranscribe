import 'package:material_ui/material_ui.dart';
import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/app/l10n/localized_issue.dart';
import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/features/transcription/realtime_controller.dart';

Future<void> showRenameRecordDialog(
  BuildContext context,
  RealtimeController live,
  TranscriptRecord record,
  bool english,
) {
  String t(String key) => strings[key]![english ? 1 : 0];
  String issue(String value) => localizedIssue(value, english);
  var title = record.displayTitle;
  String? error;
  var saving = false;
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        Future<void> save() async {
          if (saving) return;
          update(() {
            saving = true;
            error = null;
          });
          try {
            await live.renameRecord(record.id, title);
            if (context.mounted) Navigator.pop(context);
          } catch (e) {
            if (context.mounted) {
              update(() {
                saving = false;
                error = issue(e.toString());
              });
            }
          }
        }

        return AlertDialog(
          title: Text(t('renameTitle')),
          content: SizedBox(
            width: 440,
            child: TextFormField(
              key: const Key('record-title-input'),
              initialValue: title,
              autofocus: true,
              maxLength: 120,
              enabled: !saving,
              decoration: InputDecoration(
                labelText: t('recordTitle'),
                errorText: error,
              ),
              onChanged: (value) => title = value,
              onFieldSubmitted: (_) => save(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.pop(context),
              child: Text(t('cancel')),
            ),
            FilledButton(
              onPressed: saving ? null : save,
              child: Text(t('save')),
            ),
          ],
        );
      },
    ),
  );
}
