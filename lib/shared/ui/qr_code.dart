import 'package:material_ui/material_ui.dart';
import 'package:qr/qr.dart';

/// A QR code drawn black on white whatever the theme, since inverted codes
/// scan poorly. [size] includes the quiet zone.
class AltQrCode extends StatelessWidget {
  const AltQrCode({super.key, required this.data, this.size = 200});
  final String data;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'QR code',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: CustomPaint(
        size: Size.square(size),
        painter: _QrPainter(
          QrImage(
            QrCode(
              payload: QrPayload.fromString(data),
              errorCorrectLevel: QrErrorCorrectLevel.medium,
            ),
          ),
        ),
      ),
    ),
  );
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);
  final QrImage image;
  static const quietModules = 4;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFFFFFFF),
    );
    final modules = image.moduleCount + quietModules * 2;
    final cell = size.width / modules;
    final paint = Paint()..color = const Color(0xFF000000);
    for (var row = 0; row < image.moduleCount; row++) {
      for (var column = 0; column < image.moduleCount; column++) {
        if (!image.isDark(row, column)) continue;
        // Overdraw slightly so anti-aliasing never leaves hairline gaps.
        canvas.drawRect(
          Rect.fromLTWH(
            (column + quietModules) * cell,
            (row + quietModules) * cell,
            cell + .5,
            cell + .5,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.image != image;
}
