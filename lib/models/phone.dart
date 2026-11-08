import 'dart:convert';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/services.dart' show rootBundle;

/// Name used when searching the web for a phone (e.g. Samsung models are
/// stored without the "Galaxy" prefix, but photo searches need it).
String phoneQueryName(String brand, String model) {
  final b = brand.trim();
  final m = model.trim();
  if (b.isEmpty || b == 'Other') return m;
  if (b == 'Samsung' && !m.toLowerCase().startsWith('galaxy')) return 'Samsung Galaxy $m';
  if (m.toLowerCase().startsWith(b.toLowerCase())) return m;
  return '$b $m';
}

class Phone {
  final String id, brand, model;
  final String? image;
  final String searchText;
  final Set<String> searchTokens;
  final List<String> tokenList;
  final String compact;

  Phone._(this.id, this.brand, this.model, this.image, Set<String> tokens)
      : searchText = '$brand $model'.toLowerCase(),
        searchTokens = tokens,
        tokenList = tokens.toList(growable: false),
        compact = tokens.join();

  factory Phone(String id, String brand, String model, String? image) =>
      Phone._(id, brand, model, image, _tokenize('$brand $model'));

  static final RegExp _nonAlnum = RegExp(r'[^a-z0-9 ]');
  static final RegExp _spaces = RegExp(r'\s+');
  static Set<String> _tokenize(String text) => text
      .toLowerCase()
      .replaceAll(_nonAlnum, ' ')
      .split(_spaces)
      .where((token) => token.isNotEmpty)
      .toSet();

  String get queryName => phoneQueryName(brand, model);

  /// True when every search term is the start of one of the phone's words,
  /// or when the query typed without spaces appears inside the name
  /// (so "a15", "galaxy a1" and "iphone15" all work).
  bool matches(List<String> terms, String compactQuery) {
    if (terms.isEmpty) return false;
    final everyTerm = terms.every((t) => tokenList.any((k) => k.startsWith(t)));
    return everyTerm || compact.contains(compactQuery);
  }

  bool matchesExactly(List<String> terms) => terms.every(searchTokens.contains);

