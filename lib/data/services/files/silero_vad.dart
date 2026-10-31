import 'dart:math' as math;
import 'dart:typed_data';

/// The Silero VAD network that whisper.cpp runs, read from the same bundled
/// ggml file and evaluated in Dart, so files can be cut at pauses on any
/// platform and without a Whisper program. It gives one speech probability
/// per 512-sample (32 ms) window of 16 kHz audio and keeps its recurrent
/// state between calls, as whisper.cpp does.
class SileroVad {
  SileroVad._(this._basis, this._layers, this._lstm, this._final);

  /// Reads the ggml file whisper.cpp converts Silero's weights into.
  factory SileroVad.parse(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    var offset = 0;
    int next() {
      final value = data.getInt32(offset, Endian.little);
      offset += 4;
      return value;
    }

    if (data.getUint32(0, Endian.little) != 0x67676d6c) {
      throw const FormatException('Not a ggml VAD model');
    }
    offset = 4;
    final typeLength = next(); // model type, such as "silero-16k"
    offset += typeLength + 12; // and the version
    if (next() != window || next() != 64 || next() != 4) {
      throw const FormatException('Unexpected VAD model shape');
    }
    offset += 4 * 3 * 4 + 4 * 4; // encoder, LSTM and final sizes
    final tensors = <String, Float32List>{};
    while (offset < bytes.length) {
      final dimensions = next();
      final nameLength = next();
      final half = next() == 1;
      var count = 1;
      for (var i = 0; i < dimensions; i++) {
        count *= next();
      }
      final name = String.fromCharCodes(bytes, offset, offset + nameLength);
      offset += nameLength;
      final values = Float32List(count);
      for (var i = 0; i < count; i++) {
        if (half) {
          values[i] = _half(data.getUint16(offset + 2 * i, Endian.little));
        } else {
          values[i] = data.getFloat32(offset + 4 * i, Endian.little);
        }
      }
      offset += count * (half ? 2 : 4);
      tensors[name] = values;
    }
    Float32List tensor(String name) =>
        tensors['_model.$name'] ??
        (throw FormatException('VAD model lacks $name'));
    const channels = [(129, 128, 1), (128, 64, 2), (64, 64, 2), (64, 128, 1)];
    return SileroVad._(
      tensor('stft.forward_basis_buffer'),
      [
        for (final (i, (input, output, stride)) in channels.indexed)
          _Conv(
            tensor('encoder.$i.reparam_conv.weight'),
            tensor('encoder.$i.reparam_conv.bias'),
            input,
            output,
            stride,
          ),
      ],
      (
        tensor('decoder.rnn.weight_ih'),
        tensor('decoder.rnn.weight_hh'),
        tensor('decoder.rnn.bias_ih'),
        tensor('decoder.rnn.bias_hh'),
      ),
      (tensor('decoder.decoder.2.weight'), tensor('decoder.decoder.2.bias')[0]),
    );
  }

  static const window = 512;
  static const _hidden = 128;

  final Float32List _basis;
  final List<_Conv> _layers;
  final (Float32List, Float32List, Float32List, Float32List) _lstm;
  final (Float32List, double) _final;
  final _h = Float32List(_hidden);
  final _c = Float32List(_hidden);
  final _padded = Float32List(window + 128);
  final _spectrum = Float32List(129 * 4);
  final _gates = Float32List(4 * _hidden);

  /// Forgets what came before, for audio that does not continue the last.
  void reset() {
    _h.fillRange(0, _hidden, 0);
    _c.fillRange(0, _hidden, 0);
  }

  /// One probability per window of [samples] (16 kHz, -1 to 1). A partial
  /// last window is padded with silence, as whisper.cpp pads it.
  Float32List probabilities(Float32List samples) {
    final count = (samples.length + window - 1) ~/ window;
    final result = Float32List(count);
    final frame = Float32List(window);
    for (var i = 0; i < count; i++) {
      final start = i * window;
      final end = math.min(start + window, samples.length);
      frame.setRange(0, end - start, samples, start);
      if (end - start < window) frame.fillRange(end - start, window, 0);
      result[i] = _probability(frame);
    }
    return result;
  }

