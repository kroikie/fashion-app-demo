# Migration Plan: ADK Go Backend to Firebase Functions (Genkit Dart)

This document outlines the architectural comparison, component mapping, and step-by-step migration path for moving the **Fashion App Demo** backend from the **Google Agent Development Kit (ADK) in Go** to a **Firebase Functions (Genkit Dart)** backend using the target Firebase project **`flutter-firebase-fashion`**.

---

## 1. Executive Summary & Architectural Overview

### Current Architecture (ADK Go Backend)
- **Framework**: `google.golang.org/adk` running as a custom HTTP server (Gorilla Mux).
- **Agents**:
  - `root_agent`: Fast router (Gemini 3 Flash) delegating to sub-agents.
  - `catalog_agent`: Catalog search & product retrieval.
  - `fitting_room`: Multimodal try-on agent (Gemini 2.5 Flash Image) preserving user identity.
  - `stylist`: Fashion stylist agent returning structured JSON (outfits + product recommendations).
- **Session & Artifacts**: ADK In-Memory Session Service + GCS Artifact Service (`gcsartifact`).
- **Client Protocol**: ADK REST API (`POST /apps/.../sessions`, `POST /run`, `GET /.../artifacts/...`).

### Target Architecture (Genkit Dart on Firebase Functions)
- **Firebase Project**: `flutter-firebase-fashion`
- **Framework**: Genkit Dart SDK hosted on Cloud Functions for Firebase (`us-central1`).
- **Abstractions**: Genkit **Flows** (`defineFlow`), **Tools** (`defineTool`), and **Prompts** (`defineDotprompt` or programmatic prompts).
- **Security & Auth**: **Firebase Callable Functions** (`onCallGenkit` / `onCall`) with mandatory Firebase Auth token validation prior to flow execution.
- **Function Naming Convention**: Firebase Functions deploys camelCase definitions using dashed/kebab-case (e.g., `fittingRoom` -> `fitting-room`, `addUser` -> `add-user`). The Flutter client invokes functions using their dashed names.
- **Flutter Configuration**: **FlutterFire CLI** (`flutterfire_cli`) to automatically generate `lib/firebase_options.dart` and target platform native configs.
- **Session & Artifacts**: Firebase Firestore for chat history & state (scoped by `auth.uid`), Cloud Storage for Firebase (`flutter-firebase-fashion.firebasestorage.app`) for generated image artifacts.
- **Client Protocol**: Firebase Callable Functions (`FirebaseFunctions.instance.httpsCallable('fitting-room')`).

---

## 2. Component Mapping Table

| ADK Go Concept | Genkit Dart Equivalent | Target Implementation (`flutter-firebase-fashion`) |
| :--- | :--- | :--- |
| **`llmagent.New(...)`** | **`defineFlow(...)` / Genkit Prompts** | Genkit replaces multi-agent state machines with explicit, type-safe Dart flows. |
| **`functiontool.New(...)`** | **`defineTool(...)`** | Functions with typed input/output schemas (e.g. `listProducts`, `fitting_tool`). |
| **`agenttool.New(...)`** | **Sub-flow Invocation** | In Genkit, flows can directly call other flows or be provided to LLMs as tools. |
| **ADK Session Service** | **Firestore / Firebase Auth** | Store conversation history, pinned base photos, and previous outfit recommendations in Firestore under `users/{uid}/sessions`. |
| **ADK Artifact Service** | **Cloud Storage for Firebase** | Store generated image blobs in `gs://flutter-firebase-fashion.firebasestorage.app/generated-fittings/` and return signed or public URLs. |
| **ADK REST API (`/run`)** | **Firebase Callable Functions (`onCallGenkit`)** | Streamlined RPC directly from Flutter via Firebase SDK; automatically validates Auth ID tokens and attaches `context.auth.uid`. |

---

## 3. Step-by-Step Migration Guide

### Step 1: Firebase Project Setup & Local Initialization

1. **Set Active Firebase Project**:
   ```bash
   firebase use flutter-firebase-fashion
   ```
   If not yet logged in or linked, run:
   ```bash
   firebase project:list
   ```

