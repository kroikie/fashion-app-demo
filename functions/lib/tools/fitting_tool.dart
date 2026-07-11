import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:firebase_functions/firebase_functions.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_admin_sdk/firebase_admin_sdk.dart';
import 'package:google_cloud_storage/google_cloud_storage.dart' show ObjectMetadata;
import 'package:schemantic/schemantic.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import '../ai.dart';

final geminiApiKey = defineString('GEMINI_API_KEY');

int stableSeed(String s) {
  final bytes = utf8.encode(s);
  final digest = sha256.convert(bytes);
  return ByteData.sublistView(Uint8List.fromList(digest.bytes)).getInt32(0) & 0x7FFFFFFF;
}

Future<Uint8List> fetchImageBytes(String imageIdentifier) async {
  if (imageIdentifier.startsWith('gs://')) {
    final uri = Uri.parse(imageIdentifier);
    final bucketName = uri.host;
    final objectPath = uri.path.substring(1);
    
    final app = FirebaseApp.instance;
    final storage = app.storage();
    final bucket = storage.bucket(bucketName);
    return await bucket.object(objectPath).download();
  } else if (imageIdentifier.startsWith('data:image') || (!imageIdentifier.contains('/') && !imageIdentifier.contains('.'))) {
    try {
      if (imageIdentifier.contains(';base64,')) {
        final base64Str = imageIdentifier.split(';base64,').last;
        return base64Decode(base64Str);
      }
      return base64Decode(imageIdentifier);
    } catch (_) {
      // Ignored
    }
  }

  // File fallback
  for (final localPath in [
    '../flutter_frontend/assets/images/$imageIdentifier',
    '../flutter_frontend/assets/images/catalog-assets/images/$imageIdentifier',
    'catalog-assets/images/$imageIdentifier'
  ]) {
    final file = File(localPath);
    if (await file.exists()) {
      return await file.readAsBytes();
    }
  }

  final app = FirebaseApp.instance;
  final storage = app.storage();
  final bucket = storage.bucket();
  return await bucket.object('catalog-assets/images/$imageIdentifier').download();
}

Future<String> uploadToFirebaseStorage({
  required String bucketName,
  required Uint8List bytes,
  required String objectName,
  required String mimeType,
}) async {
  final app = FirebaseApp.instance;
  final storage = app.storage();
  final bucket = storage.bucket(bucketName);
  await bucket.object(objectName).upload(bytes, metadata: ObjectMetadata(contentType: mimeType));
  return 'gs://$bucketName/$objectName';
}

const toolInstructions = '''
# Virtual Try-On Image Generation — Identity-Preserving

You are generating an image of a SPECIFIC PERSON wearing new clothing. The reference person's identity is sacred. Do not invent a new person.

## What you receive

- **IMAGE 1 (Reference Person):** the user's actual photo. Treat this as a fixed identity anchor — the single source of truth for who the person is.
- **IMAGES 2 and later (Products):** clothing items or accessories to put ONTO the reference person.

## Hard rules — DO NOT BREAK THESE

You MUST preserve all of the following from IMAGE 1, exactly:

1. **Face geometry** — eye shape, eye color, eye spacing, eyebrow shape and thickness, nose shape, nose width, mouth shape, lip fullness, chin shape, jawline, cheekbone structure, forehead shape.
2. **Skin** — skin tone, undertone, freckles, moles, scars, birthmarks, age lines, any other identifying skin feature. Do NOT smooth, lighten, or "improve" the skin.
3. **Hair** — exact color (including roots, highlights, gray strands), length, parting, texture, curl pattern, hairline.
4. **Body shape** — height proportion, shoulder width, torso shape, arm thickness, leg shape, posture. Do NOT slim, muscle-up, or otherwise alter the body.
5. **Ethnicity, age, and gender presentation** — exactly as in IMAGE 1. Do NOT shift any of these.

If any of these would change in your output, your output is wrong. Regenerate mentally and start over.

## What you CAN change

- Clothing — replace the person's existing garments with the products from IMAGES 2+.
- Background — optionally adjust to a setting that fits the new outfit.
- Pose — minor adjustments only, to make the outfit look natural; do not change the framing dramatically.

## How to apply the products

- **Full-body garments (dresses, jumpsuits):** replace both upper and lower body clothing.
- **Tops (shirts, jackets):** replace only the upper body.
- **Bottoms (pants, skirts, shorts):** replace only the lower body.
- **Accessories (hats, sunglasses, bags, shoes):** add at the appropriate location without disturbing the body or face.
- Apply ALL provided products in one cohesive outfit. Do not omit any.

## Output quality

- Photorealistic. Should look like an actual photograph of THE SAME PERSON as IMAGE 1, just in different clothes.
- Resolution at least as high as IMAGE 1.
- Natural lighting consistent with the chosen background.

## Self-check before returning

Before emitting your image, ask yourself: **"If I showed this image and IMAGE 1 to the person's mother, would she immediately recognize both as her child?"** If not, your face fidelity is wrong — fix it.
''';

