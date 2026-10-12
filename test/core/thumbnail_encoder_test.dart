import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lectern/core/images/thumbnail_encoder.dart';

import '../helpers/fixtures.dart';

void main() {
  test('fitSize keeps the aspect ratio and never upscales', () {
    expect(ThumbnailEncoder.fitSize(800, 1200), (width: 400, height: 600));
    expect(ThumbnailEncoder.fitSize(1200, 800), (width: 400, height: 267));
    expect(ThumbnailEncoder.fitSize(100, 150), (width: 100, height: 150));
  });

  test('encodes BGRA pixels as a bounded JPEG', () {
    // 800x1000 opaque pure blue in BGRA.
    final pixels = Uint8List(800 * 1000 * 4);
    for (var i = 0; i < pixels.length; i += 4) {
      pixels[i] = 255; // B
      pixels[i + 3] = 255; // A
    }
    final jpeg = ThumbnailEncoder.encodeJpegSync(
      RawPixels(
        bytes: pixels,
        width: 800,
        height: 1000,
        order: PixelOrder.bgra,
      ),
    );
    final decoded = img.decodeJpg(jpeg)!;
    expect((decoded.width, decoded.height), (400, 500));
    final pixel = decoded.getPixel(200, 250);
    expect(pixel.b, greaterThan(200));
    expect(pixel.r, lessThan(60));
  });

  test('transparent pixels become white', () {
    final pixels = Uint8List(10 * 10 * 4); // fully transparent
    final jpeg = ThumbnailEncoder.encodeJpegSync(
      RawPixels(
        bytes: pixels,
        width: 10,
        height: 10,
        order: PixelOrder.rgbaPremultiplied,
      ),
    );
    final pixel = img.decodeJpg(jpeg)!.getPixel(5, 5);
    expect(pixel.r, greaterThan(240));
    expect(pixel.g, greaterThan(240));
  });

  test('decodes an encoded image at thumbnail size', () async {
    final jpeg = await const ThumbnailEncoder().fromEncodedImage(
      pngImage(width: 1000, height: 1500),
    );
    expect(jpeg, isNotNull);
    final decoded = img.decodeJpg(jpeg!)!;
    expect((decoded.width, decoded.height), (400, 600));
  });

  test('returns null for undecodable data', () async {
    expect(
      await const ThumbnailEncoder().fromEncodedImage(
        Uint8List.fromList([1, 2, 3, 4]),
      ),
      isNull,
    );
  });
}
