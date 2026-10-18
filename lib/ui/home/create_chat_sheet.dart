import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../../core/models.dart';
import '../../core/socket_service.dart';
import '../chat/chat_screen.dart';
import '../widgets/common.dart';

/// The "+" button on the chats page: New private chat / New group /
/// New channel — with LIVE username availability checks.
class CreateChatSheet extends StatefulWidget {
  const CreateChatSheet({super.key});

  static Future<void> show(BuildContext context) =>
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => const CreateChatSheet(),
      );

  @override
  State<CreateChatSheet> createState() => _CreateChatSheetState();
}

class _CreateChatSheetState extends State<CreateChatSheet> {
  int _mode = 0; // 0 pv, 1 group, 2 channel
  final _name = TextEditingController();
  final _handle = TextEditingController();
  final _handleName = TextEditingController();
  bool _public = true;
  bool _busy = false;

  // live pv username check
  String _pvState = ''; // '' | 'ok' | 'empty' | 'invalid'
  Timer? _pvDebounce;

  // live room handle check
  String _handleState = '';
  Timer? _handleDebounce;

  @override
  void dispose() {
    _name.dispose();
    _handle.dispose();
    _handleName.dispose();
    _pvDebounce?.cancel();
    _handleDebounce?.cancel();
    super.dispose();
  }

  void _onPvChanged(String v) {
    _pvDebounce?.cancel();
    final u = v.trim();
    if (u.isEmpty) {
      setState(() => _pvState = '');
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(u)) {
      setState(() => _pvState = 'invalid');
      return;
    }
    setState(() => _pvState = 'checking');
    _pvDebounce = Timer(const Duration(milliseconds: 420), () async {
      final r = await ApiService.I.userExists(u);
      if (!mounted) return;
      setState(() => _pvState = (r.ok && r.data == true) ? 'ok' : 'empty');
    });
  }

