import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/storage_service.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';

/// v1.1.0 — Data and Storage (Telegram-style):
///  • network usage (live session counters from the API client)
///  • storage usage with a per-type breakdown (photos/videos/gifs/music)
///  • per-category cache clearing + full wipe
///  • a media manager that lists every cached file and lets you delete it
///  • avatars/photos are cached ON DISK here — they load instantly next time
///    and the app stops re-downloading them.
class DataStorageScreen extends StatefulWidget {
  const DataStorageScreen({super.key});

  @override
  State<DataStorageScreen> createState() => _DataStorageScreenState();
}

class _DataStorageScreenState extends State<DataStorageScreen> {
  StorageBreakdown? _breakdown;
  bool _working = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final b = await StorageService.I.breakdown();
    if (mounted) setState(() => _breakdown = b);
  }

  Future<void> _clear(String type, String label) async {
    final s = AppState.I.str;
    setState(() => _working = true);
    await StorageService.I.clearType(type);
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() => _working = false);
    showGlassToast(context, '$label — ${s.cacheClearedToast}',
        icon: Icons.cleaning_services_rounded);
    _refresh();
  }

  Future<void> _clearAll() async {
    final s = AppState.I.str;
    setState(() => _working = true);
    await StorageService.I.clearAll();
    await Future.delayed(const Duration(milliseconds: 120));
    if (!mounted) return;
    setState(() => _working = false);
    showGlassToast(context, s.cacheClearedToast,
        icon: Icons.cleaning_services_rounded);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final b = _breakdown;

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.text),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.dataStorageTitle,
                style: TextStyle(
                    fontSize: 16.5,
                    fontWeight: FontWeight.w800,
                    color: p.text)),
            Text(s.dataStorageSub,
                style: TextStyle(fontSize: 10.5, color: p.text3)),
          ],
        ),
      ),
      body: Stack(children: [
        ListView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 40),
          children: [
            // ---------------- network usage ----------------
            _groupLabel(p, s.networkUsage),
            SectionCard(children: [
              ValueListenableBuilder<int>(
                valueListenable: _netTick,
                builder: (context, _, __) => Row(children: [
                  Expanded(
                    child: _netCell(
                        p, Icons.arrow_upward_rounded, const Color(0xFF22C55E),
                        s.sentLabel, NetStats.I.sent),
                  ),
                  Container(
                      width: 1,
                      height: 44,
                      color: p.border),
                  Expanded(
                    child: _netCell(
                        p, Icons.arrow_downward_rounded,
                        const Color(0xFF38BDF8), s.receivedLabel,
                        NetStats.I.received),
                  ),
                ]),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
                child: Row(children: [
                  Icon(Icons.circle, size: 7, color: const Color(0xFF22C55E)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                        '${s.sessionData} · ${StorageService.humanSize(NetStats.I.sent + NetStats.I.received)}',
                        style: TextStyle(
                            fontSize: 11, color: p.text3)),
                  ),
                  GestureDetector(
                    onTap: () {
                      NetStats.I.reset();
                      _netTick.value++;
                    },
                    child: Text(s.resetLabel,
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            color: p.accent)),
                  ),
                ]),
              ),
              const SizedBox(height: 6),
            ]),

            // ---------------- storage usage ----------------
            _groupLabel(p, s.storageUsage),
            SectionCard(children: [
              if (b != null) ...[
                // v1.2.0 — Telegram's signature segmented usage bar: cache
                // share per media type at a glance.
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      height: 9,
                      child: Row(
                        children: [
                          for (final seg in <(Color, int)>[
                            (const Color(0xFF38BDF8), b.images),
                            (const Color(0xFF8B5CF6), b.videos),
                            (const Color(0xFF22C55E), b.gifs),
                            (const Color(0xFFF59E0B), b.audio),
                            (p.text3, b.other),
                          ])
                            if (seg.$2 > 0)
                              Expanded(
                                flex: seg.$2,
                                child: ColoredBox(color: seg.$1),
                              ),
                          if (b.total <= 0)
                            Expanded(
                              child: ColoredBox(
                                  color: p.border.withValues(alpha: .6)),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
                _typeRow(p, Icons.photo_outlined, const Color(0xFF38BDF8),
                    s.photosLabel, b.images, () => _clear('image', s.photosLabel)),
                _typeRow(p, Icons.videocam_outlined, const Color(0xFF8B5CF6),
                    s.videosLabel, b.videos, () => _clear('video', s.videosLabel)),
                _typeRow(p, Icons.gif_box_outlined, const Color(0xFF22C55E),
                    s.gifsLabel, b.gifs, () => _clear('gif', s.gifsLabel)),
                _typeRow(p, Icons.music_note_outlined, const Color(0xFFF59E0B),
                    s.musicLabel, b.audio, () => _clear('audio', s.musicLabel)),
                _typeRow(p, Icons.insert_drive_file_outlined, p.text3,
                    s.filesLabel, b.other, () => _clear('file', s.filesLabel)),
                Divider(height: 14, color: p.border),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(children: [
                    Text('${s.cacheLabel} · ${b.count}',
                        style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w800,
                            color: p.text)),
                    const Spacer(),
                    Text(StorageService.humanSize(b.total),
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w900,
                            color: p.accent)),
                  ]),
                ),
                const SizedBox(height: 4),
              ] else
                const Padding(
                  padding: EdgeInsets.all(22),
                  child: Center(
                      child: SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2))),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 2, 10, 8),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: _working ? null : _clearAll,
                      child: Container(
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444).withValues(alpha: .10),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(s.clearAll,
                            style: const TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w800,
                                color: Color(0xFFEF4444))),
                      ),
                    ),
                  ),
                ]),
              ),
            ]),

            // ---------------- preferences ----------------
            _groupLabel(p, s.settingsTitle),
            SectionCard(children: [
              ValueListenableBuilder<bool>(
                valueListenable: MediaPrefs.autoLoad,
                builder: (context, v, _) => ListRow(
                  icon: Icons.cloud_download_outlined,
                  title: s.autoLoadMedia,
                  sub: s.autoLoadMediaSub,
                  trailing: _switch(p, v, (nv) => MediaPrefs.setAutoLoad(nv)),
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: MediaPrefs.saveToGallery,
                builder: (context, v, _) => ListRow(
                  icon: Icons.save_alt_rounded,
                  title: s.saveToGallery,
                  sub: '',
                  trailing: _switch(
                      p, v, (nv) => MediaPrefs.setSaveToGallery(nv)),
                ),
              ),
            ]),

            // ---------------- manage media ----------------
            _groupLabel(p, s.manageMedia),
            SectionCard(children: [
              ListRow(
                icon: Icons.folder_special_outlined,
                title: s.manageMedia,
                sub: s.manageMediaSub,
                onTap: _openManager,
              ),
            ]),
          ],
        ),
        if (_working)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: p.bgCard,
                    shape: BoxShape.circle,
                    boxShadow: const [
                      BoxShadow(color: Color(0x24000000), blurRadius: 20)
                    ],
                  ),
                  child: const SizedBox(
                      width: 26,
                      height: 26,
                      child: CircularProgressIndicator(strokeWidth: 2.4)),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _groupLabel(Palette p, String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 11, 10, 4),
      child: Text(label,
          style: TextStyle(fontSize: 10, color: p.text3,
              fontWeight: FontWeight.w600)),
    );
  }

  static final ValueNotifier<int> _netTick = ValueNotifier(0);

  Widget _netCell(Palette p, IconData icon, Color color, String label, int bytes) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 18, color: color),
        ),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label,
                style: TextStyle(fontSize: 10.5, color: p.text3)),
            const SizedBox(height: 2),
            Text(StorageService.humanSize(bytes),
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: p.text)),
          ],
        ),
      ]),
    );
  }

  Widget _typeRow(Palette p, IconData icon, Color color, String label,
      int bytes, VoidCallback onClear) {
    final s = AppState.I.str;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      child: Row(children: [
        const SizedBox(width: 6),
        Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: color.withValues(alpha: .12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 17, color: color),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(label,
              style: TextStyle(
                  fontSize: 13.5, fontWeight: FontWeight.w700, color: p.text)),
        ),
        Text(StorageService.humanSize(bytes),
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w700, color: p.text2)),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: bytes <= 0 ? null : onClear,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: bytes <= 0
                  ? p.bgSoft
                  : p.accentSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(s.clearCache,
                style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: bytes <= 0 ? p.text3 : p.accent)),
          ),
        ),
        const SizedBox(width: 4),
      ]),
    );
  }

  Widget _switch(Palette p, bool v, ValueChanged<bool> onChanged) {
    return GestureDetector(
      onTap: () => onChanged(!v),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        width: 44,
        height: 26,
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: v ? p.accent : p.bgSoft,
          borderRadius: BorderRadius.circular(13),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: v ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
          child: Container(
            width: 20,
            height: 20,
            decoration: const BoxDecoration(
                color: Colors.white, shape: BoxShape.circle),
          ),
        ),
      ),
    );
  }

  void _openManager() {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      builder: (_) => const MediaManagerScreen(),
    ));
  }
}

