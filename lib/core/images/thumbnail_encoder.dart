import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Byte order of raw 8-bit, 4-channel pixels.
enum PixelOrder {
  /// RGBA with premultiplied alpha (Flutter's `ImageByteFormat.rawRgba`).
  rgbaPremultiplied,

  /// BGRA, as produced by PDFium.
  bgra,
}

/// Uncompressed pixels, suitable for sending to another isolate.
class RawPixels {
  const RawPixels({
    required this.bytes,
    required this.width,
    required this.height,
    required this.order,
  });

  final Uint8List bytes;
  final int width;
  final int height;
  final PixelOrder order;
}

/// Produces small JPEG cover thumbnails.
///
/// Thumbnails are bounded to [maxWidth] x [maxHeight] so library grids never
/// decode full-size cover art, and stored as JPEG to keep large libraries
/// small on disk (a PNG of the same cover is several times larger).
class ThumbnailEncoder {
  const ThumbnailEncoder();

  static const maxWidth = 400;
  static const maxHeight = 600;
  static const quality = 82;

  /// Source images with more pixels than this are not decoded at all.
  static const maxSourcePixels = 50 * 1000 * 1000;

  /// Size that fits [width] x [height] into the thumbnail box, keeping the
  /// aspect ratio and never upscaling.
  static ({int width, int height}) fitSize(num width, num height) {
    final scale = math.min(1.0, math.min(maxWidth / width, maxHeight / height));
    return (
      width: math.max(1, (width * scale).round()),
      height: math.max(1, (height * scale).round()),
    );
  }

  /// Decodes an encoded image (JPEG, PNG, GIF, WebP...) directly at
  /// thumbnail size using the platform decoder, which avoids holding the
  /// full-resolution bitmap in memory, then encodes it as JPEG.
  ///
  /// Returns null if the image cannot be decoded or is unreasonably large.
  Future<Uint8List?> fromEncodedImage(Uint8List encoded) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final width = descriptor.width;
      final height = descriptor.height;
      if (width <= 0 || height <= 0 || width * height > maxSourcePixels) {
        return null;
      }
      final target = fitSize(width, height);
      codec = await descriptor.instantiateCodec(
        targetWidth: target.width,
        targetHeight: target.height,
      );
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      return await encodePixels(
        RawPixels(
          bytes: data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          ),
          width: image.width,
          height: image.height,
          order: PixelOrder.rgbaPremultiplied,
        ),
      );
    } on Exception {
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// Encodes raw pixels as a JPEG on a background isolate, scaling down to
  /// the thumbnail box if needed.
  Future<Uint8List> encodePixels(RawPixels pixels) {
    return Isolate.run(() => encodeJpegSync(pixels));
  }

  /// Synchronous JPEG encoding. Transparent areas are composited onto white
  /// because JPEG has no alpha channel.
  static Uint8List encodeJpegSync(RawPixels pixels) {
    final rgb = Uint8List(pixels.width * pixels.height * 3);
    final src = pixels.bytes;
    for (var i = 0, o = 0; o < rgb.length; i += 4, o += 3) {
      final int r;
      final int g;
      final int b;
      final a = src[i + 3];
      switch (pixels.order) {
        case PixelOrder.rgbaPremultiplied:
          r = src[i];
          g = src[i + 1];
          b = src[i + 2];
        case PixelOrder.bgra:
          r = src[i + 2];
          g = src[i + 1];
          b = src[i];
      }
      // Premultiplied colour over white: c + (255 - a). PDFium output is
      // opaque, so the same formula is a no-op there.
      final white = 255 - a;
      rgb[o] = math.min(255, r + white);
      rgb[o + 1] = math.min(255, g + white);
      rgb[o + 2] = math.min(255, b + white);
    }

    var image = img.Image.fromBytes(
      width: pixels.width,
      height: pixels.height,
      bytes: rgb.buffer,
      numChannels: 3,
    );
    final target = fitSize(pixels.width, pixels.height);
    if (target.width != pixels.width || target.height != pixels.height) {
      image = img.copyResize(
        image,
        width: target.width,
        height: target.height,
        interpolation: img.Interpolation.average,
      );
    }
    return img.JpegEncoder(quality: quality).encode(image);
  }
}