2. **Enable Required Google Cloud & Firebase APIs** on `flutter-firebase-fashion`:
   - Vertex AI API (`aiplatform.googleapis.com`)
   - Cloud Functions API (`cloudfunctions.googleapis.com`)
   - Cloud Build API (`cloudbuild.googleapis.com`)
   - Firebase Storage API (`firebasestorage.googleapis.com`)
   - Firestore API (`firestore.googleapis.com`)
   - Firebase Authentication (`identitytoolkit.googleapis.com`)

3. **Initialize Firebase & Genkit Dart Workspace**:
   Create a `functions` directory next to `flutter_frontend`:

   ```bash
   mkdir -p functions
   cd functions
   dart create -t server-shelf .
   ```

   **`functions/pubspec.yaml` dependencies:**
   ```yaml
   name: fashion_backend_functions
   description: Genkit Dart & Firebase Functions backend for fashion-app-demo
   environment:
     sdk: '^3.5.0'

   dependencies:
     firebase_functions: ^0.1.0
     genkit: ^0.1.0
     google_generative_ai: ^0.4.0
     gcloud: ^0.8.0
     yaml: ^3.1.2
     crypto: ^3.0.3
   ```

---

### Step 2: Configure Flutter App with `flutterfire_cli`

Use the **FlutterFire CLI** (`flutterfire_cli`) to automatically register Android, iOS, and Web apps under project `flutter-firebase-fashion` and generate the platform options configuration.

1. **Activate FlutterFire CLI**:
   ```bash
   dart pub global activate flutterfire_cli
   ```

2. **Run `flutterfire configure` in `flutter_frontend/`**:
   ```bash
   cd flutter_frontend
   flutterfire configure \
     --project=flutter-firebase-fashion \
     --platforms=android,ios,web \
     --yes
   ```
   **What this step performs:**
   - Registers Android package `com.example.fashion_app` (downloads `android/app/google-services.json`).
   - Registers iOS bundle `com.example.fashionApp` (downloads `ios/Runner/GoogleService-Info.plist`).
   - Generates/updates `lib/firebase_options.dart` with `DefaultFirebaseOptions.currentPlatform` pointing to `flutter-firebase-fashion`.
   - Updates `flutter_frontend/firebase.json` with platform-specific project mappings.

3. **Initialize Firebase in `lib/main.dart`**:
   ```dart
   import 'package:firebase_core/firebase_core.dart';
   import 'firebase_options.dart';

   void main() async {
     WidgetsFlutterBinding.ensureInitialized();
     await Firebase.initializeApp(
       options: DefaultFirebaseOptions.currentPlatform,
     );
     runApp(const MyApp());
   }
   ```

---

### Step 3: Port Tools to Genkit Dart

#### A. Catalog Tool (`listProducts`)
Read product catalog (`catalog.yaml`) and return structured product list.

**Genkit Dart (`functions/lib/tools/catalog_tool.dart`):**
```dart
import 'package:genkit/genkit.dart';

final listProductsTool = defineTool(
  name: 'listProducts',
  description: 'List all products in the fashion catalog.',
  inputSchema: Schema.object({}),
  outputSchema: Schema.object({
    'products': Schema.array(Schema.object({
      'id': Schema.string(),
      'title': Schema.string(),
      'subtitle': Schema.string(),
      'price': Schema.number(),
      'images': Schema.array(Schema.string()),
    })),
  }),
  action: (input) async {
    final products = await loadCatalogYaml();
    return {'products': products};
  },
);
```

#### B. Fitting Tool (`fitting_tool`)
Port the low-temperature image generation, identity-anchoring, and Cloud Storage upload logic for `flutter-firebase-fashion`.

