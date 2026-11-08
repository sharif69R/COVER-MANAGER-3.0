import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/phone.dart';

/// Outcome of a photo lookup.
/// [source] is one of: official, web, wikipedia, none, offline.
class PhotoResult {
  final String? path;
  final String source;
  const PhotoResult(this.path, this.source);

  bool get found => path != null;
  bool get official => source == 'official';

  String get label {
    switch (source) {
      case 'official':
        return 'Official manufacturer image';
      case 'wikipedia':
        return 'Image from Wikipedia (may not be the back view)';
      case 'web':
        return 'Web image (not confirmed as official)';
      case 'offline':
        return 'No internet connection - photo could not be looked up';
      default:
        return 'No photo found for this model';
    }
  }
}

class _Hit {
  final String url;
  final String? thumb;
  final String source;
  final int score;
  const _Hit(this.url, this.thumb, this.source, this.score);
}

/// Finds one back-panel photo per phone model, saves it on the device and
/// remembers both hits and misses so the internet is only used once per model.
class PhotoService {
  PhotoService(this.db);
  final Database db;

  /// Optional key for Brave Image Search. Supplied at build time with
  /// --dart-define=BRAVE_API_KEY=... (the GitHub workflow does this from the
  /// BRAVE_API_KEY repository secret). Without it the app uses Wikipedia only.
  static const String braveKey = String.fromEnvironment('BRAVE_API_KEY');
  static bool get hasBrave => braveKey.isNotEmpty;

  static const String _ua = 'RepairXZoneCoverManager/1.6 (phone cover inventory app)';
  static const Duration _missTtl = Duration(days: 7);
  static const int _maxParallel = 4;

  static Future<void> createTable(Database db) => db.execute(
      'CREATE TABLE IF NOT EXISTS photo_cache(photo_key TEXT PRIMARY KEY, file TEXT, source TEXT NOT NULL DEFAULT \'\', checked_at INTEGER NOT NULL DEFAULT 0)');

  // ---------------------------------------------------------------- helpers

  static final RegExp _nonAlnumRun = RegExp(r'[^a-z0-9]+');

  static String keyFor(String brand, String model) =>
      ('${brand}_$model').toLowerCase().replaceAll(_nonAlnumRun, '_');

  static String _norm(String text) =>
      text.toLowerCase().replaceAll(_nonAlnumRun, ' ').trim();

  static const Set<String> _noiseTokens = {
    '5g', '4g', '3g', 'lte', 'dual', 'sim', 'global', 'version', 'edition', 'the'
  };

  /// Words that turn one phone into a different phone. A result that mentions
  /// "Pro" must not be used for a phone whose name has no "Pro".
  static const List<String> _variantWords = [
    'pro', 'plus', 'ultra', 'max', 'mini', 'lite', 'fe', 'se', 'neo', 'fold', 'flip', 'note'
  ];

  static const List<String> _rejectWords = [
    'case', 'cases', 'cover', 'covers', 'protector', 'tempered', 'charger', 'cable',
    'skin', 'wallpaper', 'wallpapers', 'holder', 'stand', 'strap', 'adapter'
  ];

  static List<String> _modelTokens(String model) => _norm(model)
      .split(' ')
      .where((t) => t.isNotEmpty && !_noiseTokens.contains(t))
      .toList(growable: false);

  static bool _hasAllTokens(String text, List<String> tokens) {
    if (tokens.isEmpty) return false;
    final padded = ' ${_norm(text)} ';
    return tokens.every((t) => padded.contains(' $t '));
  }

  static bool _hasWord(String paddedNorm, String word) => paddedNorm.contains(' $word ');

