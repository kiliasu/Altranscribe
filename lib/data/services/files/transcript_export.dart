import 'dart:convert';
import 'dart:typed_data';

import 'package:altranscribe/data/models/transcript_record.dart';
import 'package:altranscribe/data/services/files/media_paths.dart';

enum ExportFormat { text, markdown, html }

extension ExportFormatInfo on ExportFormat {
  String get extension => switch (this) {
    ExportFormat.text => 'txt',
    ExportFormat.markdown => 'md',
    ExportFormat.html => 'html',
  };
  String get mimeType => switch (this) {
    ExportFormat.text => 'text/plain',
    ExportFormat.markdown => 'text/markdown',
    ExportFormat.html => 'text/html',
  };
}

/// Headings in the interface language; the exporter itself has no strings.
class ExportLabels {
  const ExportLabels({
    this.summary = 'Summary',
    this.transcript = 'Transcript',
    this.segments = 'segments',
    this.sourceFile = 'Source file',
    this.sources = const {
      'microphone': 'Microphone',
      'system': 'System audio',
      'file': 'File',
    },
    this.generatedBy = 'Exported from Altranscribe',
  });
  final String summary, transcript, segments, sourceFile, generatedBy;
  final Map<String, String> sources;
}

/// Media types browsers can play from a data URI or a local link.
String mediaMimeType(String name) =>
    switch (name.split('.').last.toLowerCase()) {
      'mp3' => 'audio/mpeg',
      'm4a' || 'aac' => 'audio/mp4',
      'wav' => 'audio/wav',
      'flac' => 'audio/flac',
      'ogg' || 'opus' => 'audio/ogg',
      'wma' => 'audio/x-ms-wma',
      'mp4' => 'video/mp4',
      'mkv' => 'video/x-matroska',
      'webm' => 'video/webm',
      'mov' => 'video/quicktime',
      _ => 'application/octet-stream',
    };

bool isVideoMimeType(String mime) => mime.startsWith('video/');

class TranscriptExporter {
  const TranscriptExporter(this.labels);
  final ExportLabels labels;

  static String timestamp(int ms) {
    final total = ms ~/ 1000;
    final hours = total ~/ 3600;
    final minutes = (total % 3600) ~/ 60;
    final seconds = total % 60;
    String two(int value) => value.toString().padLeft(2, '0');
    return hours > 0
        ? '$hours:${two(minutes)}:${two(seconds)}'
        : '$minutes:${two(seconds)}';
  }

  static String fileName(TranscriptRecord record, ExportFormat format) {
    final base = record.displayTitle
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final stem = base.isEmpty
        ? 'transcript'
        : base.length > 80
        ? base.substring(0, 80).trim()
        : base;
    return '$stem.${format.extension}';
  }

  String _time(TranscriptLine line) =>
      '${line.timingEstimated ? '≈' : ''}${timestamp(line.startMs)}';

  bool _showSource(TranscriptRecord record) => record.sources.length > 1;

  String _source(TranscriptLine line) =>
      labels.sources[line.source] ?? line.source;

  String _meta(TranscriptRecord record) => [
    record.dateTimeLabel,
    '${record.lines.length} ${labels.segments}',
    if (record.inputFile != null) mediaFileName(record.inputFile!),
  ].join(' · ');

  String text(TranscriptRecord record) {
    final out = StringBuffer()
      ..writeln(record.displayTitle)
      ..writeln(_meta(record))
      ..writeln();
    if (record.summary?.trim().isNotEmpty == true) {
      out
        ..writeln(labels.summary)
        ..writeln(record.summary!.trim())
        ..writeln();
    }
    out.writeln(labels.transcript);
    for (final line in record.lines) {
      final prefix =
          '[${_time(line)}]${_showSource(record) ? ' ${_source(line)}:' : ''} ';
      out.writeln('$prefix${line.displayText}');
      final translation = line.displayTranslation;
      if (translation != null && translation.trim().isNotEmpty) {
        out.writeln('${' ' * prefix.length}$translation');
      }
    }
    return out.toString();
  }

  String markdown(TranscriptRecord record) {
    final out = StringBuffer()
      ..writeln('# ${record.displayTitle}')
      ..writeln()
      ..writeln(_meta(record))
      ..writeln();
    if (record.summary?.trim().isNotEmpty == true) {
      out
        ..writeln('## ${labels.summary}')
        ..writeln()
        ..writeln(record.summary!.trim())
        ..writeln();
    }
    out
      ..writeln('## ${labels.transcript}')
      ..writeln();
    for (final line in record.lines) {
      final source = _showSource(record) ? ' ${_source(line)} ·' : '';
      out.writeln('**${_time(line)}**$source ${line.displayText}  ');
      final translation = line.displayTranslation;
      if (translation != null && translation.trim().isNotEmpty) {
        out.writeln('$translation  ');
      }
      out.writeln();
    }
    return out.toString();
  }