**Genkit Dart (`functions/lib/tools/fitting_tool.dart`):**
```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:genkit/genkit.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:crypto/crypto.dart';

int stableSeed(String s) {
  final bytes = utf8.encode(s);
  final digest = sha256.convert(bytes);
  return ByteData.sublistView(Uint8List.fromList(digest.bytes)).getInt32(0) & 0x7FFFFFFF;
}

final fittingTool = defineTool(
  name: 'fitting_tool',
  description: 'Generates an image combining a user photo and product images.',
  inputSchema: Schema.object({
    'user_image': Schema.string(description: 'GCS URI or base64 of user photo'),
    'accessories': Schema.array(Schema.string(), description: 'GCS URIs or base64 of product photos'),
  }),
  outputSchema: Schema.object({
    'gcs_url': Schema.string(),
  }),
  action: (input) async {
    final userImageUri = input['user_image'] as String;
    final accessories = List<String>.from(input['accessories']);

    // Build multimodal prompt with identity anchor at the end
    final parts = <DataPart>[];
    for (var i = 0; i < accessories.length; i++) {
      final bytes = await fetchImageBytes(accessories[i]);
      parts.add(DataPart('image/png', bytes));
    }

    final userBytes = await fetchImageBytes(userImageUri);
    parts.add(DataPart('image/jpeg', userBytes));

    final model = GenerativeModel(
      model: 'gemini-2.5-flash-image',
      apiKey: Platform.environment['GEMINI_API_KEY']!,
    );

    final seed = stableSeed(userImageUri);
    final response = await model.generateContent(
      [
        Content.multi([
          TextPart(toolInstructionsText),
          ...parts,
          TextPart('=== IDENTITY ANCHOR ===\nUser photo (identity anchor):'),
        ])
      ],
      generationConfig: GenerationConfig(
        temperature: 0.05,
      ),
    );

    // Save output image to Cloud Storage for Firebase in flutter-firebase-fashion
    final storageBucket = 'flutter-firebase-fashion.firebasestorage.app';
    final gcsUrl = await uploadToFirebaseStorage(
      bucket: storageBucket,
      bytes: response.firstImageBytes,
    );
    return {'gcs_url': gcsUrl};
  },
);
```

---

### Step 4: Implement Genkit Flows (Auth-Aware)

Flows can now access user authentication metadata (`uid`, `token`) passed from the Callable wrapper:

#### A. Fitting Room Flow (`fittingRoomFlow`)
```dart
final fittingRoomFlow = defineFlow(
  name: 'fittingRoomFlow',
  inputSchema: Schema.object({
    'userImageBase64': Schema.string(),
    'productImageBase64': Schema.string(),
    'userId': Schema.string(), // Extracted from verified Firebase Auth token
  }),
  outputSchema: Schema.object({
    'gcsUrl': Schema.string(),
    'imageBytesBase64': Schema.string(),
  }),
  action: (input) async {
    final userId = input['userId'] as String;

    // 1. Upload incoming user photo & product photo to Cloud Storage under user path
    final userUri = await saveToStorage(input['userImageBase64'], 'users/$userId/uploads');
    final productUri = await saveToStorage(input['productImageBase64'], 'users/$userId/products');

    // 2. Call fitting tool
    final result = await fittingTool.run({
      'user_image': userUri,
      'accessories': [productUri],
    });

    final bytes = await downloadFromStorage(result['gcs_url']);
    return {
      'gcsUrl': result['gcs_url'],
      'imageBytesBase64': base64Encode(bytes),
    };
  },
);
```

#### B. Stylist Flow (`stylistFlow`)
```dart
final stylistFlow = defineFlow(
  name: 'stylistFlow',
  inputSchema: Schema.object({
    'prompt': Schema.string(),
    'userId': Schema.string(), // Extracted from verified Firebase Auth token
    'userImageGcsUrl': Schema.string(optional: true),
    'previousProductIds': Schema.array(Schema.string(), optional: true),
  }),
  outputSchema: outfitResponseSchema,
  action: (input) async {
    final prompt = input['prompt'] as String;
    final prevIds = (input['previousProductIds'] as List?)?.cast<String>() ?? [];

    final response = await generate(
      model: 'gemini-3.1-pro-preview',
      tools: [listProductsTool, fittingTool],
      prompt: '''
        You are an expert fashion stylist.
        ${prevIds.isNotEmpty ? "Do NOT reuse these product IDs: ${prevIds.join(', ')}" : ""}
        User query: $prompt
      ''',
      responseFormat: OutfitResponseJsonSchema,
    );

    return response.output;
  },
);
```

---

### Step 5: Expose Flows via Firebase Callable Functions with Auth Validation

By using **Firebase Callable Functions** (`onCallGenkit` or `onCall`), Firebase automatically handles the CORS preflight, decodes the HTTP Authorization header (`Bearer <idToken>`), verifies the JWT against Firebase Auth public keys, and rejects unauthenticated requests **before** the Genkit flow is triggered.

> **Important Naming Convention:** Firebase Functions converts camelCase definitions into dashed/kebab-case endpoint names (e.g., `fittingRoom` -> `fitting-room`, `stylistFlow` -> `stylist-flow`). Ensure the Flutter client references the dashed name when calling `httpsCallable(...)`.

