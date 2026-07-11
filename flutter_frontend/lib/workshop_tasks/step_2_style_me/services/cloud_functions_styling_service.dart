import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:fashion_app/core_app/models/product.dart';
import 'package:fashion_app/workshop_tasks/step_2_style_me/models/outfit.dart';
import 'package:fashion_app/workshop_tasks/step_2_style_me/models/style_request.dart';
import 'package:fashion_app/workshop_tasks/step_2_style_me/services/styling_service.dart';

class CloudFunctionsStylingService implements StylingService {
  static const _outfitHeroImages = [
    'assets/images/outfit_casual.png',
    'assets/images/outfit_floral.png',
    'assets/images/outfit_streetwear.png',
    'assets/images/outfit_evening.png',
  ];

  static const _productImageMap = {
    'id_bomber_jacket': 'assets/images/bomber_jacket.png',
    'id_flutter_hat': 'assets/images/flutter_hat.png',
    'id_flutter_letterman': 'assets/images/flutter_letterman.png',
    'id_hightop': 'assets/images/hightop.png',
    'id_plaid_shirt': 'assets/images/plaid_shirt.png',
    'id_product_1': 'assets/images/product_1.png',
    'id_product_2': 'assets/images/product_2.png',
    'id_product_3': 'assets/images/product_3.png',
    'id_product_4': 'assets/images/product_4.png',
    'id_quarter-zip': 'assets/images/quarter-zip.png',
    'id_style_1': 'assets/images/prod1_var1.png',
    'id_style_2': 'assets/images/prod2_var1.png',
    'id_style_3': 'assets/images/prod3_var1.png',
    'id_style_4': 'assets/images/prod4_var1.png',
    'id_style_5': 'assets/images/prod5_var1.png',
    'id_style_6': 'assets/images/prod6_var1.png',
    'id_style_7': 'assets/images/prod7_var1.png',
    'id_style_8': 'assets/images/prod8_var1.png',
    'id_style_9': 'assets/images/prod9_var1.png',
    'id_style_10': 'assets/images/prod10_var1.png',
    'id_style_11': 'assets/images/prod11_var1.png',
    'id_style_12': 'assets/images/prod12_var1.png',
  };

  final FirebaseFunctions _functions;
  final FirebaseAuth _auth;
  String? _sessionId;

  CloudFunctionsStylingService({
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
  Future<List<Outfit>> getStyleSuggestions(StyleRequest request) async {
    try {
      await _ensureAuthenticated();
      _sessionId ??= 'session_${DateTime.now().millisecondsSinceEpoch}';

      final callable = _functions.httpsCallable(
        'stylist',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 180)),
      );

      final response = await callable.call<Map<dynamic, dynamic>>({
        'prompt': _buildPrompt(request),
        'sessionId': _sessionId,
        if (request.userImageData != null)
          'userImageBase64': base64Encode(request.userImageData!),
        if (request.gcsUserImageUrl != null)
          'userImageGcsUrl': request.gcsUserImageUrl,
      });

      return _parseResponse(response.data);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('FirebaseFunctionsException (${e.code}): ${e.message}');
      throw Exception(
        e.message ?? 'Failed to get style suggestions. Please try again.',
      );
    } on SocketException {
      throw Exception('Check your internet connection and try again.');
    } on TimeoutException {
      throw Exception('The server took too long to respond. Please try again.');
    } catch (e) {
      debugPrint('Error getting style suggestions via Cloud Functions: $e');
      throw Exception('Failed to get style suggestions. Please try again.');
    }
  }

  @override
  Future<List<Outfit>> refineWithFeedback(String feedback) async {
    try {
      await _ensureAuthenticated();
      _sessionId ??= 'session_${DateTime.now().millisecondsSinceEpoch}';

      final callable = _functions.httpsCallable(
        'stylist',
        options: HttpsCallableOptions(timeout: const Duration(seconds: 180)),
      );

      final response = await callable.call<Map<dynamic, dynamic>>({
        'prompt': feedback,
        'sessionId': _sessionId,
      });

      return _parseResponse(response.data);
    } on FirebaseFunctionsException catch (e) {
      debugPrint('FirebaseFunctionsException (${e.code}): ${e.message}');
      throw Exception(
        e.message ?? 'Failed to refine suggestions. Please try again.',
      );
    } on SocketException {
      throw Exception('Check your internet connection and try again.');
    } on TimeoutException {
      throw Exception('The server took too long to respond. Please try again.');
    } catch (e) {
      debugPrint('Error refining suggestions via Cloud Functions: $e');
      throw Exception('Failed to refine suggestions. Please try again.');
    }
  }

  String _buildPrompt(StyleRequest request) {
    final parts = <String>[];
    if (request.location.isNotEmpty) parts.add('Location: ${request.location}');
    if (request.occasion.isNotEmpty) parts.add('Occasion: ${request.occasion}');
    if (request.notes.isNotEmpty) {
      parts.add('Additional notes: ${request.notes}');
    }
    if (request.selectedProductId != null) {
      parts.add(
        'Base product already tried on (MUST include in the outfit): ID=${request.selectedProductId}, Title=${request.selectedProductTitle}',
      );
    }
    return parts.join('\n');
  }

  List<Outfit> _parseResponse(Map<dynamic, dynamic> dataMap) {
    final data = Map<String, dynamic>.from(dataMap);
    final outfitsData = data['outfits'] as List<dynamic>? ?? [];

    final List<Outfit> parsedOutfits = [];
    for (int index = 0; index < outfitsData.length; index++) {
      final outfitData = Map<String, dynamic>.from(outfitsData[index] as Map);
      final commentary = outfitData['commentary'] as String? ?? '';
      final productsData = outfitData['products'] as List<dynamic>? ?? [];

      final products = productsData.map((p) {
        final productMap = Map<String, dynamic>.from(p as Map);
        final id = productMap['id'] as String? ?? '';
        final imagePath =
            _productImageMap[id] ??
            _outfitHeroImages[index % _outfitHeroImages.length];
        final priceRaw = productMap['price'];
        final double price = priceRaw != null
            ? (priceRaw as num).toDouble()
            : 0.0;

        return Product(
          id: id,
          title: productMap['title'] as String? ?? '',
          subtitle: productMap['subtitle'] as String? ?? '',
          price: price,
          images: [imagePath],
        );
      }).toList();

      final heroImage = _outfitHeroImages[index % _outfitHeroImages.length];

      Uint8List? imageData;
      final imageBase64 = outfitData['imageBytesBase64'] as String?;
      if (imageBase64 != null && imageBase64.isNotEmpty) {
        try {
          imageData = base64Decode(imageBase64);
        } catch (e) {
          debugPrint('Failed to decode outfit imageBase64: $e');
        }
      }

      parsedOutfits.add(
        Outfit(
          imagePath: heroImage,
          imageData: imageData,
          products: products,
          commentary: commentary,
        ),
      );
    }

    return parsedOutfits;
  }
}
