import 'dart:io';
import 'package:yaml/yaml.dart';
import 'package:schemantic/schemantic.dart';
import '../ai.dart';

final listProductsTool = ai.defineTool(
  name: 'listProducts',
  description: 'List all products in the fashion catalog.',
  inputSchema: SchemanticType.voidSchema(),
  outputSchema: SchemanticType.from(
    jsonSchema: {
      'type': 'object',
      'properties': {
        'products': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'id': {'type': 'string'},
              'title': {'type': 'string'},
              'subtitle': {'type': 'string'},
              'price': {'type': 'number'},
              'images': {
                'type': 'array',
                'items': {'type': 'string'}
              }
            },
            'required': ['id', 'title', 'price', 'images']
          }
        }
      },
      'required': ['products']
    },
    parse: (json) => json,
  ),
  fn: (input, context) async {
    final products = await loadCatalogYaml();
    return {'products': products};
  },
);

Future<List<Map<String, dynamic>>> loadCatalogYaml() async {
  for (final path in [
    'catalog/catalog.yaml',
    'functions/catalog/catalog.yaml',
    '../adk_backend/catalog/catalog.yaml',
  ]) {
    final file = File(path);
    if (await file.exists()) {
      final content = await file.readAsString();
      final yamlList = loadYaml(content) as YamlList;
      final List<Map<String, dynamic>> products = [];
      for (final item in yamlList) {
        if (item is YamlMap) {
          final images = (item['images'] as YamlList?)?.map((e) => e.toString()).toList() ?? [];
          products.add({
            'id': item['id']?.toString() ?? '',
            'title': item['title']?.toString() ?? '',
            'subtitle': item['subtitle']?.toString() ?? '',
            'price': (item['price'] as num?)?.toDouble() ?? 0.0,
            'images': images,
          });
        }
      }
      return products;
    }
  }
  throw Exception('catalog.yaml not found');
}
