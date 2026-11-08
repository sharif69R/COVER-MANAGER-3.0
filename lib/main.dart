import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'services/photo_service.dart';
import 'ui/home_page.dart';

// NOTE: the GitHub workflow reads this constant to build the launcher icon.
// Keep it in this file, on one line, in exactly this form.
const String _repairLogo = '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';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final path = p.join(await getDatabasesPath(), 'cover_inventory.db');
  final db = await openDatabase(
    path,
    version: 2,
    onCreate: (db, _) async {
      await db.execute(
          '''CREATE TABLE stock(id INTEGER PRIMARY KEY AUTOINCREMENT, phone_id TEXT NOT NULL UNIQUE, brand TEXT NOT NULL, model TEXT NOT NULL, image_path TEXT, image_url TEXT, quantity INTEGER NOT NULL DEFAULT 0, description TEXT NOT NULL DEFAULT '')''');
      await PhotoService.createTable(db);
    },
    // Version 2 adds the photo cache; existing stock data is left untouched.
    onUpgrade: (db, oldVersion, newVersion) async {
      if (oldVersion < 2) await PhotoService.createTable(db);
    },
  );
  runApp(CoverApp(db: db, photos: PhotoService(db)));
}

class CoverApp extends StatelessWidget {
  final Database db;
  final PhotoService photos;
  const CoverApp({super.key, required this.db, required this.photos});

  @override
  Widget build(BuildContext context) {
    final Uint8List logo = base64Decode(_repairLogo);
    return MaterialApp(
      title: 'Repair X Zone Cover Management',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF087F6B)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF5F7F7),
      ),
      home: HomePage(db: db, photos: photos, logo: logo),
    );
  }
}
