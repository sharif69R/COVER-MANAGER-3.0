import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';

import '../models/phone.dart';
import '../services/photo_service.dart';
import 'phone_thumb.dart';

class HomePage extends StatefulWidget {
  final Database db;
  final PhotoService photos;
  final Uint8List logo;
  const HomePage({super.key, required this.db, required this.photos, required this.logo});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static Future<List<Phone>>? _catalogueFuture;

  final search = TextEditingController();
  final inventorySearch = TextEditingController();
  Timer? _debounce;

  List<Phone> matches = [];
  List<Map<String, Object?>> stock = [];
  Map<String, Map<String, Object?>> stockByKey = {};
  bool busy = false, searched = false;
  String? error;
  int tab = 0;
  int photoEpoch = 0;
  String stockFilter = 'all'; // all | in | out

  @override
  void initState() {
    super.initState();
    loadStock();
    // Warm up the catalogue so the first search is instant.
    _catalogueFuture ??= loadPhoneCatalogue();
    _catalogueFuture!.catchError((_) => <Phone>[]);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    search.dispose();
    inventorySearch.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ data

  Future<void> loadStock() async {
    final rows = await widget.db.query('stock', orderBy: 'brand COLLATE NOCASE, model COLLATE NOCASE');
    final byKey = <String, Map<String, Object?>>{};
    for (final row in rows) {
      byKey[PhotoService.keyFor('${row['brand']}', '${row['model']}')] = row;
    }
    if (mounted) {
      setState(() {
        stock = rows;
        stockByKey = byKey;
      });
    }
  }

  /// Matches by name first (so saved stock is found whichever catalogue
  /// variant was picked) and falls back to the stored catalogue id.
  Map<String, Object?>? saved(Phone phone) {
    final byName = stockByKey[PhotoService.keyFor(phone.brand, phone.model)];
    if (byName != null) return byName;
    for (final row in stock) {
      if (row['phone_id'] == phone.id) return row;
    }
    return null;
  }

  void _onSearchChanged(String value) {
    setState(() {});
    _debounce?.cancel();
    if (value.trim().isEmpty) {
      setState(() {
        matches = [];
        searched = false;
        error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), findPhones);
  }

  Future<void> findPhones() async {
    final text = search.text.trim();
    if (text.isEmpty) return;
    setState(() {
      busy = true;
      searched = true;
      error = null;
    });
    try {
      final all = await (_catalogueFuture ??= loadPhoneCatalogue());
      final q = text.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), ' ');
      final terms = q.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
      final compactQuery = terms.join();
      final queryText = terms.join(' ');
      final ranked = <({Phone phone, int score})>[];
      final seen = <String>{};
      for (final phone in all) {
        if (!phone.matches(terms, compactQuery)) continue;
        final identity = '${phone.brand.toLowerCase()}|${phone.model.toLowerCase()}';
        if (!seen.add(identity)) continue;
        final display = phone.searchText;
        var score = display == queryText ? 1000 : display.startsWith(queryText) ? 500 : 100;
        if (phone.model.toLowerCase().startsWith(queryText)) score += 200;
        if (phone.matchesExactly(terms)) score += 150;
        ranked.add((phone: phone, score: score));
      }
      ranked.sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byBrand = a.phone.brand.toLowerCase().compareTo(b.phone.brand.toLowerCase());
        return byBrand != 0 ? byBrand : a.phone.model.toLowerCase().compareTo(b.phone.model.toLowerCase());
      });
      // Ignore the answer if the user already typed something else.
      if (mounted && text == search.text.trim()) {
        setState(() => matches = ranked.take(60).map((e) => e.phone).toList());
      }
    } catch (e) {
      _catalogueFuture = null;
      if (mounted) {
        setState(() {
          matches = [];
          error = 'Could not load the phone catalogue. ($e)';
        });
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // --------------------------------------------------------------- actions

  Future<void> edit(Phone phone, {Map<String, Object?>? old}) async {
    final result = await showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheet) => _StockSheet(
        photos: widget.photos,
        brand: phone.brand,
        model: phone.model,
        quantity: (old?['quantity'] as int?) ?? 0,
        description: (old?['description'] as String?) ?? '',
        isNew: old == null,
      ),
    );
    if (result == null) return;
    final values = <String, Object?>{
      'brand': phone.brand,
      'model': phone.model,
      'quantity': result['quantity'],
      'description': result['description'],
    };
    if (old != null) {
      await widget.db.update('stock', values, where: 'id = ?', whereArgs: [old['id']]);
    } else {
      await widget.db.insert('stock', {'phone_id': phone.id, ...values},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await loadStock();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Saved on this device.')));
    }
  }

  Future<void> remove(Map<String, Object?> row) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete saved phone?'),
        content: Text('Remove ${row['brand']} ${row['model']} from stock?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (yes == true) {
      await widget.db.delete('stock', where: 'id = ?', whereArgs: [row['id']]);
      await loadStock();
    }
  }

  Future<void> retryMissingPhotos() async {
    await widget.photos.clearMisses();
    if (!mounted) return;
    setState(() => photoEpoch++);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Searching again for phones with no photo...')));
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: Row(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(widget.logo, width: 48, height: 52, fit: BoxFit.contain),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                const Text('REPAIR X ZONE', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900)),
                Text(tab == 0 ? 'COVER MANAGEMENT' : 'YOUR COVER INVENTORY',
                    style: const TextStyle(fontSize: 10, color: Colors.black54, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
          actions: [
            IconButton(
              tooltip: 'Search again for phones with no photo',
              icon: const Icon(Icons.image_search),
              onPressed: retryMissingPhotos,
            ),
          ],
        ),
        body: SafeArea(child: tab == 0 ? searchView() : inventoryView()),
        bottomNavigationBar: NavigationBar(
          selectedIndex: tab,
          onDestinationSelected: (v) => setState(() => tab = v),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.search), label: 'Find phone'),
            NavigationDestination(icon: Icon(Icons.inventory_2_outlined), label: 'My stock'),
          ],
        ),
      );

  Widget _stockLabel(Map<String, Object?>? row) {
    if (row == null) {
      return const Text('Not in your list - tap to add',
          style: TextStyle(fontSize: 12, color: Colors.black54));
    }
    final qty = (row['quantity'] as int?) ?? 0;
    return Text(
      qty > 0 ? 'IN STOCK - $qty cover(s)' : 'OUT OF STOCK',
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: qty > 0 ? kBrandGreen : Colors.red),
    );
  }

  Widget _phoneRow({
    required String brand,
    required String model,
    required Widget status,
    String description = '',
    Widget? trailing,
    required VoidCallback onTap,
  }) =>
      Card(
        elevation: 0,
        color: Colors.white,
        margin: const EdgeInsets.only(bottom: 8),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(children: [
              PhoneThumb(
                key: ValueKey('$brand|$model|$photoEpoch'),
                photos: widget.photos,
                brand: brand,
                model: model,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('$brand $model', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 4),
                  status,
                  if (description.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(description, maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12, color: Colors.black54)),
                    ),
                ]),
              ),
              if (trailing != null) trailing,
            ]),
          ),
        ),
      );

  Widget searchView() {
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            gradient: const LinearGradient(colors: [Color(0xFF087F6B), Color(0xFF145D70)]),
          ),
          child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Find a phone model',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22)),
            SizedBox(height: 5),
            Text('Type a model to see its back photo and whether you have the cover.',
                style: TextStyle(color: Colors.white70)),
          ]),
        ),
        const SizedBox(height: 14),
        Row(children: [
          Expanded(
            child: TextField(
              controller: search,
              textInputAction: TextInputAction.search,
              onChanged: _onSearchChanged,
              onSubmitted: (_) => findPhones(),
              decoration: InputDecoration(
                hintText: 'Samsung A15, iPhone 15 Pro...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: search.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () {
                          search.clear();
                          _onSearchChanged('');
                        },
                      ),
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 56,
            child: FilledButton(
              onPressed: busy ? null : findPhones,
              child: busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.arrow_forward),
            ),
          ),
        ]),
        const SizedBox(height: 4),
        Text(
          PhotoService.hasBrave
              ? 'Search works offline - photos are found online once, then saved on this phone'
              : 'Search works offline - photos are found online for free, once, then saved on this phone',
          style: const TextStyle(fontSize: 12, color: Colors.black54),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: const TextStyle(color: Colors.red))),
        if (searched && error == null)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Text('${matches.length} matching models', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
      ]),
    );

    Widget body;
    if (!searched) {
      body = ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Popular brands', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: ['Samsung', 'Apple', 'Infinix', 'OPPO', 'vivo', 'Xiaomi', 'OnePlus', 'Huawei', 'Google Pixel',
            'Nothing', 'TECNO', 'Realme', 'Motorola', 'Honor']
              .map((b) => ActionChip(
                    label: Text(b),
                    onPressed: () {
                      search.text = b;
                      _onSearchChanged(b);
                    },
                  ))
              .toList(),
        ),
        const SizedBox(height: 20),
        const Text('- Search the offline phone catalogue\n'
            '- Tap a photo to zoom in\n'
            '- Enter cover quantity and save your stock offline'),
      ]);
    } else if (matches.isEmpty && !busy && error == null) {
      body = const Center(
        child: Padding(padding: EdgeInsets.all(20), child: Text('No matching models found. Try a shorter search.')),
      );
    } else {
      body = ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        itemCount: matches.length,
        itemBuilder: (context, index) {
          final phone = matches[index];
          final old = saved(phone);
          return _phoneRow(
            brand: phone.brand,
            model: phone.model,
            status: _stockLabel(old),
            description: (old?['description'] as String?) ?? '',
            trailing: Icon(old == null ? Icons.add_circle_outline : Icons.edit_outlined, color: kBrandGreen),
            onTap: () => edit(phone, old: old),
          );
        },
      );
    }
    return Column(children: [header, Expanded(child: body)]);
  }

  List<Map<String, Object?>> get filteredStock {
    final q = inventorySearch.text.trim().toLowerCase();
    return stock.where((row) {
      final qty = (row['quantity'] as int?) ?? 0;
      if (stockFilter == 'in' && qty <= 0) return false;
      if (stockFilter == 'out' && qty > 0) return false;
      if (q.isEmpty) return true;
      return '${row['brand']} ${row['model']} ${row['description']}'.toLowerCase().contains(q);
    }).toList();
  }

  Widget inventoryView() {
    if (stock.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Text('No saved phones yet. Search for a phone and add stock.', textAlign: TextAlign.center),
        ),
      );
    }
    final total = stock.fold<int>(0, (s, r) => s + ((r['quantity'] as int?) ?? 0));
    final outCount = stock.where((r) => ((r['quantity'] as int?) ?? 0) <= 0).length;
    final rows = filteredStock;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
        child: Row(children: [
          Expanded(child: _Metric(label: 'PHONE MODELS', value: '${stock.length}')),
          const SizedBox(width: 8),
          Expanded(child: _Metric(label: 'TOTAL COVERS', value: '$total')),
          const SizedBox(width: 8),
          Expanded(child: _Metric(label: 'OUT OF STOCK', value: '$outCount')),
        ]),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: TextField(
          controller: inventorySearch,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Search your stock',
            prefixIcon: const Icon(Icons.search),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(15), borderSide: BorderSide.none),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
        child: Wrap(spacing: 8, children: [
          for (final f in const [('all', 'All'), ('in', 'In stock'), ('out', 'Out of stock')])
            ChoiceChip(
              label: Text(f.$2),
              selected: stockFilter == f.$1,
              onSelected: (_) => setState(() => stockFilter = f.$1),
            ),
        ]),
      ),
      Expanded(
        child: rows.isEmpty
            ? const Center(child: Text('Nothing matches this filter.'))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                itemCount: rows.length,
                itemBuilder: (context, index) {
                  final row = rows[index];
                  final phone = Phone('${row['phone_id']}', '${row['brand']}', '${row['model']}', null);
                  return _phoneRow(
                    brand: phone.brand,
                    model: phone.model,
                    status: _stockLabel(row),
                    description: (row['description'] as String?) ?? '',
                    onTap: () => edit(phone, old: row),
                    trailing: PopupMenuButton<String>(
                      onSelected: (v) {
                        if (v == 'edit') {
                          edit(phone, old: row);
                        } else {
                          remove(row);
                        }
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'edit', child: Text('Edit stock')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

/// Bottom sheet for adding or editing the stock of one phone.
class _StockSheet extends StatefulWidget {
  final PhotoService photos;
  final String brand, model, description;
  final int quantity;
  final bool isNew;
  const _StockSheet({
    required this.photos,
    required this.brand,
    required this.model,
    required this.quantity,
    required this.description,
    required this.isNew,
  });

  @override
  State<_StockSheet> createState() => _StockSheetState();
}

class _StockSheetState extends State<_StockSheet> {
  late final TextEditingController qty = TextEditingController(text: '${widget.quantity}');
  late final TextEditingController desc = TextEditingController(text: widget.description);

  @override
  void dispose() {
    qty.dispose();
    desc.dispose();
    super.dispose();
  }

  void _bump(int delta) {
    final current = int.tryParse(qty.text.trim()) ?? 0;
    final next = current + delta;
    qty.text = '${next < 0 ? 0 : next}';
  }

  void _save() {
    final count = int.tryParse(qty.text.trim());
    if (count == null || count < 0) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Enter a valid quantity (0 or more).')));
      return;
    }
    Navigator.pop(context, <String, Object?>{'quantity': count, 'description': desc.text.trim()});
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, MediaQuery.of(context).viewInsets.bottom + 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            PhoneThumb(
              photos: widget.photos,
              brand: widget.brand,
              model: widget.model,
              width: 90,
              height: 120,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.isNew ? 'Add cover stock' : 'Edit cover stock',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                Text('${widget.brand} ${widget.model}'),
              ]),
            ),
          ]),
          const SizedBox(height: 16),
          Row(children: [
            IconButton.filledTonal(onPressed: () => _bump(-1), icon: const Icon(Icons.remove)),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(
                controller: qty,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                decoration: const InputDecoration(
                  labelText: 'Number of covers available',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(width: 10),
            IconButton.filledTonal(onPressed: () => _bump(1), icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 12),
          TextField(
            controller: desc,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              hintText: 'Transparent, black, silicone, premium...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('Save phone'),
            ),
          ),
        ]),
      );
}

class _Metric extends StatelessWidget {
  final String label, value;
  const _Metric({required this.label, required this.value});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(value, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
          Text(label, style: const TextStyle(fontSize: 9, color: Colors.black54)),
        ]),
      );
}