  void _onHandleChanged(String v) {
    _handleDebounce?.cancel();
    final u = v.trim().replaceFirst(RegExp(r'^@'), '');
    if (u.isEmpty) {
      setState(() => _handleState = '');
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_]{3,20}$').hasMatch(u)) {
      setState(() => _handleState = 'invalid');
      return;
    }
    setState(() => _handleState = 'checking');
    _handleDebounce = Timer(const Duration(milliseconds: 420), () async {
      final r = await ApiService.I.roomUsernameCheck(u);
      if (!mounted) return;
      setState(() => _handleState = (r.ok && r.data == true) ? 'ok' : 'taken');
    });
  }

  Future<void> _startPv() async {
    final s = AppState.I.str;
    final u = _handleName.text.trim();
    if (u.isEmpty) return;
    setState(() => _busy = true);
    final r = await ApiService.I.startPv(u);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok && (r.data ?? 0) > 0) {
      final chatId = r.data!;
      SocketService.I.joinPv(chatId);
      Navigator.of(context).pop();
      await Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: ChatKind.pv,
        title: u,
        chatId: chatId,
        peerUsername: u,
      ));
    } else {
      showRaviToast(context,
          r.message != null && r.message!.contains('مسدود')
              ? s.dmClosedBanner
              : s.userNotFound,
          icon: Icons.error_outline_rounded);
    }
  }

  Future<void> _createRoom() async {
    final s = AppState.I.str;
    final name = _name.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    final isPublic = _public && _mode >= 1;
    final handle = isPublic ? _handle.text.trim() : '';
    final r = await ApiService.I.createRoomAdvanced(
      name: name,
      type: _mode == 2 ? 'channel' : 'group',
      isPublic: isPublic,
      username: handle,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (r.ok && r.data != null) {
      final roomId = '${r.data!['room_id'] ?? ''}';
      showRaviToast(context, s.created);
      Navigator.of(context).pop();
      AppState.I.loadChatsCachedThenNetwork();
      await Future.delayed(const Duration(milliseconds: 260));
      if (!mounted) return;
      await Navigator.of(context, rootNavigator: true).push(ChatScreen.route(
        kind: _mode == 2 ? ChatKind.channel : ChatKind.group,
        title: name,
        roomId: roomId,
        canPost: true,
      ));
    } else {
      final why = switch (r.message) {
        'invalid_username' => s.handleInvalid,
        'username_taken' => s.handleTaken,
        _ => s.createFailed,
      };
      showRaviToast(context, why, icon: Icons.error_outline_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: p.bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                        color: p.border, borderRadius: BorderRadius.circular(2))),
              ),
              const SizedBox(height: 16),
              // v1.0.7 — proper header like the web app
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: C.ownBubbleGrad,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  alignment: Alignment.center,
                  child: Icon(
                    _mode == 0
                        ? Icons.chat_bubble_outline_rounded
                        : _mode == 1
                            ? Icons.group_rounded
                            : Icons.campaign_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _mode == 0 ? s.newPv : (_mode == 1 ? s.createGroup : s.createChannel),
                        style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: p.text),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _mode == 0
                            ? s.startPvSub
                            : (isChannelMode
                                ? s.publicHandle
                                : s.publicToggle),
                        style: TextStyle(
                            fontSize: 11, color: p.text2),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ]),
              const SizedBox(height: 16),
              // mode selector
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: p.bgSoft,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(children: [
                  _modeCard(p, Icons.chat_bubble_outline_rounded, s.newPv, 0),
                  _modeCard(p, Icons.group_outlined, s.createGroup, 1),
                  _modeCard(p, Icons.campaign_outlined, s.createChannel, 2),
                ]),
              ),
              const SizedBox(height: 18),

              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _mode == 0
                    ? _pvBody(p, s)
                    : _roomBody(p, s),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool get isChannelMode => _mode == 2;

  Widget _modeCard(Palette p, IconData icon, String label, int mode) {
    final active = _mode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _mode = mode),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsetsDirectional.only(end: 4),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: active ? C.ownBubbleGrad : null,
            color: active ? null : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            boxShadow: active
                ? const [BoxShadow(color: Color(0x338B5CF6), blurRadius: 12, offset: Offset(0, 4))]
                : null,
          ),
          child: Column(children: [
            Icon(icon, size: 19, color: active ? Colors.white : p.text2),
            const SizedBox(height: 4),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: active ? FontWeight.w800 : FontWeight.w500,
                    color: active ? Colors.white : p.text2)),
          ]),
        ),
      ),
    );
  }

  Widget _pvBody(Palette p, S s) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(s.startPvSub, style: TextStyle(fontSize: 11.5, color: p.text2)),
        const SizedBox(height: 8),
        TextField(
          controller: _handleName,
          onChanged: _onPvChanged,
          textDirection: TextDirection.ltr,
          textAlign: TextAlign.start,
          textInputAction: TextInputAction.done,
          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.text),
          decoration: _deco(p, s).copyWith(
            prefixText: '@',
            prefixStyle: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: p.pfHandle),
          ),
        ),
        _stateLine(p, _pvState),
        const SizedBox(height: 14),
        _cta(p, s.newPv, _busy || _handleName.text.trim().isEmpty, _startPv),
      ],
    );
  }

  Widget _roomBody(Palette p, S s) {
    final isChannel = _mode == 2;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(isChannel ? s.channelName : s.groupName,
            style: TextStyle(fontSize: 11.5, color: p.text2)),
        const SizedBox(height: 8),
        TextField(
          controller: _name,
          maxLength: 60,
          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: p.text),
          decoration: _deco(p, s),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: Text(s.publicToggle,
                style: TextStyle(fontSize: 12.5, color: p.text)),
          ),
          GestureDetector(
            onTap: () => setState(() => _public = !_public),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: 40,
              height: 23,
              padding: const EdgeInsets.all(3),
              alignment: _public ? Alignment.centerLeft : Alignment.centerRight,
              decoration: BoxDecoration(
                color: _public ? p.accent : (p.brightness == Brightness.dark ? const Color(0xFF39424B) : const Color(0xFFDCE1E5)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Container(
                  width: 17,
                  height: 17,
                  decoration:
                      const BoxDecoration(color: Colors.white, shape: BoxShape.circle)),
            ),
          ),
        ]),
        if (_public) ...[
          const SizedBox(height: 10),
          Text(s.publicHandle,
              style: TextStyle(fontSize: 11.5, color: p.text2)),
          const SizedBox(height: 8),
          TextField(
            controller: _handle,
            onChanged: _onHandleChanged,
            textDirection: TextDirection.ltr,
            style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: p.text),
            decoration: _deco(p, s).copyWith(
              prefixText: '@',
              prefixStyle: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w800, color: p.pfHandle),
            ),
          ),
          _stateLine(p, _handleState),
        ],
        const SizedBox(height: 16),
        _cta(p, isChannel ? s.createChannel : s.createGroup,
            _busy || _name.text.trim().isEmpty, _createRoom),
      ],
    );
  }

  Widget _stateLine(Palette p, String state) {
    final s = AppState.I.str;
    if (state.isEmpty) return const SizedBox(height: 4);
    final (icon, text, color) = switch (state) {
      'checking' => (
          Icons.hourglass_top_rounded,
          s.checkingHandle,
          p.text3
        ),
      'ok' => (Icons.check_circle_rounded, s.handleAvailable, const Color(0xFF16A34A)),
      'taken' => (Icons.cancel_rounded, s.handleTaken, const Color(0xFFEF4444)),
      'invalid' => (Icons.info_outline_rounded, s.handleInvalid, const Color(0xFFF59E0B)),
      'empty' => (Icons.cancel_rounded, s.userNotFound, const Color(0xFFEF4444)),
      _ => (null, '', p.text3),
    };
    if (icon == null) return const SizedBox(height: 4);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 5),
        Text(text, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: color)),
      ]),
    );
  }

  Widget _cta(Palette p, String label, bool disabled, VoidCallback onTap) {
    return SizedBox(
      height: 48,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: p.accent,
          disabledBackgroundColor: p.accent.withValues(alpha: .35),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        ),
        onPressed: disabled ? null : onTap,
        child: _busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Text(label,
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800)),
      ),
    );
  }

  InputDecoration _deco(Palette p, S s) {
    return InputDecoration(
      filled: true,
      fillColor: p.bgSoft,
      isDense: true,
      counterText: '',
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.border.withValues(alpha: .5))),
      focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: p.accent.withValues(alpha: .65), width: 1.4)),
    );
  }
}
