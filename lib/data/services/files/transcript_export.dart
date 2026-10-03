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
    this.followPlayback = 'Follow playback',
  });
  final String summary, transcript, segments, sourceFile, generatedBy;
  final String followPlayback;
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
        '<div class="playback-bar"><div class="playback $tag">'
        '<$tag id="player" controls preload="metadata" src="${a(mediaSource)}"></$tag>'
        '<label class="follow"><span>${e(labels.followPlayback)}</span>'
        '<input id="follow-playback" type="checkbox" role="switch" checked></label></div></div>',
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
      out.write('<li data-start="${line.startMs}" data-end="${line.endMs}">');
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
:root{color-scheme:light dark;
--surface:#fef9f0;--surface-low:#f8f3ea;--surface-container:#f2ede4;--surface-high:#ece8de;--surface-highest:#e7e2d9;
--on-surface:#1e1b15;--on-surface-variant:#4c4639;--outline:#7d7668;--outline-variant:#cec6b6;
--primary:#8e437d;--on-primary:#fff;--primary-container:#ffd7f3;--on-primary-container:#742a64;
--shadow:rgba(0,0,0,.14)}
@media(prefers-color-scheme:dark){:root{
--surface:#17130a;--surface-low:#1e1b15;--surface-container:#221f19;--surface-high:#2d2a23;--surface-highest:#38342d;
--on-surface:#e7e2d9;--on-surface-variant:#cec6b6;--outline:#979081;--outline-variant:#4c4639;
--primary:#fface9;--on-primary:#5a0e4c;--primary-container:#742a64;--on-primary-container:#ffd7f3;
--shadow:rgba(0,0,0,.45)}}
*{box-sizing:border-box}
body{margin:0;background:var(--surface);color:var(--on-surface);font:16px/1.6 system-ui,"Segoe UI",Roboto,"Noto Sans SC","PingFang SC","Microsoft YaHei",sans-serif;-webkit-text-size-adjust:100%}
main{max-width:48rem;margin:0 auto;padding:40px 24px 64px}
h1{font-size:1.75rem;line-height:1.3;font-weight:600;margin:0 0 8px}
h2{font-size:1.125rem;line-height:1.4;font-weight:600;margin:32px 0 12px}
.meta,.footer{color:var(--on-surface-variant);font-size:.875rem;margin:0}
.footer{margin-top:32px}
/* The band keeps text that scrolls under the player out of sight. */
.playback-bar{position:sticky;top:0;z-index:2;margin:12px 0;padding:12px 0;background:var(--surface)}
.playback{display:flex;flex-wrap:wrap;align-items:center;gap:8px 16px;padding:10px 16px 10px 10px;border-radius:28px;background:var(--surface-high);box-shadow:0 1px 3px var(--shadow),0 4px 12px var(--shadow)}
.playback audio{flex:1 1 18rem;min-width:0;height:44px}
audio::-webkit-media-controls-enclosure{background:transparent;border-radius:22px}
audio::-webkit-media-controls-panel{background:transparent}
.playback.video{padding:12px 16px 12px 12px}
.playback video{flex:1 0 100%;display:block;width:100%;max-height:min(40vh,24rem);border-radius:18px;background:#000}
.follow{display:flex;align-items:center;gap:12px;margin-left:auto;padding-left:6px;font-size:.875rem;font-weight:500;color:var(--on-surface-variant);cursor:pointer;user-select:none}
.follow input{appearance:none;-webkit-appearance:none;position:relative;flex:none;width:52px;height:32px;margin:0;border:2px solid var(--outline);border-radius:16px;background:var(--surface-highest);cursor:pointer;transition:background-color .2s,border-color .2s}
.follow input::before{content:"";position:absolute;top:50%;left:6px;width:16px;height:16px;border-radius:50%;background:var(--outline);transform:translateY(-50%);transition:left .2s,width .2s,height .2s,background-color .2s}
.follow input:checked{border-color:var(--primary);background:var(--primary)}
.follow input:checked::before{left:22px;width:24px;height:24px;background:var(--on-primary)}
.follow input:focus-visible{outline:2px solid var(--primary);outline-offset:2px}
.summary{margin-top:24px;padding:20px;border-radius:24px;background:var(--surface-container)}
.summary h2{margin:0 0 8px}.summary p{margin:0}
ol.transcript{list-style:none;display:flex;flex-direction:column;gap:4px;padding:0;margin:0}
ol.transcript li{padding:12px 20px;border-radius:20px;transition:background-color .2s,color .2s,padding .2s,margin .2s,box-shadow .2s}
ol.transcript li.seekable{cursor:pointer}
ol.transcript li.seekable:hover{background:var(--surface-low)}
.time,.source{font-size:.75rem;line-height:1.3;font-weight:500;letter-spacing:.02em;color:var(--on-surface-variant);font-variant-numeric:tabular-nums}
.source::before{content:"·";margin:0 6px}
.text,.translation{margin:4px 0 0;font-size:1.0625rem;transition:font-size .2s}
.translation{margin-top:2px;color:var(--primary);font-weight:500}
ol.transcript li.active{padding:16px 20px;margin:4px 0;background:var(--primary-container);color:var(--on-primary-container);box-shadow:0 1px 3px var(--shadow)}
ol.transcript li.active .time,ol.transcript li.active .source{color:var(--on-primary-container)}
ol.transcript li.active .text,ol.transcript li.active .translation{font-size:1.1875rem}
ol.transcript li.active .translation{color:var(--on-primary-container);font-weight:600}
@media(max-width:600px){main{padding:24px 16px 48px}.playback-bar{padding:8px 0}.summary{padding:16px}ol.transcript li{padding:12px 16px}ol.transcript li.active{padding:14px 16px}}
@media(prefers-reduced-motion:reduce){*{transition:none!important}}
@media print{.playback-bar{display:none}ol.transcript li.active{background:none;box-shadow:none;padding:12px 20px;margin:0}}
''';

  static const _script = '''
(function(){
  var p=document.getElementById('player');if(!p)return;
  var follow=document.getElementById('follow-playback');
  var bar=document.querySelector('.playback');
  var items=[].slice.call(document.querySelectorAll('li[data-start]'));
  var active=null;
  function update(force,instant){
    var t=p.currentTime*1000,current=null,nearest=null,distance=Infinity;
    items.forEach(function(li){
      var start=Number(li.dataset.start),end=Number(li.dataset.end);
      if(start<=t&&t<end&&(!current||start>=Number(current.dataset.start)))current=li;
      var gap=t<start?start-t:Math.max(0,t-end);
      if(gap<distance||(gap===distance&&start>Number(nearest.dataset.start))){nearest=li;distance=gap;}
    });
    current=current||nearest;
    var changed=current!==active;
    if(changed){
      if(active){active.classList.remove('active');active.removeAttribute('aria-current');}
      active=current;
      if(active){active.classList.add('active');active.setAttribute('aria-current','true');}
    }
    if(!current||!follow.checked||(!changed&&!force))return;
    var rect=current.getBoundingClientRect(),top=bar.getBoundingClientRect().bottom+16;
    if(force||rect.top<top||rect.bottom>window.innerHeight-24){
      var reduced=window.matchMedia('(prefers-reduced-motion: reduce)').matches;
      window.scrollTo({top:Math.max(0,window.scrollY+rect.top-Math.max(top,(window.innerHeight-rect.height)/2)),
        behavior:instant||reduced?'auto':'smooth'});
    }
  }
  items.forEach(function(li){
    li.classList.add('seekable');
    li.addEventListener('click',function(){
      p.currentTime=Number(li.dataset.start)/1000;update(true,true);
      var playing=p.play();if(playing)playing.catch(function(){});
    });
  });
  p.addEventListener('timeupdate',function(){update(p.seeking,p.seeking);});
  ['seeking','seeked'].forEach(function(event){
    p.addEventListener(event,function(){update(true,true);});
  });
  ['loadedmetadata','play','ended'].forEach(function(event){
    p.addEventListener(event,function(){update(false,true);});
  });
  follow.addEventListener('change',function(){update(true,true);});
})();
''';
}
