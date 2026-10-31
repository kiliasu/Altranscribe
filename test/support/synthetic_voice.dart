import 'dart:math' as math;
import 'dart:typed_data';

/// A voiced, syllable-like sound that Silero hears as speech: a 100-140 Hz
/// glottal buzz through two moving formants, four syllables a second.
Float32List syntheticVoice(int ms, {double peak = .5}) {
  final random = math.Random(ms);
  final samples = Float32List(ms * 16);
  var phase = 0.0;
  var a1 = 0.0, a2 = 0.0, b1 = 0.0, b2 = 0.0;
  (double, double) resonator(double frequency, double bandwidth) {
    final radius = math.exp(-math.pi * bandwidth / 16000);
    return (
      2 * radius * math.cos(2 * math.pi * frequency / 16000),
      -radius * radius,
    );
  }

  var loudest = 0.0;
  for (var i = 0; i < samples.length; i++) {
    final time = i / 16000;
    phase += (120 + 20 * math.sin(2 * math.pi * 1.3 * time)) / 16000;
    final pulse = phase - phase.floorToDouble() < .05 ? 1.0 : 0.0;
    final syllable = time * 4 % 1;
    final (c1, c2) = resonator(syllable < .5 ? 700 : 400, 90);
    final (d1, d2) = resonator(syllable < .5 ? 1200 : 2200, 120);
    final first = pulse + .02 * (random.nextDouble() - .5) + c1 * a1 + c2 * a2;
    a2 = a1;
    a1 = first;
    final second = first + d1 * b1 + d2 * b2;
    b2 = b1;
    b1 = second;
    samples[i] = second * math.pow(math.sin(math.pi * syllable), 2);
    loudest = math.max(loudest, samples[i].abs());
  }
  for (var i = 0; i < samples.length; i++) {
    samples[i] = samples[i] / loudest * peak;
  }
  return samples;
}

/// Voice and silence in turn: positive lengths are speech, negative ones
/// pauses, in milliseconds.
Float32List speechWithPauses(List<int> parts, {double peak = .5}) =>
    Float32List.fromList([
      for (final ms in parts)
        ...(ms > 0 ? syntheticVoice(ms, peak: peak) : Float32List(-ms * 16)),
    ]);

/// 16-bit little-endian PCM, as the file decoders deliver it.
Uint8List pcm16(Float32List samples) {
  final data = ByteData(samples.length * 2);
  for (var i = 0; i < samples.length; i++) {
    data.setInt16(
      2 * i,
      (samples[i] * 32767).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}
