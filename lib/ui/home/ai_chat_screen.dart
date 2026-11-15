import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../widgets/ravi_alerts.dart';

/// Real backend-backed RAVI AI Assistant chat screen (`/api/ai_chat` & `/api/ai_pro_chat`).
class AiChatScreen extends StatefulWidget {
  final bool initialPro;
  const AiChatScreen({super.key, this.initialPro = false});

  static Route<void> route({bool pro = false}) => MaterialPageRoute(
        builder: (_) => AiChatScreen(initialPro: pro),
      );

  @override
  State<AiChatScreen> createState() => _AiChatScreenState();
}

class _AiBubble {
  final String text;
  final bool isMe;
  final bool isError;
  final String time;

  const _AiBubble({
    required this.text,
    required this.isMe,
    this.isError = false,
    required this.time,
  });
}

class _AiChatScreenState extends State<AiChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final List<_AiBubble> _messages = [];
  late bool _proMode = widget.initialPro;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    final fa = AppState.I.lang.value.isFa;
    _messages.add(_AiBubble(
      text: fa
          ? 'سلام! من هوش مصنوعی راوی هستم. می‌توانم در ریاضی، برنامه‌نویسی، ترجمه و سؤالات روزمره کمکت کنم.'
          : 'Hi! I am RAVI AI. Ask me anything about math, coding, writing, or everyday questions.',
      isMe: false,
      time: _nowClock(),
    ));
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  static String _nowClock() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent + 120,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  Future<void> _send([String? preset]) async {
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _sending) return;
    if (preset == null) _input.clear();
    setState(() {
      _sending = true;
      _messages.add(_AiBubble(text: text, isMe: true, time: _nowClock()));
    });
    _scrollToBottom();

    final res = await ApiService.I.aiChat(text, pro: _proMode);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (res.ok && (res.data ?? '').isNotEmpty) {
        _messages.add(_AiBubble(text: res.data!, isMe: false, time: _nowClock()));
      } else {
        final fa = AppState.I.lang.value.isFa;
        final errText = (res.message != null && res.message != 'fail')
            ? res.message!
            : (fa ? 'پاسخی از سرور دریافت نشد. دوباره تلاش کنید.' : 'Could not reach RAVI AI. Please try again.');
        _messages.add(_AiBubble(
          text: errText,
          isMe: false,
          isError: true,
          time: _nowClock(),
        ));
      }
    });
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final fa = AppState.I.lang.value.isFa;

    final suggestions = fa
        ? const ['۱۴۵ × ۲۸ چند میشه؟', 'یک شعر کوتاه بگو', 'تفاوت Flutter و React Native چیه؟']
        : const ['What is 145 * 28?', 'Give me a productivity tip', 'Explain WebSockets simply'];

    return Scaffold(
      backgroundColor: p.bg,
      appBar: AppBar(
        backgroundColor: p.bg,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: p.text),
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Color(0xFF8B5CF6), Color(0xFF38BDF8)],
                ),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.aiAssistantTitle,
                    style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w800, color: p.text),
                  ),
                  Text(
                    _sending ? (fa ? 'در حال پاسخ‌گویی…' : 'Thinking…') : s.aiAssistantSub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: _sending ? p.accent : p.text3),
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: () {
                HapticFeedback.selectionClick();
                setState(() => _proMode = !_proMode);
              },
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                margin: const EdgeInsetsDirectional.only(end: 12),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  gradient: _proMode
                      ? const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF38BDF8)])
                      : null,
                  color: _proMode ? null : p.bgSoft,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: _proMode ? Colors.transparent : p.border),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.bolt_rounded,
                      size: 14,
                      color: _proMode ? Colors.white : p.text2,
                    ),
                    const SizedBox(width: 3),
                    Text(
                      s.aiProBadge,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: _proMode ? Colors.white : p.text2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scroll,
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
              itemCount: _messages.length + (_sending ? 1 : 0),
              itemBuilder: (context, i) {
                if (i == _messages.length) {
                  return Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: p.bgCard,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(color: p.border),
                      ),
                      child: const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  );
                }
                final m = _messages[i];
                return Align(
                  alignment: m.isMe
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: GestureDetector(
                    onLongPress: () {
                      Clipboard.setData(ClipboardData(text: m.text));
                      showGlassToast(context, s.copiedToClipboard, icon: Icons.copy_rounded);
                    },
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: MediaQuery.of(context).size.width * 0.80,
                      ),
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.fromLTRB(13, 10, 13, 8),
                      decoration: BoxDecoration(
                        gradient: m.isMe ? C.ownBubbleGrad : null,
                        color: m.isMe
                            ? null
                            : (m.isError
                                ? const Color(0xFFEF4444).withValues(alpha: .10)
                                : p.bgCard),
                        borderRadius: BorderRadius.circular(18),
                        border: m.isMe
                            ? null
                            : Border.all(
                                color: m.isError
                                    ? const Color(0xFFEF4444).withValues(alpha: .35)
                                    : p.border,
                              ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          SelectableText(
                            m.text,
                            style: TextStyle(
                              fontSize: 14,
                              height: 1.55,
                              color: m.isMe
                                  ? Colors.white
                                  : (m.isError ? const Color(0xFFEF4444) : p.text),
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            m.time,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: m.isMe ? Colors.white70 : p.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (_messages.length <= 1)
            SizedBox(
              height: 40,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 14),
                itemCount: suggestions.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) => ActionChip(
                  backgroundColor: p.bgSoft,
                  side: BorderSide(color: p.border),
                  label: Text(
                    suggestions[i],
                    style: TextStyle(fontSize: 12, color: p.text),
                  ),
                  onPressed: () => _send(suggestions[i]),
                ),
              ),
            ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              decoration: BoxDecoration(
                color: p.bg,
                border: Border(top: BorderSide(color: p.border)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      decoration: BoxDecoration(
                        color: p.bgSoft,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(color: p.borderSoft),
                      ),
                      child: TextField(
                        controller: _input,
                        maxLines: 4,
                        minLines: 1,
                        textInputAction: TextInputAction.send,
                        onSubmitted: (_) => _send(),
                        style: TextStyle(fontSize: 14.5, color: p.text),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: s.aiAskHint,
                          hintStyle: TextStyle(fontSize: 13.5, color: p.text3),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _sending ? null : _send,
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: C.ownBubbleGrad,
                      ),
                      child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