  double _probability(Float32List frame) {
    // Reflect 64 samples at each edge, then a 256-tap Fourier basis with a
    // 128-sample hop gives four frames of 129 magnitudes.
    final padded = _padded;
    padded.setRange(64, 64 + window, frame);
    for (var i = 1; i <= 64; i++) {
      padded[64 - i] = frame[i];
      padded[63 + window + i] = frame[window - 1 - i];
    }
    final basis = _basis;
    final spectrum = _spectrum;
    for (var t = 0; t < 4; t++) {
      final base = t * 128;
      for (var f = 0; f < 129; f++) {
        var real = 0.0;
        var imaginary = 0.0;
        final r = f * 256;
        final m = (f + 129) * 256;
        for (var k = 0; k < 256; k++) {
          final x = padded[base + k];
          real += basis[r + k] * x;
          imaginary += basis[m + k] * x;
        }
        spectrum[f * 4 + t] = math.sqrt(real * real + imaginary * imaginary);
      }
    }
    var features = spectrum;
    var length = 4;
    for (final layer in _layers) {
      features = layer.apply(features, length);
      length = layer.outputLength(length);
    }

    // The encoder leaves one frame of 128 channels for the LSTM cell.
    final (inputWeights, hiddenWeights, inputBias, hiddenBias) = _lstm;
    final h = _h;
    final c = _c;
    final gates = _gates;
    for (var r = 0; r < 4 * _hidden; r++) {
      var sum = inputBias[r] + hiddenBias[r];
      final row = r * _hidden;
      for (var j = 0; j < _hidden; j++) {
        sum +=
            inputWeights[row + j] * features[j] + hiddenWeights[row + j] * h[j];
      }
      gates[r] = sum;
    }
    for (var j = 0; j < _hidden; j++) {
      final input = _sigmoid(gates[j]);
      final forget = _sigmoid(gates[_hidden + j]);
      final cell = _tanh(gates[2 * _hidden + j]);
      final output = _sigmoid(gates[3 * _hidden + j]);
      c[j] = forget * c[j] + input * cell;
      h[j] = output * _tanh(c[j]);
    }
    final (weights, bias) = _final;
    var logit = bias;
    for (var j = 0; j < _hidden; j++) {
      if (h[j] > 0) logit += weights[j] * h[j];
    }
    return _sigmoid(logit);
  }

  static double _sigmoid(double x) => 1 / (1 + math.exp(-x));

  static double _tanh(double x) {
    if (x > 20) return 1;
    if (x < -20) return -1;
    final e = math.exp(2 * x);
    return (e - 1) / (e + 1);
  }

  static double _half(int bits) {
    final sign = bits & 0x8000 == 0 ? 1.0 : -1.0;
    final exponent = (bits >> 10) & 0x1f;
    final fraction = bits & 0x3ff;
    if (exponent == 0) return sign * fraction / 16777216;
    if (exponent == 31) {
      return fraction == 0 ? sign * double.infinity : double.nan;
    }
    return sign * (1024 + fraction) * math.pow(2, exponent - 25).toDouble();
  }
}

/// A 3-tap convolution with zero padding of one, then ReLU. Weights are
/// [output][input][tap], features [channel][time].
class _Conv {
  _Conv(this.weights, this.bias, this.input, this.output, this.stride);
  final Float32List weights;
  final Float32List bias;
  final int input;
  final int output;
  final int stride;

  int outputLength(int length) => (length - 1) ~/ stride + 1;

  Float32List apply(Float32List features, int length) {
    final outLength = outputLength(length);
    final result = Float32List(output * outLength);
    for (var o = 0; o < output; o++) {
      for (var t = 0; t < outLength; t++) {
        var sum = bias[o];
        for (var i = 0; i < input; i++) {
          final w = (o * input + i) * 3;
          final row = i * length;
          for (var k = 0; k < 3; k++) {
            final position = t * stride + k - 1;
            if (position >= 0 && position < length) {
              sum += weights[w + k] * features[row + position];
            }
          }
        }
        result[o * outLength + t] = sum > 0 ? sum : 0;
      }
    }
    return result;
  }
}