  static const Map<String, List<String>> _officialDomains = {
    'samsung': ['samsung.com', 'images.samsung.com', 'samsungmobilepress.com'],
    'apple': ['apple.com', 'mzstatic.com', 'cdn-apple.com'],
    'oneplus': ['oneplus.com', 'oneplus.net', 'opstatics.com'],
    'xiaomi': ['mi.com', 'xiaomi.com', 'mi-img.com', 'appmifile.com'],
    'redmi': ['mi.com', 'xiaomi.com', 'mi-img.com', 'appmifile.com'],
    'poco': ['mi.com', 'po.co', 'mi-img.com', 'appmifile.com'],
    'oppo': ['oppo.com', 'heytap.com'],
    'vivo': ['vivo.com', 'vivofs.com', 'vivo.com.cn', 'iqoo.com'],
    'iqoo': ['iqoo.com', 'vivo.com', 'vivofs.com'],
    'realme': ['realme.com', 'realme.net'],
    'tecno': ['tecno-mobile.com', 'tecnomobile.com'],
    'infinix': ['infinixmobility.com', 'infinixmobiles.com'],
    'itel': ['itel-life.com', 'itel-mobile.com'],
    'honor': ['honor.com', 'hihonor.com', 'honorfile.com'],
    'huawei': ['huawei.com', 'consumer.huawei.com'],
    'google': ['google.com', 'googleusercontent.com', 'withgoogle.com'],
    'motorola': ['motorola.com', 'lenovo.com'],
    'lenovo': ['lenovo.com', 'motorola.com'],
    'nothing': ['nothing.tech'],
    'asus': ['asus.com'],
    'sony': ['sony.com', 'sony.net', 'sonymobile.com'],
    'nokia': ['hmd.com', 'nokia.com'],
    'hmd': ['hmd.com', 'nokia.com'],
    'zte': ['zte.com.cn', 'ztedevices.com', 'zte.com'],
    'nubia': ['nubia.com', 'zte.com.cn'],
    'tcl': ['tcl.com'],
    'meizu': ['meizu.com'],
    'lava': ['lavamobiles.com', 'lavainternational.in'],
    'micromax': ['micromaxinfo.com'],
    'walton': ['waltonbd.com'],
    'symphony': ['symphony-mobile.com'],
    'blackview': ['blackview.hk'],
    'doogee': ['doogee.cc'],
    'ulefone': ['ulefone.com'],
  };

  static List<String> _domainsFor(String brand) {
    final b = brand.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    for (final entry in _officialDomains.entries) {
      if (b.contains(entry.key)) return entry.value;
    }
    return const [];
  }

  static bool _isOfficialHost(String host, List<String> domains) =>
      domains.any((d) => host == d || host.endsWith('.$d'));

  static bool _looksLikeImage(List<int> b) {
    if (b.length < 12) return false;
    final jpeg = b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF;
    final png = b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47;
    final webp = b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50;
    return jpeg || png || webp;
  }

  // ------------------------------------------------------- concurrency gate

  int _active = 0;
  final List<Completer<void>> _waiters = [];

  Future<void> _acquire() async {
    if (_active < _maxParallel) {
      _active++;
      return;
    }
    final waiter = Completer<void>();
    _waiters.add(waiter);
    await waiter.future; // the slot is handed over, _active stays the same
  }

