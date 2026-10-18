import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/app_state.dart';
import '../../core/constants.dart';
import 'gif_picker_sheet.dart';

/// v1.0.8 — ONE panel for emoji + GIF (Telegram-style): a compact bottom
/// tab bar switches between the emoji keyboard and the GIF library grid.
/// Replaces both the old emoji-only panel and the standalone GIF sheet.
class EmojiGifPanel extends StatefulWidget {
  final Palette palette;
  final TextEditingController? emojiController;
  final ValueChanged<String> onGifPicked;

  const EmojiGifPanel({
    super.key,
    required this.palette,
    this.emojiController,
    required this.onGifPicked,
  });

  @override
  State<EmojiGifPanel> createState() => _EmojiGifPanelState();
}

class _EmojiGifPanelState extends State<EmojiGifPanel> {
  int _tab = 0; // 0 = emoji, 1 = gif

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final s = AppState.I.str;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      height: 300,
      decoration: BoxDecoration(
        color: p.chatHeadBg,
        border: Border(top: BorderSide(color: p.chatHeadBorder)),
      ),
      child: Column(children: [
        // ---- tab bar ----
        Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(children: [
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
        // ---- body ----
        Expanded(
          child: _tab == 0
              ? EmojiPicker(
                  textEditingController: widget.emojiController,
                  scrollController: ScrollController(),
                  config: Config(
                    emojiViewConfig: EmojiViewConfig(
                      columns: 8,
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
                    bottomActionBarConfig:
                        const BottomActionBarConfig(enabled: false),
                    searchViewConfig: SearchViewConfig(
                      backgroundColor: p.bgSoft,
                      hintText: '',
                    ),
                    viewOrderConfig: const ViewOrderConfig(),
                  ),
                )
              : GifPickerGrid(
                  onPicked: widget.onGifPicked,
                  compact: true,
                ),
        ),
      ]),
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