String detectMimeType(Uint8List bytes, {String fallback = 'image/jpeg'}) {
  if (bytes.length >= 4) {
    if (bytes[0] == 0xFF && bytes[1] == 0xD8) {
      return 'image/jpeg';
    }
    if (bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'image/webp';
    }
  }
  return fallback;
}

final fittingTool = ai.defineTool(
  name: 'fitting_tool',
  description: 'Generates an image combining a user photo and product images.',
  inputSchema: SchemanticType.from(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'user_image': {
          'type': 'string',
          'description': 'GCS URI or base64 of user photo'
        },
        'accessories': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': 'GCS URIs or base64 of product photos'
        }
      },
      'required': ['user_image', 'accessories']
    },
    parse: (json) => json,
  ),
  outputSchema: SchemanticType.from(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'gcs_url': {'type': 'string'}
      },
      'required': ['gcs_url']
    },
    parse: (json) => json,
  ),
  fn: (input, context) async {
    final userImageUri = input['user_image'] as String;
    final accessories = List<String>.from(input['accessories']);

    final parts = <Part>[
      TextPart(text: toolInstructions),
    ];

    for (var i = 0; i < accessories.length; i++) {
      final bytes = await fetchImageBytes(accessories[i]);
      final mime = detectMimeType(bytes, fallback: 'image/png');
      parts.add(
        TextPart(text: 'Product image ${i + 1} to apply to the person below:'),
      );
      parts.add(
        MediaPart(
          media: Media(
            url: 'data:$mime;base64,${base64Encode(bytes)}',
            contentType: mime,
          ),
        ),
      );
    }

    final userBytes = await fetchImageBytes(userImageUri);
    final userMime = detectMimeType(userBytes, fallback: 'image/jpeg');
    parts.add(
      TextPart(
        text: '=== IDENTITY ANCHOR ===\n'
            'The image below is the user\'s actual photograph. The person you generate MUST be this exact person.\n'
            'Do NOT alter their face geometry, eyes, nose, mouth, skin tone, hair color, hair length, or body shape.\n'
            'Use this image as the single ground truth for who the person is. Apply the products above to THIS person, unchanged.\n'
            'User photo (identity anchor):',
      ),
    );
    parts.add(
      MediaPart(
        media: Media(
          url: 'data:$userMime;base64,${base64Encode(userBytes)}',
          contentType: userMime,
        ),
      ),
    );

    final response = await ai.generate(
      model: googleAI.gemini('gemini-2.5-flash-image'),
      messages: [
        Message(role: Role.user, content: parts),
      ],
      config: GeminiOptions(
        temperature: 0.05,
      ),
    );

    final media = response.media;
    if (media == null) {
      throw Exception('No image was generated by the model.');
    }

    final urlStr = media.url;
    String mimeType = media.contentType ?? 'image/png';
    Uint8List outBytes;
    if (urlStr.contains(';base64,')) {
      final splitParts = urlStr.split(';base64,');
      if (splitParts.first.startsWith('data:')) {
        mimeType = splitParts.first.substring(5);
      }
      outBytes = base64Decode(splitParts.last);
    } else {
      outBytes = base64Decode(urlStr);
    }

    final storageBucket =
        Platform.environment['GCS_BUCKET'] ??
        'flutter-firebase-fashion.firebasestorage.app';
    final uuid = DateTime.now().millisecondsSinceEpoch.toString();
    final objectName = 'generated-fittings/fitting_$uuid.png';

    final gcsUrl = await uploadToFirebaseStorage(
      bucketName: storageBucket,
      bytes: outBytes,
      objectName: objectName,
      mimeType: mimeType,
    );

    return {'gcs_url': gcsUrl};
  },
);