  void _release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _active--;
    }
  }

  DateTime _nextBrave = DateTime.fromMillisecondsSinceEpoch(0);
  bool _braveRejected = false;

  /// Last reason Brave could not be used, shown in the photo viewer.
  String? braveProblem;

  /// Brave's entry plans allow about one request per second.
  Future<void> _braveThrottle() async {
    final now = DateTime.now();
    final start = _nextBrave.isAfter(now) ? _nextBrave : now;
    _nextBrave = start.add(const Duration(milliseconds: 1100));
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  // ------------------------------------------------------------ file + cache

  Directory? _photoDir;
  Future<Directory> _dir() async {
    final existing = _photoDir;
    if (existing != null) return existing;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, 'official_phone_photos'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _photoDir = dir;
    return dir;
  }

  Future<PhotoResult?> _readCache(String key) async {
    final rows = await db.query('photo_cache', where: 'photo_key = ?', whereArgs: [key], limit: 1);
    final dir = await _dir();
    if (rows.isNotEmpty) {
      final row = rows.first;
      final file = row['file'] as String?;
      if (file != null && file.isNotEmpty) {
        final f = File(p.join(dir.path, file));
        if (await f.exists() && await f.length() > 0) {
          return PhotoResult(f.path, (row['source'] as String?) ?? 'web');
        }
      } else {
        final checked = (row['checked_at'] as int?) ?? 0;
        final age = DateTime.now().millisecondsSinceEpoch - checked;
        if (age >= 0 && age < _missTtl.inMilliseconds) return const PhotoResult(null, 'none');
      }
    }
    // Photos saved by older versions of the app live in the same folder.
    final legacy = File(p.join(dir.path, '$key.img'));
    if (await legacy.exists() && await legacy.length() > 0) {
      await _writeCache(key, '$key.img', 'web');
      return PhotoResult(legacy.path, 'web');
    }
    return null;
  }

  Future<void> _writeCache(String key, String? file, String source) => db.insert(
        'photo_cache',
        {
          'photo_key': key,
          'file': file,
          'source': source,
          'checked_at': DateTime.now().millisecondsSinceEpoch,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

  /// Forget "no photo found" answers so they are searched again.
  Future<void> clearMisses() => db.delete('photo_cache', where: 'file IS NULL');

  // ------------------------------------------------------------------ lookup

  final Map<String, Future<PhotoResult>> _inflight = {};

  Future<PhotoResult> lookup(String brand, String model, {bool force = false}) {
    final key = keyFor(brand, model);
    if (force) _inflight.remove(key);
    final existing = _inflight[key];
    if (existing != null) return existing;
    final task = _resolve(key, brand, model, force);
    _inflight[key] = task;
    task.whenComplete(() {
      _inflight.remove(key);
    });
    return task;
  }

  Future<PhotoResult> _resolve(String key, String brand, String model, bool force) async {
    try {
      if (!force) {
        final cached = await _readCache(key);
        if (cached != null) return cached;
      }
      await _acquire();
      try {
        // Each source reports "ok" (even with zero results) or "failed".
        var sourcesOk = 0;
        var sourcesFailed = 0;
        final official = <_Hit>[];
        final preferred = <_Hit>[];
        final fallback = <_Hit>[];

        Future<void> runSource(Future<List<_Hit>> Function() job, {required bool trusted}) async {
          try {
            final found = await job();
            sourcesOk++;
            for (final h in found) {
              (h.source == 'official' ? official : (trusted ? preferred : fallback)).add(h);
            }
          } catch (_) {
            sourcesFailed++;
          }
        }

        // Image search and the free encyclopedias run at the same time.
        await Future.wait([
          if (hasBrave && !_braveRejected) runSource(() => _searchBrave(brand, model), trusted: true),
          runSource(() => _searchDuckDuckGo(brand, model), trusted: true),
          runSource(() => _searchFree(brand, model), trusted: false),
        ]);

        final seen = <String>{};
        final hits = <_Hit>[...official, ...preferred, ...fallback].where((h) => seen.add(h.url)).toList();
        // Offline only when EVERY source failed, not when one of them was blocked.
        final networkProblem = sourcesOk == 0 && sourcesFailed > 0;

        var tried = 0;
        var downloadFailed = false;
        for (final hit in hits) {
          if (tried++ >= 8) break;
          final file = await _saveImage(key, hit);
          if (file != null) {
            await _writeCache(key, file, hit.source);
            final dir = await _dir();
            return PhotoResult(p.join(dir.path, file), hit.source);
          }
          downloadFailed = true;
        }

        if (networkProblem && hits.isEmpty) return const PhotoResult(null, 'offline');
        // Photos were found but could not be downloaded: try again later, do not remember as a miss.
        if (downloadFailed) return const PhotoResult(null, 'offline');
        await _writeCache(key, null, '');
        return const PhotoResult(null, 'none');
      } finally {
        _release();
      }
    } catch (_) {
      return const PhotoResult(null, 'offline');
    }
  }

  // ------------------------------------------------------------------- Brave

  Future<List<_Hit>> _searchBrave(String brand, String model) async {
    final name = phoneQueryName(brand, model);
    final domains = _domainsFor(brand);
    final tokens = _modelTokens(model);
    final hits = <_Hit>[];

    hits.addAll(await _braveQuery('"$name" back panel official', brand, tokens, domains));
    final foundOfficial = hits.any((h) => h.source == 'official');
    if (!foundOfficial && domains.isNotEmpty && !_braveRejected) {
      hits.addAll(await _braveQuery('$name back view site:${domains.first}', brand, tokens, domains));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  Future<List<_Hit>> _braveQuery(String query, String brand, List<String> tokens, List<String> domains) async {
    await _braveThrottle();
    final uri = Uri.https('api.search.brave.com', '/res/v1/images/search', {
      'q': query,
      'count': '40',
      'safesearch': 'strict',
      'search_lang': 'en',
    });
    final response = await http.get(uri, headers: {
      'Accept': 'application/json',
      'X-Subscription-Token': braveKey,
    }).timeout(const Duration(seconds: 20));
    if (response.statusCode == 401 || response.statusCode == 403) {
      _braveRejected = true; // wrong or expired key: stop spending requests
      braveProblem = 'Brave key rejected (HTTP ${response.statusCode})';
      return const [];
    }
    if (response.statusCode == 429 || response.statusCode == 402) {
      braveProblem = 'Brave limit reached (HTTP ${response.statusCode})';
    }
    if (response.statusCode != 200) throw HttpException('Brave search ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];

    final hits = <_Hit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final hit = _scoreResult(raw, brand, tokens, domains);
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  /// Gives a search result a score, or null when it is clearly the wrong thing.
  _Hit? _scoreResult(Map raw, String brand, List<String> tokens, List<String> domains, {int minScore = 45}) {
    final props = raw['properties'];
    final thumbnail = raw['thumbnail'];
    final imageUrl = (props is Map ? props['url'] : null)?.toString() ?? '';
    final thumbUrl = (thumbnail is Map ? thumbnail['src'] : null)?.toString();
    final pageUrl = (raw['url'] ?? '').toString();
    final title = (raw['title'] ?? '').toString();

    final image = Uri.tryParse(imageUrl);
    if (image == null || image.scheme != 'https' || image.host.isEmpty) return null;
    final lowerPath = image.path.toLowerCase();
    if (lowerPath.endsWith('.svg') || lowerPath.endsWith('.gif')) return null;

    final padded = ' ${_norm('$title $pageUrl $imageUrl')} ';

    // Wrong subject: accessories, wallpapers and so on.
    for (final bad in _rejectWords) {
      if (_hasWord(padded, bad)) return null;
    }
    // Must mention every distinctive part of the model name (a15, 14, pro ...).
    if (tokens.isEmpty || !tokens.every((t) => _hasWord(padded, t))) return null;

    var score = 20;
    final brandWord = _norm(brand);
    if (brandWord.isNotEmpty && brandWord != 'other' && _hasWord(padded, brandWord)) score += 10;

    // A different edition (Pro/Plus/Ultra...) of the same family.
    final titleAndPage = ' ${_norm('$title $pageUrl')} ';
    for (final v in _variantWords) {
      if (!tokens.contains(v) && _hasWord(titleAndPage, v)) score -= 60;
    }

    final mentionsBack = _hasWord(padded, 'back') || _hasWord(padded, 'rear');
    if (mentionsBack) {
      score += 25;
    } else if (_hasWord(padded, 'front')) {
      score -= 10;
    }

    var official = false;
    if (domains.isNotEmpty) {
      final pageHost = Uri.tryParse(pageUrl)?.host.toLowerCase() ?? '';
      final imageOfficial = _isOfficialHost(image.host.toLowerCase(), domains);
      final pageOfficial = _isOfficialHost(pageHost, domains);
      if (imageOfficial) score += 60;
      if (pageOfficial) score += 40;
      official = imageOfficial || pageOfficial;
    }

    final width = props is Map ? props['width'] : null;
    if (width is num && width < 200) score -= 20;

    if (score < minScore) return null;
    return _Hit(imageUrl, (thumbUrl != null && thumbUrl.startsWith('https://')) ? thumbUrl : null,
        official ? 'official' : 'web', score);
  }

  // ------------------------------------------------------- name variants

  /// Different ways people write the same phone, so a miss on one spelling
  /// does not end the search ("Galaxy A15", "A15 5G", "Redmi Note 13 Pro+").
  static List<String> nameVariants(String brand, String model) {
    final base = phoneQueryName(brand, model);
    final out = <String>[base];
    void add(String v) {
      final t = v.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (t.isNotEmpty && !out.any((e) => e.toLowerCase() == t.toLowerCase())) out.add(t);
    }
    final m = model.trim();
    final b = brand.trim();
    if (b.isNotEmpty && b != 'Other') add('$b $m');
    if (!RegExp(r'\b5g\b', caseSensitive: false).hasMatch(base)) add('$base 5G');
    add(base.replaceAll(RegExp(r'\b5G\b', caseSensitive: false), ''));
    add(base.replaceAll(RegExp(r'\bPlus\b', caseSensitive: false), '+'));
    add(base.replaceAll('+', ' Plus'));
    add(base.replaceFirst(RegExp(r'^Samsung\s+', caseSensitive: false), ''));
    add(base.replaceAllMapped(RegExp(r'\b([A-Za-z])\s(\d)'), (x) => '${x[1]}${x[2]}'));
    return out;
  }

  // ------------------------------------------------------ DuckDuckGo (free)

  DateTime _nextDdg = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _ddgThrottle() async {
    final now = DateTime.now();
    final start = _nextDdg.isAfter(now) ? _nextDdg : now;
    _nextDdg = start.add(const Duration(milliseconds: 600));
    final wait = start.difference(now);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  /// Free image search with no key. Uses DuckDuckGo's public image endpoint,
  /// which is unofficial and may change. Results go through the same scoring
  /// as Brave, so official manufacturer images still get the green tick.
  Future<List<_Hit>> _searchDuckDuckGo(String brand, String model) async {
    final domains = _domainsFor(brand);
    final tokens = _modelTokens(model);
    final names = nameVariants(brand, model);
    final hits = <_Hit>[];
    var failures = 0;
    var attempts = 0;

    Future<void> run(String q, {int page = 0}) async {
      attempts++;
      try {
        hits.addAll(await _ddgQuery(q, brand, tokens, domains, page: page));
      } catch (_) {
        failures++;
      }
    }

    // Round 1: search ONLY the manufacturer's own website(s) first.
    for (final d in domains.take(3)) {
      await run('${names.first} site:$d');
      if (hits.any((h) => h.source == 'official')) break;
    }
    // Round 2: general search for a back photo.
    if (!hits.any((h) => h.source == 'official')) {
      await run('${names.first} back panel');
      if (hits.isEmpty) await run('${names.first} smartphone');
    }
    // Round 3: alternate spellings, only if still nothing.
    for (final n in names.skip(1).take(3)) {
      if (hits.isNotEmpty) break;
      await run('$n smartphone');
    }

    if (hits.isEmpty && attempts > 0 && failures == attempts) {
      throw const SocketException('DuckDuckGo unreachable');
    }
    final seen = <String>{};
    hits.retainWhere((h) => seen.add(h.url));
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  Future<List<_Hit>> _ddgQuery(String query, String brand, List<String> tokens, List<String> domains, {int page = 0}) async {
    await _ddgThrottle();
    const headers = {
      'User-Agent': 'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      'Accept-Language': 'en-US,en;q=0.9',
    };
    // Step 1: DuckDuckGo hands out a short-lived token (vqd) for the search.
    final landing = await http
        .get(Uri.https('duckduckgo.com', '/', {'q': query, 'iax': 'images', 'ia': 'images'}), headers: headers)
        .timeout(const Duration(seconds: 15));
    if (landing.statusCode != 200) throw HttpException('DuckDuckGo ${landing.statusCode}');
    final vqd = RegExp(r'vqd=\W?([\d-]+)').firstMatch(landing.body)?.group(1);
    if (vqd == null) throw const HttpException('DuckDuckGo token not found');

    // Step 2: the actual image results.
    final response = await http.get(
      Uri.https('duckduckgo.com', '/i.js', {
        'l': 'us-en',
        'o': 'json',
        'q': query,
        'vqd': vqd,
        'f': ',,,,,',
        'p': '1',
        if (page > 0) 's': '${page * 100}',
      }),
      headers: {...headers, 'Referer': 'https://duckduckgo.com/'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('DuckDuckGo images ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];

    final hits = <_Hit>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      // Convert to the shape _scoreResult already understands.
      final mapped = <String, dynamic>{
        'title': raw['title'],
        'url': raw['url'],
        'thumbnail': {'src': raw['thumbnail']},
        'properties': {'url': raw['image'], 'width': raw['width']},
      };
      // minScore 30: accept the right model even if it is not a back view.
      final hit = _scoreResult(mapped, brand, tokens, domains, minScore: 30);
      if (hit != null) hits.add(hit);
    }
    return hits;
  }

  // ------------------------------------------------- Wikipedia + Commons (free)

  /// Free, key-less sources. Tries several Wikipedia queries and then
  /// Wikimedia Commons file search, so far more models get a photo than with
  /// a single Wikipedia query. These are NOT official manufacturer images.
  Future<List<_Hit>> _searchFree(String brand, String model) async {
    final hits = <_Hit>[];
    var failures = 0;
    var attempts = 0;
    final names = nameVariants(brand, model);
    final tokens = _modelTokens(model);

    Future<void> step(Future<void> Function() job) async {
      attempts++;
      try {
        await job();
      } catch (_) {
        failures++;
      }
    }

    // 1) Wikipedia page images, every spelling.
    for (final n in names) {
      if (hits.isNotEmpty) break;
      for (final q in [n, '$n smartphone']) {
        if (hits.isNotEmpty) break;
        await step(() async {
          final hit = await _searchWikipedia(q, tokens);
          if (hit != null) hits.add(hit);
        });
      }
    }
    // 2) Wikimedia Commons image files.
    for (final n in names) {
      if (hits.isNotEmpty) break;
      await step(() async => hits.addAll(await _searchCommons(n, tokens)));
    }
    // 3) Wikidata item image (covers phones without a Wikipedia article).
    for (final n in names) {
      if (hits.isNotEmpty) break;
      await step(() async {
        final hit = await _searchWikidata(n, tokens);
        if (hit != null) hits.add(hit);
      });
    }
    // 4) Openverse (openly licensed photos from many sites).
    for (final n in names.take(3)) {
      if (hits.isNotEmpty) break;
      await step(() async => hits.addAll(await _searchOpenverse(n, tokens)));
    }

    if (hits.isEmpty && attempts > 0 && failures == attempts) {
      throw const SocketException('free sources unreachable');
    }
    return hits;
  }

  Future<_Hit?> _searchWikidata(String name, List<String> tokens) async {
    final search = await http.get(
      Uri.https('www.wikidata.org', '/w/api.php', {
        'action': 'wbsearchentities',
        'search': name,
        'language': 'en',
        'limit': '6',
        'format': 'json',
      }),
      headers: {'User-Agent': _ua},
    ).timeout(const Duration(seconds: 15));
    if (search.statusCode != 200) throw HttpException('Wikidata ${search.statusCode}');
    final data = jsonDecode(utf8.decode(search.bodyBytes));
    final list = data is Map ? data['search'] : null;
    if (list is! List) return null;

    for (final item in list.whereType<Map>()) {
      final label = '${item['label'] ?? ''} ${item['description'] ?? ''}';
      final labelOnly = (item['label'] ?? '').toString();
      if (!_hasAllTokens(labelOnly, tokens)) continue;
      final padded = ' ${_norm(labelOnly)} ';
      if (_variantWords.any((v) => !tokens.contains(v) && _hasWord(padded, v))) continue;
      if (_rejectWords.any((w) => _hasWord(' ${_norm(label)} ', w))) continue;
      final id = item['id']?.toString();
      if (id == null) continue;
      final claims = await http.get(
        Uri.https('www.wikidata.org', '/w/api.php', {
          'action': 'wbgetclaims',
          'entity': id,
          'property': 'P18',
          'format': 'json',
        }),
        headers: {'User-Agent': _ua},
      ).timeout(const Duration(seconds: 15));
      if (claims.statusCode != 200) continue;
      final c = jsonDecode(utf8.decode(claims.bodyBytes));
      final p18 = c is Map && c['claims'] is Map ? (c['claims'] as Map)['P18'] : null;
      if (p18 is! List || p18.isEmpty) continue;
      final value = (((p18.first as Map)['mainsnak'] as Map?)?['datavalue'] as Map?)?['value'];
      if (value is! String || value.isEmpty) continue;
      final url = Uri.https('commons.wikimedia.org', '/wiki/Special:FilePath/$value', {'width': '700'}).toString();
      return _Hit(url, null, 'wikipedia', 28);
    }
    return null;
  }

  Future<List<_Hit>> _searchOpenverse(String name, List<String> tokens) async {
    final response = await http.get(
      Uri.https('api.openverse.org', '/v1/images/', {
        'q': name,
        'page_size': '20',
        'mature': 'false',
      }),
      headers: {'User-Agent': _ua, 'Accept': 'application/json'},
    ).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Openverse ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final results = data is Map ? data['results'] : null;
    if (results is! List) return const [];

    final hits = <_Hit>[];
    for (final raw in results.whereType<Map>()) {
      final title = (raw['title'] ?? '').toString();
      final padded = ' ${_norm(title)} ';
      if (!tokens.every((t) => _hasWord(padded, t))) continue;
      if (_rejectWords.any((w) => _hasWord(padded, w))) continue;
      if (_variantWords.any((v) => !tokens.contains(v) && _hasWord(padded, v))) continue;
      final url = (raw['url'] ?? '').toString();
      final thumb = (raw['thumbnail'] ?? '').toString();
      if (!url.startsWith('https://')) continue;
      var score = 24;
      if (_hasWord(padded, 'back') || _hasWord(padded, 'rear')) score += 15;
      hits.add(_Hit(url, thumb.startsWith('https://') ? thumb : null, 'web', score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  Future<_Hit?> _searchWikipedia(String query, List<String> tokens) async {
    final uri = Uri.https('en.wikipedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': query,
      'gsrnamespace': '0',
      'gsrlimit': '8',
      'prop': 'pageimages',
      'piprop': 'thumbnail',
      'pithumbsize': '700',
      'format': 'json',
      'formatversion': '2',
    });
    final response = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Wikipedia ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final q = data is Map ? data['query'] : null;
    final pages = q is Map ? q['pages'] : null;
    if (pages is! List) return null;

    final sorted = pages.whereType<Map>().toList()
      ..sort((a, b) => ((a['index'] ?? 99) as num).compareTo((b['index'] ?? 99) as num));
    for (final page in sorted) {
      final title = (page['title'] ?? '').toString();
      final thumb = page['thumbnail'];
      final src = (thumb is Map ? thumb['source'] : null)?.toString();
      if (src == null || !src.startsWith('https://')) continue;
      if (!_hasAllTokens(title, tokens)) continue;
      final padded = ' ${_norm(title)} ';
      var otherEdition = false;
      for (final v in _variantWords) {
        if (!tokens.contains(v) && _hasWord(padded, v)) otherEdition = true;
      }
      if (otherEdition) continue;
      return _Hit(src, null, 'wikipedia', 30);
    }
    return null;
  }

  /// Searches Wikimedia Commons image files (many phones have photos there
  /// even when they have no Wikipedia page picture).
  Future<List<_Hit>> _searchCommons(String name, List<String> tokens) async {
    final uri = Uri.https('commons.wikimedia.org', '/w/api.php', {
      'action': 'query',
      'generator': 'search',
      'gsrsearch': '$name filetype:bitmap',
      'gsrnamespace': '6',
      'gsrlimit': '12',
      'prop': 'imageinfo',
      'iiprop': 'url|size|mime',
      'iiurlwidth': '700',
      'format': 'json',
      'formatversion': '2',
    });
    final response = await http.get(uri, headers: {'User-Agent': _ua}).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) throw HttpException('Commons ${response.statusCode}');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    final q = data is Map ? data['query'] : null;
    final pages = q is Map ? q['pages'] : null;
    if (pages is! List) return const [];

    final hits = <_Hit>[];
    for (final page in pages.whereType<Map>()) {
      final title = (page['title'] ?? '').toString();
      final padded = ' ${_norm(title)} ';
      if (!tokens.every((t) => _hasWord(padded, t))) continue;
      if (_rejectWords.any((w) => _hasWord(padded, w))) continue;
      var otherEdition = false;
      for (final v in _variantWords) {
        if (!tokens.contains(v) && _hasWord(padded, v)) otherEdition = true;
      }
      if (otherEdition) continue;
      final infos = page['imageinfo'];
      final info = infos is List && infos.isNotEmpty && infos.first is Map ? infos.first as Map : null;
      if (info == null) continue;
      final mime = (info['mime'] ?? '').toString();
      if (mime != 'image/jpeg' && mime != 'image/png') continue;
      final src = (info['thumburl'] ?? info['url'])?.toString();
      if (src == null || !src.startsWith('https://')) continue;
      var score = 25;
      if (_hasWord(padded, 'back') || _hasWord(padded, 'rear')) score += 20;
      hits.add(_Hit(src, null, 'wikipedia', score));
    }
    hits.sort((a, b) => b.score.compareTo(a.score));
    return hits;
  }

  // ---------------------------------------------------------------- download

  Future<String?> _saveImage(String key, _Hit hit) async {
    final candidates = <String>[hit.url, if (hit.thumb != null) hit.thumb!];
    for (final url in candidates) {
      try {
        final response = await http.get(Uri.parse(url), headers: {
          'User-Agent': _ua,
          'Accept': 'image/*,*/*;q=0.5',
        }).timeout(const Duration(seconds: 20));
        if (response.statusCode != 200) continue;
        final bytes = response.bodyBytes;
        if (bytes.length < 3000 || bytes.length > 8 * 1024 * 1024) continue;
        if (!_looksLikeImage(bytes)) continue;
        final dir = await _dir();
        final name = '$key.img';
        await File(p.join(dir.path, name)).writeAsBytes(bytes, flush: true);
        return name;
      } catch (_) {
        continue;
      }
    }
    return null;
  }
}
