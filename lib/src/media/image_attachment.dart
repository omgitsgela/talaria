import 'dart:convert';
import 'dart:typed_data';

import '../gateway/client.dart';

class PendingAttachment {
  const PendingAttachment(
      {required this.ref,
      required this.filename,
      required this.sizeBytes,
      this.bytes});

  final String ref;
  final String filename;
  final int sizeBytes;
  final Uint8List? bytes;
}

class StagedImage {
  StagedImage(Map<String, dynamic> result)
      : path = result['path'] as String,
        count = result['count'] as int?,
        metadata = Map.unmodifiable(result);

  final String path;
  final int? count;
  final Map<String, dynamic> metadata;
}

class ImageAttachmentService {
  ImageAttachmentService(this.client, {required this.sessionId});

  final GatewayClient client;
  final String sessionId;

  // tui_gateway/prompt_attachments.py: _ATTACH_BYTES_MAX_BYTES.
  static const maxBytes = 25 * 1024 * 1024;

  static void validate(List<int> bytes) {
    if (bytes.isEmpty) throw GatewayError('Image is empty');
    if (bytes.length > maxBytes) {
      throw GatewayError('Image is too large. The gateway limit is 25 MiB.');
    }
  }

  Future<StagedImage> attach(List<int> bytes,
      {required String filename, String ext = ''}) async {
    validate(bytes);
    final result = await client.request('image.attach_bytes', {
      'session_id': sessionId,
      'content_base64': base64Encode(bytes),
      'filename': filename,
      if (ext.isNotEmpty) 'ext': ext,
    });
    return StagedImage(result);
  }

  Future<Map<String, dynamic>> detach(String path, {int timeoutMs = 120000}) =>
      client.request(
          'image.detach', {'session_id': sessionId, 'path': path}, timeoutMs);
}
