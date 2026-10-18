import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../core/constants.dart';

/// v1.0.6 — professional, glassy alerts used across the app.
///  • showGlassToast  — floating pill with blur + icon, slides from top
///  • showRaviModal   — RaviModal.confirm-style dialog (icon/title/body/ok)
///  • showGlassSheet  — bottom action sheet with blur backdrop

void showGlassToast(
  BuildContext context,
  String msg, {
  IconData icon = Icons.check_circle_rounded,
  Color? color,
  bool top = true,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  late final OverlayEntry entry;
  final controller = _ToastController();
  entry = OverlayEntry(
    builder: (_) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      final c = color ?? const Color(0xFF8B5CF6);
      return AnimatedBuilder(
        animation: controller,
        builder: (context, child) {
          final t = controller.t;
          return Positioned(
            top: top ? MediaQuery.of(context).padding.top + 14 : null,
            bottom: top ? null : MediaQuery.of(context).padding.bottom + 90,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(0, top ? -26 * (1 - t) : 26 * (1 - t)),
                  child: Center(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(30),
                      child: BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          decoration: BoxDecoration(
                            color: dark
                                ? const Color(0xE6151B22)
                                : const Color(0xF0FFFFFF),
                            borderRadius: BorderRadius.circular(30),
                            border: Border.all(
                              color: dark
                                  ? Colors.white.withValues(alpha: .09)
                                  : Colors.black.withValues(alpha: .06),
                            ),
                            boxShadow: const [
                              BoxShadow(
                                  color: Color(0x40000000),
                                  blurRadius: 24,
                                  offset: Offset(0, 8)),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(icon, size: 17, color: c),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  msg,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: dark ? Colors.white : C.textL,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
  controller.forward();
  overlay.insert(entry);
  Timer(const Duration(milliseconds: 2100), () async {
    await controller.reverse();
    controller.disposeNow();
    try {
      entry.remove();
    } catch (_) {}
  });
}

class _ToastController extends ChangeNotifier {
  late final AnimationController c = AnimationController(
      vsync: _TickerProvider(), duration: const Duration(milliseconds: 260))
    ..addListener(notifyListeners);

  double get t {
    final a = CurvedAnimation(parent: c,
        curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return a.value;
  }

  void forward() => c.forward();
  Future<void> reverse() => c.reverse();
  void disposeNow() => c.dispose();
}

class _TickerProvider extends TickerProvider {
  @override
  Ticker createTicker(TickerCallback onTick) => Ticker(onTick);
}

/// Telegram-style confirm dialog with icon, title, body — glass card.
Future<bool> showRaviModal(
  BuildContext context, {
  IconData icon = Icons.help_outline_rounded,
  Color iconColor = const Color(0xFF8B5CF6),
  required String title,
  String? body,
  required String okText,
  String? cancelText,
  bool danger = false,
}) async {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final res = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'modal',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, __) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return Center(
        child: ScaleTransition(
          scale: Tween(begin: 0.86, end: 1.0).animate(curved),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  width: MediaQuery.of(ctx).size.width * 0.82,
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xF0171D24)
                        : const Color(0xF7FFFFFF),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: .08)
                          : Colors.black.withValues(alpha: .05),
                    ),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x4D000000),
                          blurRadius: 40,
                          offset: Offset(0, 18)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        decoration: BoxDecoration(
                          color: iconColor.withValues(alpha: .14),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: iconColor, size: 26),
                      ),
                      const SizedBox(height: 14),
                      Text(title,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: dark ? Colors.white : C.textL)),
                      if (body != null && body.isNotEmpty) ...[
                        const SizedBox(height: 7),
                        Text(body,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                fontSize: 12.5,
                                height: 1.6,
                                color: dark ? C.text2D : C.text2L)),
                      ],
                      const SizedBox(height: 18),
                      Row(children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => Navigator.pop(ctx, false),
                            child: Container(
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: dark
                                    ? Colors.white.withValues(alpha: .07)
                                    : Colors.black.withValues(alpha: .05),
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: Text(cancelText ?? 'لغو',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color:
                                          dark ? C.text2D : C.text2L)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => Navigator.pop(ctx, true),
                            child: Container(
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: danger
                                    ? const LinearGradient(colors: [
                                        Color(0xFFF87171),
                                        Color(0xFFDC2626)
                                      ])
                                    : C.ownBubbleGrad,
                                borderRadius: BorderRadius.circular(13),
                                boxShadow: [
                                  BoxShadow(
                                      color: (danger
                                              ? const Color(0xFFDC2626)
                                              : const Color(0xFF8B5CF6))
                                          .withValues(alpha: .35),
                                      blurRadius: 14,
                                      offset: const Offset(0, 5)),
                                ],
                              ),
                              child: Text(okText,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white)),
                            ),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
  return res == true;
}

/// v1.0.7 — glass single-field prompt (message editing).
Future<bool?> showRaviPrompt(
  BuildContext context, {
  required String title,
  required String hint,
  required TextEditingController controller,
  required String okText,
  String? cancelText,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final focus = FocusNode();
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'prompt',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, __) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutBack);
      return Center(
        child: ScaleTransition(
          scale: Tween(begin: 0.86, end: 1.0).animate(curved),
          child: FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: Container(
                  width: MediaQuery.of(ctx).size.width * 0.86,
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                  decoration: BoxDecoration(
                    color: dark
                        ? const Color(0xF0171D24)
                        : const Color(0xF7FFFFFF),
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(
                      color: dark
                          ? Colors.white.withValues(alpha: .08)
                          : Colors.black.withValues(alpha: .05),
                    ),
                    boxShadow: const [
                      BoxShadow(
                          color: Color(0x4D000000),
                          blurRadius: 40,
                          offset: Offset(0, 18)),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w800,
                              color: dark ? Colors.white : C.textL)),
                      const SizedBox(height: 12),
                      TextField(
                        controller: controller,
                        focusNode: focus,
                        maxLines: 3,
                        minLines: 1,
                        autofocus: true,
                        style: TextStyle(
                            fontSize: 13.5,
                            height: 1.5,
                            color: dark ? Colors.white : C.textL),
                        decoration: InputDecoration(
                          hintText: hint,
                          hintStyle: TextStyle(
                              fontSize: 12.5,
                              color: dark ? C.text2D : C.text2L),
                          filled: true,
                          fillColor: dark
                              ? Colors.white.withValues(alpha: .06)
                              : Colors.black.withValues(alpha: .04),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 13, vertical: 11),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide(
                                color: const Color(0xFF8B5CF6)
                                    .withValues(alpha: .6),
                                width: 1.3),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(children: [
                        Expanded(
                          child: GestureDetector(
                            onTap: () => Navigator.pop(ctx, false),
                            child: Container(
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: dark
                                    ? Colors.white.withValues(alpha: .07)
                                    : Colors.black.withValues(alpha: .05),
                                borderRadius: BorderRadius.circular(13),
                              ),
                              child: Text(cancelText ?? 'لغو',
                                  style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w700,
                                      color: dark ? C.text2D : C.text2L)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: GestureDetector(
                            onTap: () => Navigator.pop(ctx, true),
                            child: Container(
                              height: 42,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                gradient: C.ownBubbleGrad,
                                borderRadius: BorderRadius.circular(13),
                                boxShadow: const [
                                  BoxShadow(
                                      color: Color(0x598B5CF6),
                                      blurRadius: 14,
                                      offset: Offset(0, 5)),
                                ],
                              ),
                              child: Text(okText,
                                  style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white)),
                            ),
                          ),
                        ),
                      ]),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  ).whenComplete(() => focus.dispose());
}

/// Bottom action sheet — glass card sliding up (like index modals).
Future<T?> showGlassSheet<T>(
  BuildContext context, {
  required Widget Function(BuildContext ctx) builder,
  double heightFactor = 0.6,
  bool dismissible = true,
}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black45,
    isDismissible: dismissible,
    builder: (ctx) => ClipRRect(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 26, sigmaY: 26),
        child: Container(
          height: MediaQuery.of(ctx).size.height * heightFactor,
          decoration: BoxDecoration(
            color: dark ? const Color(0xF3161C23) : const Color(0xFAFFFFFF),
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(26)),
            border: Border(
              top: BorderSide(
                color: dark
                    ? Colors.white.withValues(alpha: .09)
                    : Colors.black.withValues(alpha: .05),
              ),
            ),
          ),
          child: builder(ctx),
        ),
      ),
    ),
  );
}
