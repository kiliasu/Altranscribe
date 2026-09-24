String mediaFileName(String path) {
  final uri = Uri.tryParse(path);
  if (uri?.scheme == 'content' && uri!.hasFragment) {
    return Uri.decodeComponent(uri.fragment);
  }
  return path.split(RegExp(r'[/\\]')).last;
}

bool isDocumentUri(String path) => Uri.tryParse(path)?.scheme == 'content';
