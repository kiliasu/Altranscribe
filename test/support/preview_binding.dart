import 'package:flutter_test/flutter_test.dart';

/// Render the same shadows as the app instead of the test runner's solid silhouettes.
class PreviewBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get disableShadows => false;
}