  factory Phone.fromJson(Map<String, dynamic> j) {
    String read(dynamic value) {
      if (value is Map) return (value['name'] ?? value['slug'] ?? value['title'] ?? '').toString().trim();
      return value?.toString().trim() ?? '';
    }
    String pick(List<String> keys) {
      for (final key in keys) {
        final value = read(j[key]);
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final id = pick(['slug','id','key','model_id']);
    final rawBrand = pick(['brand','manufacturer','maker','vendor']);
    final rawModel = pick(['name','marketing_name','model_name','model','device','title']);
    final source = '$rawBrand $rawModel $id'.replaceAll('_',' ').replaceAll('-',' ').toLowerCase();

    const brandPatterns = <String, String>{
      'samsung':'Samsung','galaxy':'Samsung','sm ':'Samsung','apple':'Apple','iphone':'Apple',
      'oppo':'OPPO','cph':'OPPO','vivo':'vivo','iqoo':'iQOO','infinix':'Infinix',
      'tecno':'TECNO','realme':'Realme','rmx':'Realme','xiaomi':'Xiaomi','redmi':'Xiaomi',
      'poco':'POCO','oneplus':'OnePlus','huawei':'Huawei','honor':'Honor','google':'Google',
      'pixel':'Google','nothing':'Nothing','motorola':'Motorola','moto':'Motorola','nokia':'Nokia',
      'sony':'Sony','asus':'ASUS','lenovo':'Lenovo','zte':'ZTE','nubia':'Nubia',
      'itel':'itel','tcl':'TCL','blackview':'Blackview','doogee':'DOOGEE','ulefone':'Ulefone'
    };
    var brand = '';
    final b = rawBrand.toLowerCase().trim();
    if (b.isNotEmpty && b != 'other' && !b.startsWith('other ')) {
      for (final entry in brandPatterns.entries) {
        if (b == entry.key || b.startsWith(entry.key) || b.contains(entry.key)) {
          brand = entry.value;
          break;
        }
      }
      if (brand.isEmpty) brand = rawBrand.trim();
    }
    if (brand.isEmpty) {
      for (final entry in brandPatterns.entries) {
        if (RegExp(r'(^|[^a-z0-9])' + RegExp.escape(entry.key) + r'([^a-z0-9]|$)', caseSensitive:false).hasMatch(source)) {
          brand = entry.value;
          break;
        }
      }
    }
    if (brand.isEmpty) brand = 'Other';

    var model = rawModel;
    model = model.replaceFirst(RegExp(r'^other\s+',caseSensitive:false),'');
    model = model.replaceFirst(RegExp(r'^(?:' + RegExp.escape(rawBrand) + r')\s+',caseSensitive:false),'');
    model = model.replaceAll(RegExp(r'\b(?:SM|CPH|RMX)\s*[-_]?[A-Z0-9]{3,}\b',caseSensitive:false),' ');
    model = model.replaceAll(RegExp(r'\b(?:19|20)\d{2}\b.*$'),' ');
    model = model.replaceAll(RegExp(r'\b(?:premium edition|standard edition|dual sim|td-lte|fdd-lte|lte|5g nr|128gb|256gb|512gb|64gb|32gb|cn|hk|tw|us|in|id|my|pk|v1)\b.*$',caseSensitive:false),' ');
    model = model.replaceAll(RegExp(r'\([^)]*\)'),' ');
    model = model.replaceAll(RegExp(r'\s+'),' ').trim();

    RegExpMatch? match;
    if (brand == 'Samsung') {
      match = RegExp(r'(Galaxy\s+(?:[ASMFZ]\s*)?\d{1,3}[A-Za-z]?(?:\s+(?:5G|4G|FE|Ultra|Plus|Pro|Edge|Note|Fold|Flip))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Apple') {
      match = RegExp(r'(iPhone\s+(?:SE(?:\s*\d{0,2})?|\d{1,2}[A-Za-z]?(?:\s+(?:Pro|Max|Plus|mini))?(?:\s+(?:Pro|Max))?))',caseSensitive:false).firstMatch(model);
    } else if (brand == 'OPPO') {
      match = RegExp(r'\b(A\d{1,3}[A-Za-z]?(?:\s+(?:Pro|Plus|s))?|Reno\s*\d{0,2}[A-Za-z]?(?:\s+(?:Pro|Plus|Z))?|Find\s+[A-Za-z0-9 ]+?)\b',caseSensitive:false).firstMatch(model);
    } else if (brand == 'vivo' || brand == 'iQOO') {
      match = RegExp(r'\b([YVXZT]\s*\d{1,3}[A-Za-z]?(?:\s+(?:Pro|Plus|Lite|e|T))?)\b',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Xiaomi' || brand == 'POCO') {
      match = RegExp(r'\b((?:Redmi\s+)?(?:Note\s+)?(?:\d{1,2}[A-Za-z]?(?:\s+(?:Pro|Plus|Ultra|Max|5G|4G))*)|POCO\s+[A-Za-z0-9 ]+)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Infinix') {
      match = RegExp(r'\b((?:Hot|Note|Zero|Smart|GT)\s+[A-Za-z0-9]+(?:\s+(?:Pro|Plus|Ultra|5G|4G|X))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'TECNO') {
      match = RegExp(r'\b((?:Spark|Camon|Pova|Phantom|Pop)\s+[A-Za-z0-9]+(?:\s+(?:Pro|Plus|Premier|Ultra|5G|4G))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Realme') {
      match = RegExp(r'\b((?:C|GT|Narzo|Number)\s*\d{1,3}[A-Za-z]?(?:\s+(?:Pro|Plus|Ultra|5G|4G|Master))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'OnePlus') {
      match = RegExp(r'\b((?:Nord\s+)?(?:CE\s*)?\d{1,2}[A-Za-z]?(?:\s+(?:R|Pro|Plus|Lite))?)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Google') {
      match = RegExp(r'\b(Pixel\s+\d+[A-Za-z]?(?:\s+(?:Pro|XL|a|Fold))?)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Honor') {
      match = RegExp(r'\b((?:Magic|X|Play|90|200)\s*[A-Za-z0-9]+(?:\s+(?:Pro|Plus|Lite|Ultra))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Huawei') {
      match = RegExp(r'\b((?:Pura|Mate|Nova|P)\s*\d+[A-Za-z]?(?:\s+(?:Pro|Plus|Ultra|Lite))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Motorola') {
      match = RegExp(r'\b((?:Moto\s+)?(?:G|E|Edge|Razr)\s*\d{1,3}[A-Za-z]?(?:\s+(?:Power|Play|Plus|Ultra|Pro))*)',caseSensitive:false).firstMatch(model);
    } else if (brand == 'Nothing') {
      match = RegExp(r'\b(Phone\s*\(?\d+[A-Za-z]?\)?)',caseSensitive:false).firstMatch(model);
    }
    if (match != null) model = match.group(1)!.trim();
    if (brand == 'Samsung') model = model.replaceFirst(RegExp(r'^Galaxy\s+',caseSensitive:false),'').trim();
    model = model.replaceAll(RegExp(r'\s+'),' ').trim();
    if (model.isEmpty) model = 'Unknown model';

    final image = pick(['image_url','imageUrl','image','photo','thumbnail','picture']);
    return Phone(id.isEmpty ? '${brand}_${model}' : id, brand, model, image.isEmpty ? null : image);
  }
}

List<Phone> _decodePhoneCatalogue(String source) {
  final decoded = jsonDecode(source);
  dynamic rows = decoded;
  if (decoded is Map) rows = decoded['results'] ?? decoded['data'] ?? decoded['phones'] ?? decoded['items'];
  if (rows is! List) throw const FormatException('Bundled catalogue has an unknown format');
  return rows
      .whereType<Map>()
      .map((e) => Phone.fromJson(Map<String, dynamic>.from(e)))
      .where((phone) => phone.model != 'Unknown model')
      .toList(growable: false);
}

/// Loads and normalises the bundled catalogue off the UI thread.
Future<List<Phone>> loadPhoneCatalogue() async {
  final source = await rootBundle.loadString('assets/phones.json');
  return compute(_decodePhoneCatalogue, source);
}
