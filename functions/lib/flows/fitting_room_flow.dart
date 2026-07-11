import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:google_cloud_storage/google_cloud_storage.dart' show ObjectMetadata;
import 'package:schemantic/schemantic.dart';
import '../tools/fitting_tool.dart';
import '../ai.dart';

Future<String> saveToStorage(String base64Str, String folderPath) async {
  if (base64Str.contains(';base64,')) {
    base64Str = base64Str.split(';base64,').last;
  }
  final bytes = base64Decode(base64Str);
  final uuidStr = DateTime.now().millisecondsSinceEpoch.toString();
  final objectName = '$folderPath/$uuidStr.png';
  final bucketName = Platform.environment['GCS_BUCKET'] ?? 'flutter-firebase-fashion.firebasestorage.app';
  
  final app = FirebaseApp.instance;
  final storage = app.storage();
  final bucket = storage.bucket(bucketName);
  await bucket.object(objectName).upload(bytes, metadata: ObjectMetadata(contentType: 'image/png'));
  return 'gs://$bucketName/$objectName';
}

Future<Uint8List> downloadFromStorage(String gcsUrl) async {
  final uri = Uri.parse(gcsUrl);
  final bucketName = uri.host;
  final objectPath = uri.path.substring(1);
  
  final app = FirebaseApp.instance;
  final storage = app.storage();
  final bucket = storage.bucket(bucketName);
  return await bucket.object(objectPath).download();
}

final fittingRoomFlow = ai.defineFlow(
  name: 'fittingRoomFlow',
  inputSchema: SchemanticType.from(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'userImageBase64': {'type': 'string'},
        'productImageBase64': {'type': 'string'},
        'userId': {'type': 'string'}
      },
      'required': ['userImageBase64', 'productImageBase64', 'userId']
    },
    parse: (json) => json,
  ),
  outputSchema: SchemanticType.from(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'gcsUrl': {'type': 'string'},
        'imageBytesBase64': {'type': 'string'}
      },
      'required': ['gcsUrl', 'imageBytesBase64']
    },
    parse: (json) => json,
  ),
  fn: (input, context) async {
    final userId = input['userId'] as String;

    final userUri = await saveToStorage(input['userImageBase64'] as String, 'users/$userId/uploads');
    final productUri = await saveToStorage(input['productImageBase64'] as String, 'users/$userId/products');

    final runResult = await fittingTool.run({
      'user_image': userUri,
      'accessories': [productUri],
    });
    final toolResult = runResult.result;

    final bytes = await downloadFromStorage(toolResult['gcs_url'] as String);
    return {
      'gcsUrl': toolResult['gcs_url'] as String,
      'imageBytesBase64': base64Encode(bytes),
    };
  },
);
