import 'package:material_ui/material_ui.dart';

import 'app/app.dart';
import 'features/captions/caption_app.dart';
import 'shared/platform/mobile_platform.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MobilePlatform.initialize();
  runApp(const AltranscribeApp());
}

@pragma('vm:entry-point')
void captionMain() => runApp(const CaptionApp());