  /// [mediaSource] is a URL or data URI for an optional player; segments seek
  /// the player when clicked.
  String html(
    TranscriptRecord record, {
    String? mediaSource,
    String mediaMime = 'audio/mpeg',
  }) {
    final e = const HtmlEscape(HtmlEscapeMode.element).convert;
    final a = const HtmlEscape(HtmlEscapeMode.attribute).convert;
    final out = StringBuffer()
      ..writeln('<!doctype html>')
      ..writeln('<html lang="${record.language == 'zh' ? 'zh-CN' : 'en'}">')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln(
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
      )
      ..writeln('<title>${e(record.displayTitle)}</title>')
      ..writeln('<style>$_style</style>')
      ..writeln('</head>')
      ..writeln('<body>')
      ..writeln('<main>')
      ..writeln('<h1>${e(record.displayTitle)}</h1>')
      ..writeln('<p class="meta">${e(_meta(record))}</p>');
    if (mediaSource != null) {
      final tag = isVideoMimeType(mediaMime) ? 'video' : 'audio';
      out.writeln(
        '<$tag id="player" controls preload="metadata" src="${a(mediaSource)}"></$tag>',
      );
    }
    if (record.summary?.trim().isNotEmpty == true) {
      out
        ..writeln('<section class="summary">')
        ..writeln('<h2>${e(labels.summary)}</h2>')
        ..writeln(
          '<p>${e(record.summary!.trim()).replaceAll('\n', '<br>')}</p>',
        )
        ..writeln('</section>');
    }
    out
      ..writeln('<h2>${e(labels.transcript)}</h2>')
      ..writeln('<ol class="transcript">');
    for (final line in record.lines) {
      out.write('<li data-start="${line.startMs}">');
      out.write('<span class="time">${e(_time(line))}</span>');
      if (_showSource(record)) {
        out.write('<span class="source">${e(_source(line))}</span>');
      }
      out.write('<p class="text">${e(line.displayText)}</p>');
      final translation = line.displayTranslation;
      if (translation != null && translation.trim().isNotEmpty) {
        out.write('<p class="translation">${e(translation)}</p>');
      }
      out.writeln('</li>');
    }
    out
      ..writeln('</ol>')
      ..writeln('<p class="footer">${e(labels.generatedBy)}</p>')
      ..writeln('</main>');
    if (mediaSource != null) out.writeln('<script>$_script</script>');
    out
      ..writeln('</body>')
      ..writeln('</html>');
    return out.toString();
  }

  static String dataUri(Uint8List bytes, String mime) =>
      'data:$mime;base64,${base64Encode(bytes)}';

  static const _style = '''
:root{color-scheme:light dark;--fg:#1c1b1f;--muted:#5f5e63;--bg:#fdfbf7;--panel:#f3efe6;--accent:#7b3f8c}
@media(prefers-color-scheme:dark){:root{--fg:#e6e1e5;--muted:#a8a4ad;--bg:#1a1817;--panel:#2a2724;--accent:#e9a6ff}}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,"Segoe UI",Roboto,"Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif}
main{max-width:52rem;margin:0 auto;padding:2rem 1.25rem 4rem}
h1{font-size:1.8rem;margin:0 0 .25rem}h2{font-size:1.1rem;margin:2rem 0 .75rem}
.meta,.footer{color:var(--muted);font-size:.9rem}
audio,video{display:block;width:100%;margin:1.25rem 0;position:sticky;top:.5rem;background:var(--panel);border-radius:12px}
.summary{background:var(--panel);border-radius:16px;padding:1rem 1.25rem}.summary h2{margin-top:0}
ol.transcript{list-style:none;padding:0;margin:0}
ol.transcript li{padding:.6rem .75rem;border-radius:12px;margin:0 -.75rem}
ol.transcript li.seekable{cursor:pointer}ol.transcript li.seekable:hover,ol.transcript li.active{background:var(--panel)}
.time,.source{font-size:.8rem;color:var(--muted);margin-right:.75rem}
.text{margin:.1rem 0}.translation{margin:.1rem 0 0;color:var(--accent)}
''';

  static const _script = '''
(function(){var p=document.getElementById('player');if(!p)return;var items=[].slice.call(document.querySelectorAll('li[data-start]'));
items.forEach(function(li){li.classList.add('seekable');li.addEventListener('click',function(){p.currentTime=Number(li.dataset.start)/1000;p.play();});});
p.addEventListener('timeupdate',function(){var t=p.currentTime*1000,current=null;items.forEach(function(li){if(Number(li.dataset.start)<=t)current=li;});
items.forEach(function(li){li.classList.toggle('active',li===current);});});})();
''';
}
