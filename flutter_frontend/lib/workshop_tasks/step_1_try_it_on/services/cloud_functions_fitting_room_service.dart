import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:fashion_app/app_config.dart';
import 'package:fashion_app/workshop_tasks/step_1_try_it_on/services/try_it_on_service.dart';

class CloudFunctionsFittingRoomService implements TryItOnService {
  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;

  CloudFunctionsFittingRoomService({
    FirebaseFunctions? functions,
    FirebaseAuth? auth,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _auth = auth ?? FirebaseAuth.instance;

  Future<void> _ensureAuthenticated() async {
    try {
      if (_auth.currentUser == null) {
        await _auth.signInAnonymously();
      }
    } catch (e) {
      debugPrint('Warning: Anonymous sign-in failed: $e');
    }
  }

  @override
  Future<(Uint8List?, String?)> generateTryOnImage(
    Uint8List userImageBytes,
    Uint8List productImageBytes,
  ) async {
    try {
      await _ensureAuthenticated();

      final callable = _functions.httpsCallableFromUrl(
        AppConfig.fittingRoomEndpoint,
        options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
      );

      final response = await callable.call<Map<dynamic, dynamic>>({
        'userImageBase64': base64Encode(userImageBytes),
        'productImageBase64': base64Encode(productImageBytes),
      });

      final data = Map<String, dynamic>.from(response.data);
      final imageBytesBase64 = data['imageBytesBase64'] as String?;
      final gcsUrl = data['gcsUrl'] as String?;

      if (imageBytesBase64 == null || imageBytesBase64.isEmpty) {
        throw Exception('We could not generate an image from this photo.');
      }

      final imageBytes = base64Decode(imageBytesBase64);
      return (imageBytes, gcsUrl);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('FirebaseFunctionsException (${e.code}): ${e.message}');
      throw Exception(
        e.message ?? 'Failed to generate image. Please try another photo.',
      );
    } on SocketException {
      throw Exception('Check your internet connection and try again.');
    } on TimeoutException {
      throw Exception('The server took too long to respond. Please try again.');
    } catch (e) {
      debugPrint('Error generating try-on image via Cloud Functions: $e');
      throw Exception('Failed to generate image. Please try another photo.');
    }
  }
}