**`functions/bin/server.dart`:**
```dart
import 'package:firebase_functions/firebase_functions.dart';
import 'package:genkit/genkit.dart';

void main() {
  // Option A: Using onCallGenkit with authPolicy
  // Deployed as endpoint name: "fitting-room"
  onCallGenkit(
    'fittingRoom',
    fittingRoomFlow,
    authPolicy: (auth, input) {
      if (auth == null) {
        throw HttpsError(
          code: HttpsErrorCode.unauthenticated,
          message: 'User must be authenticated with Firebase Auth to access try-on.',
        );
      }
    },
  );

  // Option B: Explicit Callable Function wrapper
  // Deployed as endpoint name: "stylist"
  onCall('stylist', (data, context) async {
    // 1. Validate Firebase Auth ID Token
    if (context.auth == null) {
      throw HttpsError(
        code: HttpsErrorCode.unauthenticated,
        message: 'Authentication required. Please sign in.',
      );
    }

    final uid = context.auth!.uid;

    // 2. Inject verified uid into Genkit Flow input
    final flowInput = Map<String, dynamic>.from(data)..['userId'] = uid;

    // 3. Execute Genkit Flow
    return await stylistFlow.run(flowInput);
  });
}
```

---

### Step 6: Connect Flutter Frontend to Firebase Callable Functions

When using `FirebaseFunctions.instance.httpsCallable(...)`, the Firebase SDK automatically attaches the current user's Firebase Auth ID token (`Authorization: Bearer <token>`) to every request.

> **Note on Function Names**: Because camelCase function definitions in Firebase Functions map to dashed names (e.g. `fittingRoom` -> `fitting-room`, `addUser` -> `add-user`), pass the dashed string name to `httpsCallable(...)`.

```dart
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:fashion_app/workshop_tasks/step_1_try_it_on/services/try_it_on_service.dart';

class GenkitFittingRoomService implements TryItOnService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseAuth _auth = FirebaseAuth.instance;

  @override
  Future<(Uint8List?, String?)> generateTryOnImage(
    Uint8List userImageBytes,
    Uint8List productImageBytes,
  ) async {
    // Ensure user is signed in (anonymous or email/password)
    if (_auth.currentUser == null) {
      await _auth.signInAnonymously();
    }

    // Call the Firebase Callable Function — note the dashed function name ('fitting-room')
    final callable = _functions.httpsCallable('fitting-room');
    try {
      final result = await callable.call({
        'userImageBase64': base64Encode(userImageBytes),
        'productImageBase64': base64Encode(productImageBytes),
      });

      final data = result.data as Map<String, dynamic>;
      final gcsUrl = data['gcsUrl'] as String?;
      final imageBytes = base64Decode(data['imageBytesBase64'] as String);

      return (imageBytes, gcsUrl);
    } on FirebaseFunctionsException catch (e) {
      if (e.code == 'unauthenticated') {
        throw Exception('Please sign in to use virtual try-on.');
      }
      rethrow;
    }
  }
}
```

---

## 4. Key Architectural Improvements Post-Migration

1. **Automated App Configuration with `flutterfire_cli`**: Seamless, reproducible setup for Android, iOS, and Web pointing to `flutter-firebase-fashion` without manual plist/json edits.
2. **Mandatory Token Validation**: Firebase Callable Functions automatically verify the user's Firebase Auth JWT before triggering Genkit flows or invoking Vertex AI models.
3. **Consistent Dashed Naming Convention**: Firebase Functions camelCase definitions (e.g., `fittingRoom`, `addUser`) map to dashed endpoint names (`fitting-room`, `add-user`) for clear, standardized REST/RPC naming.
4. **Simplified Client Code**: Eliminates manual ADK session creation (`_createSession`), polling, SSE stream parsing, and raw artifact endpoint downloads on the Flutter client.
5. **Native Dart Ecosystem**: Both backend (Firebase Functions) and frontend (Flutter) share Dart type definitions, data models, and serialization logic.
6. **Automatic Scaling & Zero Server Ops**: Eliminates Cloud Run / custom container management for Go ADK by utilizing Firebase Cloud Functions in `flutter-firebase-fashion`.
7. **Multi-Tenant User Isolation**: Session history and generated try-on artifacts are strictly isolated in Firestore and Cloud Storage using the authenticated `auth.uid`.
