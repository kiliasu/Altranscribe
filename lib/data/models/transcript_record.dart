import 'package:altranscribe/data/services/files/text_cleanup.dart';
import 'package:altranscribe/data/services/files/media_paths.dart';

class TranscriptLine {
  TranscriptLine({
    required this.source,
    required this.startMs,
    required this.endMs,
    required this.text,
    this.translation,
    this.translationStatus = 'none',
    this.translationError,
    this.revisedText,
    this.revisedTranslation,
    this.textEdits = const [],
    this.translationEdits = const [],
    this.transcriptionStatus = 'done',
    this.continuous = false,
    this.timingEstimated = false,
  });
  final String source;
  final int startMs;
  final int endMs;
  final String text;
  String transcriptionStatus;
  final bool continuous;
  final bool timingEstimated;
  String? translation;
  String translationStatus;
  String? translationError;
  String? revisedText;
  String? revisedTranslation;
  List<CleanupEdit> textEdits;
  List<CleanupEdit> translationEdits;
  String get displayText => revisedText ?? text;
  String? get displayTranslation => revisedTranslation ?? translation;
  Map<String, Object?> toJson() => {
    'source': source,
    'startMs': startMs,
    'endMs': endMs,
    'text': text,
    'transcriptionStatus': transcriptionStatus,
    'continuous': continuous,
    'timingEstimated': timingEstimated,
    'translation': translation,
    'translationStatus': translationStatus,
    'translationError': translationError,
    'revisedText': revisedText,
    'revisedTranslation': revisedTranslation,
    'textEdits': textEdits.map((edit) => edit.toJson()).toList(),
    'translationEdits': translationEdits.map((edit) => edit.toJson()).toList(),
  };
  factory TranscriptLine.fromJson(Map<String, dynamic> value) => TranscriptLine(
    source: value['source'] as String,
    startMs: value['startMs'] as int,
    endMs: value['endMs'] as int,
    text: value['text'] as String,
    transcriptionStatus: value['transcriptionStatus'] == 'partial'
        ? 'interrupted'
        : value['transcriptionStatus'] as String? ?? 'done',
    continuous: value['continuous'] as bool? ?? false,
    timingEstimated: value['timingEstimated'] as bool? ?? false,
    translation: value['translation'] as String?,
    translationStatus: value['translationStatus'] == 'pending'
        ? 'interrupted'
        : value['translationStatus'] as String? ?? 'none',
    translationError: value['translationError'] as String?,
    revisedText: value['revisedText'] as String?,
    revisedTranslation: value['revisedTranslation'] as String?,
    textEdits: (value['textEdits'] as List? ?? [])
        .map(
          (item) =>
              CleanupEdit.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
    translationEdits: (value['translationEdits'] as List? ?? [])
        .map(
          (item) =>
              CleanupEdit.fromJson(Map<String, dynamic>.from(item as Map)),
        )
        .toList(),
  );
}

class TranscriptRecord {
  TranscriptRecord({
    required this.id,
    required this.createdAt,
    required this.language,
    required this.sources,
    required this.lines,
    this.status = 'recording',
    this.error,
    this.targetLanguage,
    this.translationModel,
    this.title,
    this.summary,
    this.summaryStatus = 'none',
    this.summaryError,
    this.summaryLanguage,
    this.llmProvider,
    this.llmModel,
    this.summaryProvider,
    this.summaryModel,
    this.inputFile,
    this.cleanupOptions,
    this.cleanupStatus = 'none',
    this.cleanupError,
    this.speechProvider,
    this.speechModel,
    this.directTranslation = false,
  });
  final String id;
  final DateTime createdAt;
  final String language;
  final String? speechProvider, speechModel;
  final bool directTranslation;
  final String? targetLanguage;
  final String? translationModel;
  String? summaryLanguage;
  String? summaryProvider;
  String? summaryModel;
  final String? llmProvider;
  final String? llmModel;
  final String? inputFile;
  final Map<String, dynamic>? cleanupOptions;
  String cleanupStatus;
  String? cleanupError;
  String get dateTimeLabel => createdAt.toLocal().toString().split('.').first;
  String? title;
  String? summary;
  String summaryStatus;
  String? summaryError;
  String get displayTitle => title?.trim().isNotEmpty == true
      ? title!
      : inputFile == null
      ? dateTimeLabel
      : mediaFileName(inputFile!);
  final List<String> sources;
  final List<TranscriptLine> lines;
  String status;
  String? error;
  bool get needsSummary => summary?.trim().isNotEmpty != true;

