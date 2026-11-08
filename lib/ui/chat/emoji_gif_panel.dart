import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/constants.dart';
import 'gif_picker_sheet.dart';

/// v1.0.8 — ONE panel for emoji + GIF (Telegram-style): a compact bottom
/// tab bar switches between the emoji keyboard and the GIF library grid.
///
/// v1.3.1 — LAG FIX + JUMP FIX:
///  • the panel's height now equals the REMEMBERED KEYBOARD HEIGHT, so
///    switching keyboard ⇄ panel keeps every pixel in place (WhatsUp logic);
///  • both tabs live in an IndexedStack → the emoji grid is built ONCE and
///    keeps its scroll position (tab switching is instant, no re-layout);
///  • the EmojiPicker's ScrollController is a real State field (it used to
///    be re-created on every build → state loss + jank).
class EmojiGifPanel extends StatefulWidget {
  final Palette palette;
  final TextEditingController? emojiController;
  final ValueChanged<String> onGifPicked;
  /// v1.3.1 — height == remembered keyboard height (clamped for sanity).
  final double height;

  const EmojiGifPanel({
    super.key,
    required this.palette,
    this.emojiController,
    required this.onGifPicked,
    this.height = 300,
  });

  @override
  State<EmojiGifPanel> createState() => _EmojiGifPanelState();
}

class _EmojiGifPanelState extends State<EmojiGifPanel> {
  int _tab = 0; // 0 = emoji, 1 = gif
  late final ScrollController _emojiScroll =
      ScrollController(keepScrollOffset: true);
  late final ScrollController _gifScroll =
      ScrollController(keepScrollOffset: true);

  @override
  void dispose() {
    _emojiScroll.dispose();
    _gifScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final s = AppState.I.str;
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: p.chatHeadBg,
        border: Border(top: BorderSide(color: p.chatHeadBorder)),
      ),
      child: Column(children: [
        // ---- tab bar ----
        SizedBox(
          height: 42,
          child: Row(children: [
            const SizedBox(width: 10),
            _tabBtn(
                icon: Icons.emoji_emotions_outlined,
                label: s.emojiTab,
                active: _tab == 0,
                onTap: () => setState(() => _tab = 0)),
            const SizedBox(width: 8),
            _tabBtn(
                icon: Icons.gif_rounded,
                label: s.gifTab,
                active: _tab == 1,
                onTap: () => setState(() => _tab = 1)),
          ]),
        ),
        Divider(height: 1, color: p.chatHeadBorder),
        // ---- body (IndexedStack: both tabs stay ALIVE → zero re-build lag,
        // scroll positions survive tab flips) ----
        Expanded(
          child: IndexedStack(
            index: _tab,
            children: [
              _emojiTab(p),
              GifPickerGrid(
                onPicked: widget.onGifPicked,
                compact: true,
                scrollController: _gifScroll,
              ),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _emojiTab(Palette p) {
    // EmojiPicker needs a bounded height — inside IndexedStack/Expanded the
    // viewport is the panel body; a plain ListView inside works, but the
    // package wants an explicit viewport fraction for the grid density.
    final cols = widget.height > 330 ? 9 : 8;
    return EmojiPicker(
      textEditingController: widget.emojiController,
      scrollController: _emojiScroll,
      config: Config(
        emojiViewConfig: EmojiViewConfig(
          columns: cols,
          emojiSizeMax: 28,
          backgroundColor: Colors.transparent,
        ),
        categoryViewConfig: CategoryViewConfig(
          indicatorColor: p.accent,
          iconColorSelected: p.accent,
          backgroundColor: Colors.transparent,
          iconColor: p.text3,
        ),
        skinToneConfig: const SkinToneConfig(),
        bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
        searchViewConfig: SearchViewConfig(
          backgroundColor: p.bgSoft,
          hintText: '',
        ),
        viewOrderConfig: const ViewOrderConfig(),
      ),
    );
  }

  Widget _tabBtn({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    final p = widget.palette;
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: active ? p.accentSoft : Colors.transparent,
          borderRadius: BorderRadius.circular(11),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 17, color: active ? p.accent : p.text3),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: active ? FontWeight.w800 : FontWeight.w600,
                  color: active ? p.accent : p.text3)),
        ]),
      ),
    );
  }
}