/// v1.1.0 — persisted media preferences (shared with the whole app).
class MediaPrefs {
  MediaPrefs._();
  static final ValueNotifier<bool> autoLoad = ValueNotifier(true);
  static final ValueNotifier<bool> saveToGallery = ValueNotifier(false);
  static bool _loaded = false;

  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    final sp = await SharedPreferences.getInstance();
    autoLoad.value = sp.getBool('pref.media.autoload') ?? true;
    saveToGallery.value = sp.getBool('pref.media.saveGallery') ?? false;
    autoLoad.addListener(() async {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('pref.media.autoload', autoLoad.value);
    });
    saveToGallery.addListener(() async {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('pref.media.saveGallery', saveToGallery.value);
    });
  }

  static Future<void> setAutoLoad(bool v) async {
    autoLoad.value = v;
  }

  static Future<void> setSaveToGallery(bool v) async {
    saveToGallery.value = v;
  }
}

/// v1.1.0 — the media manager: every cached file with a thumbnail, size and
/// date; tap a photo to preview it, long-press (or trash icon) to delete.
class MediaManagerScreen extends StatefulWidget {
  const MediaManagerScreen({super.key});

  @override
  State<MediaManagerScreen> createState() => _MediaManagerScreenState();
}

class _MediaManagerScreenState extends State<MediaManagerScreen> {
  List<CachedMediaFile>? _files;
  final Set<String> _picked = {};
  bool _multi = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final files = await StorageService.I.listCachedMedia();
    if (mounted) setState(() => _files = files);
  }

  Future<void> _deletePicked() async {
    final s = AppState.I.str;
    final files = _files ?? const <CachedMediaFile>[];
    for (final f in files) {
      if (_picked.contains(f.file.path)) {
        await StorageService.I.deleteFile(f.file);
      }
    }
    if (!mounted) return;
    showGlassToast(context, s.mediaDeletedToast,
        icon: Icons.delete_outline_rounded,
        color: const Color(0xFFEF4444));
    setState(() {
      _picked.clear();
      _multi = false;
    });
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.text),
        actions: [
          if (_picked.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: Color(0xFFEF4444)),
              onPressed: _deletePicked,
            ),
        ],
        title: _multi
            ? Text(s.selectedCount(_picked.length),
                style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: p.text))
            : Text(s.manageMedia,
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: p.text)),
      ),
      body: _files == null
          ? const Center(
              child: SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2)))
          : (_files!.isEmpty
              ? Center(
                  child: Text(s.mediaEmpty,
                      style: TextStyle(fontSize: 12.5, color: p.text3)))
              : GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 4,
                    crossAxisSpacing: 4,
                  ),
                  itemCount: _files!.length,
                  itemBuilder: (ctx, i) {
                    final f = _files![i];
                    final picked = _picked.contains(f.file.path);
                    final isImg =
                        f.type == 'image' || f.type == 'gif';
                    return GestureDetector(
                      onTap: () {
                        if (isImg && !_multi) {
                          _preview(f);
                        } else {
                          setState(() {
                            picked
                                ? _picked.remove(f.file.path)
                                : _picked.add(f.file.path);
                          });
                        }
                      },
                      onLongPress: () {
                        HapticFeedback.selectionClick();
                        setState(() {
                          _multi = true;
                          picked
                              ? _picked.remove(f.file.path)
                              : _picked.add(f.file.path);
                        });
                      },
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(picked ? 8 : 3),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            if (isImg)
                              Image.file(f.file,
                                  fit: BoxFit.cover,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, __, ___) => Container(
                                      color: p.bgSoft,
                                      child: Icon(Icons.image_outlined,
                                          size: 24, color: p.text3)))
                            else
                              Container(
                                color: p.bgSoft,
                                child: Icon(
                                    f.type == 'video'
                                        ? Icons.videocam_rounded
                                        : f.type == 'audio'
                                            ? Icons.music_note_rounded
                                            : Icons.insert_drive_file_rounded,
                                    size: 26,
                                    color: p.text3),
                              ),
                            if (f.type == 'gif')
                              PositionedDirectional(
                                bottom: 4,
                                start: 4,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 4, vertical: 1),
                                  color: Colors.black.withValues(alpha: .5),
                                  child: const Text('GIF',
                                      textDirection: TextDirection.ltr,
                                      style: TextStyle(
                                          color: Colors.white,
                                          fontSize: 7.5,
                                          fontWeight: FontWeight.w900)),
                                ),
                              ),
                            PositionedDirectional(
                              bottom: 3,
                              end: 4,
                              child: Text(StorageService.humanSize(f.size),
                                  textDirection: TextDirection.ltr,
                                  style: TextStyle(
                                      fontSize: 8,
                                      color: Colors.white,
                                      shadows: const [
                                        Shadow(
                                            color: Colors.black54,
                                            blurRadius: 4)
                                      ])),
                            ),
                            if (picked)
                              PositionedDirectional(
                                top: 4,
                                end: 4,
                                child: Container(
                                  width: 20,
                                  height: 20,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: p.accent,
                                    border: Border.all(
                                        color: Colors.white, width: 1.6),
                                  ),
                                  child: const Icon(Icons.check_rounded,
                                      size: 12,
                                      color: Colors.white),
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                )),
    );
  }

  void _preview(CachedMediaFile f) {
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          actions: [
            IconButton(
              icon: const Icon(Icons.delete_outline_rounded,
                  color: Colors.white),
              onPressed: () async {
                final s = AppState.I.str;
                await StorageService.I.deleteFile(f.file);
                if (!mounted) return;
                Navigator.of(context).pop();
                showGlassToast(context, s.mediaDeletedToast,
                    icon: Icons.delete_outline_rounded,
                    color: const Color(0xFFEF4444));
                _load();
              },
            ),
          ],
        ),
        body: Center(
          child: InteractiveViewer(
            maxScale: 6,
            child: Image.file(f.file, fit: BoxFit.contain),
          ),
        ),
      ),
    ));
  }
}