  // Edit a saved snapshot without changing the visible record before disk succeeds.
  TranscriptRecord copy() => TranscriptRecord(
    id: id,
    createdAt: createdAt,
    language: language,
    speechProvider: speechProvider,
    speechModel: speechModel,
    directTranslation: directTranslation,
    sources: sources,
    lines: lines,
    status: status,
    error: error,
    targetLanguage: targetLanguage,
    translationModel: translationModel,
    title: title,
    summary: summary,
    summaryStatus: summaryStatus,
    summaryError: summaryError,
    summaryLanguage: summaryLanguage,
    llmProvider: llmProvider,
    llmModel: llmModel,
    summaryProvider: summaryProvider,
    summaryModel: summaryModel,
    inputFile: inputFile,
    cleanupOptions: cleanupOptions,
    cleanupStatus: cleanupStatus,
    cleanupError: cleanupError,
  );
  Map<String, Object?> toJson() => {
    'version': 5,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'language': language,
    'speechProvider': speechProvider,
    'speechModel': speechModel,
    'directTranslation': directTranslation,
    'targetLanguage': targetLanguage,
    'translationModel': translationModel,
    'title': title,
    'summary': summary,
    'summaryStatus': summaryStatus,
    'summaryError': summaryError,
    'summaryLanguage': summaryLanguage,
    'summaryProvider': summaryProvider,
    'summaryModel': summaryModel,
    'llmProvider': llmProvider,
    'llmModel': llmModel,
    'inputFile': inputFile,
    'cleanupOptions': cleanupOptions,
    'cleanupStatus': cleanupStatus,
    'cleanupError': cleanupError,
    'sources': sources,
    'status': status,
    'error': error,
    'lines': lines.map((line) => line.toJson()).toList(),
  };
  factory TranscriptRecord.fromJson(Map<String, dynamic> value) =>
      TranscriptRecord(
        id: value['id'] as String,
        createdAt: DateTime.parse(value['createdAt'] as String),
        language: value['language'] as String,
        speechProvider: value['speechProvider'] as String?,
        speechModel: value['speechModel'] as String?,
        directTranslation: value['directTranslation'] as bool? ?? false,
        targetLanguage: value['targetLanguage'] as String?,
        translationModel: value['translationModel'] as String?,
        title: value['title'] as String?,
        summary: value['summary'] as String?,
        summaryStatus: value['summaryStatus'] == 'pending'
            ? 'interrupted'
            : value['summaryStatus'] as String? ?? 'none',
        summaryError: value['summaryError'] as String?,
        summaryLanguage: value['summaryLanguage'] as String?,
        summaryProvider: value['summaryProvider'] as String?,
        summaryModel: value['summaryModel'] as String?,
        llmProvider: value['llmProvider'] as String?,
        llmModel: value['llmModel'] as String?,
        inputFile: value['inputFile'] as String?,
        cleanupOptions: value['cleanupOptions'] == null
            ? null
            : Map<String, dynamic>.from(value['cleanupOptions'] as Map),
        cleanupStatus: value['cleanupStatus'] == 'pending'
            ? 'interrupted'
            : value['cleanupStatus'] as String? ?? 'none',
        cleanupError: value['cleanupError'] as String?,
        sources: List<String>.from(value['sources'] as List),
        lines: (value['lines'] as List)
            .map(
              (line) => TranscriptLine.fromJson(
                Map<String, dynamic>.from(line as Map),
              ),
            )
            .toList(),
        status: value['status'] == 'recording' || value['status'] == 'finishing'
            ? 'interrupted'
            : value['status'] as String,
        error: value['error'] as String?,
      );
}
