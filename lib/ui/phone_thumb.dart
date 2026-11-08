import 'dart:io';

import 'package:flutter/material.dart';

import '../services/photo_service.dart';

const Color kBrandGreen = Color(0xFF087F6B);

/// Back-photo of a phone. Looks the photo up (or loads it from the device),
/// opens a zoomable viewer when tapped, and retries the search when no photo
/// was found.
class PhoneThumb extends StatefulWidget {
  final PhotoService photos;
  final String brand, model;
  final double width, height;
  const PhoneThumb({
    super.key,
    required this.photos,
    required this.brand,
    required this.model,
    this.width = 64,
    this.height = 84,
  });

  @override
  State<PhoneThumb> createState() => _PhoneThumbState();
}

class _PhoneThumbState extends State<PhoneThumb> {
  late Future<PhotoResult> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.photos.lookup(widget.brand, widget.model);
  }

  void _retry() {
    setState(() => _future = widget.photos.lookup(widget.brand, widget.model, force: true));
  }

  Widget _frame(Widget child) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFFEAF0EF),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      );

  Widget _placeholder(PhotoResult? result) {
    final offline = result?.source == 'offline';
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(offline ? Icons.cloud_off : Icons.phone_android, size: widget.width * 0.32, color: kBrandGreen),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 3),
          child: Text(widget.model,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, height: 1.1)),
        ),
        const SizedBox(height: 2),
        Text(
          offline ? 'Offline\ntap to retry' : 'No photo\ntap to retry',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 8, color: Colors.black54, height: 1.1),
        ),
      ],
    );
  }

  void _openViewer(PhotoResult result) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${widget.brand} ${widget.model}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 10),
              Flexible(
                child: InteractiveViewer(
                  minScale: 1,
                  maxScale: 5,
                  child: Image.file(File(result.path!), fit: BoxFit.contain),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (result.official) const Icon(Icons.verified, size: 18, color: kBrandGreen),
                  if (result.official) const SizedBox(width: 6),
                  Flexible(
                    child: Text(result.label,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12, color: Colors.black54)),
                  ),
                ],
              ),
              if (!result.official)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    !PhotoService.hasBrave
                        ? 'No official photo found - showing the best free match. Tap "Search again" to retry.'
                        : (widget.photos.braveProblem ?? 'No official photo found - showing the best free match.'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 11, color: Colors.deepOrange),
                  ),
                ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  TextButton.icon(
                    onPressed: () {
                      Navigator.pop(dialogContext);
                      _retry();
                    },
                    icon: const Icon(Icons.refresh),
                    label: const Text('Search again'),
                  ),
                  FilledButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Close')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<PhotoResult>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return _frame(const Center(
              child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            ));
          }
          final result = snapshot.data;
          if (result == null || !result.found) {
            return GestureDetector(onTap: _retry, child: _frame(_placeholder(result)));
          }
          return GestureDetector(
            onTap: () => _openViewer(result),
            child: _frame(Stack(
              fit: StackFit.expand,
              children: [
                Padding(
                  padding: const EdgeInsets.all(3),
                  child: Image.file(
                    File(result.path!),
                    fit: BoxFit.contain,
                    errorBuilder: (_, __, ___) => _placeholder(null),
                  ),
                ),
                if (result.official)
                  const Positioned(
                    right: 2,
                    bottom: 2,
                    child: Icon(Icons.verified, size: 16, color: kBrandGreen),
                  ),
              ],
            )),
          );
        },
      );
}
