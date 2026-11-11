import 'package:altranscribe/app/l10n/strings.dart';
import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/shared/ui/elapsed_text.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// When a transcript was made, the way one would say it: today and
/// yesterday by name, this year by its day, earlier ones with their year.
String recordDate(DateTime created, bool english, {DateTime? now}) {
  final at = created.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  final time =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  // Calendar days, whatever the clocks did in between.
  final days = DateTime.utc(
    today.year,
    today.month,
    today.day,
  ).difference(DateTime.utc(at.year, at.month, at.day)).inDays;
  if (days == 0) return english ? 'Today $time' : '今天 $time';
  if (days == 1) return english ? 'Yesterday $time' : '昨天 $time';
  if (at.year == today.year) {
    return english
        ? '${_months[at.month - 1]} ${at.day}, $time'
        : '${at.month}月${at.day}日 $time';
  }
  return english
      ? '${_months[at.month - 1]} ${at.day}, ${at.year}'
      : '${at.year}年${at.month}月${at.day}日';
}

/// A transcript in one line under its title: when it was made, how long it
/// runs and how many lines it has. Its state is named only when it is not
/// simply saved, and the date only when the title is not the date itself.
String recordLine(TranscriptRecord record, bool english, {DateTime? now}) {
  String t(String key) => strings[key]![english ? 1 : 0];
  final titled =
      record.title?.trim().isNotEmpty == true || record.inputFile != null;
  return [
    if (titled) recordDate(record.createdAt, english, now: now),
    if (record.lines.isNotEmpty)
      durationLabel(Duration(milliseconds: record.lines.last.endMs)),
    '${record.lines.length} ${t('segments')}',
    if (record.status != 'completed') t('recordStatus_${record.status}'),
  ].join(' · ');
}
