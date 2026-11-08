import 'package:flutter/material.dart';

import '../../core/account_manager.dart';
import '../../core/api_service.dart';
import '../../core/app_state.dart';
import '../../core/constants.dart';
import '../../core/i18n.dart';
import '../auth/auth_screen.dart';
import '../widgets/common.dart';
import '../widgets/ravi_alerts.dart';

/// v1.4.0 — Telegram-style multi-account switcher.
///
/// Lists every account stored in [AccountManager] (avatar + name + @username,
/// green check on the active one). Tap switches (cookie swap + socket
/// reconnect via `AppState.I.switchAccount`), long-press on a NON-active row
/// removes it locally after a confirm dialog, and the bottom button opens
/// [AuthScreen] to add a new account (cap: 3 normal / 5 when any account Pro).
class AccountsSheet extends StatefulWidget {
  /// A context that stays alive after the sheet pops — used to push
  /// [AuthScreen] once the sheet is closed (see [_AccountsSheetState._addAccount]).
  final BuildContext anchor;

  const AccountsSheet({super.key, required this.anchor});

  /// Opens the switcher over the root navigator (safe from any page).
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => AccountsSheet(anchor: context),
    );
  }

  @override
  State<AccountsSheet> createState() => _AccountsSheetState();
}

class _AccountsSheetState extends State<AccountsSheet> {
  bool _switching = false; // a cookie-swap/socket-reconnect is in flight
  bool _checkingLimit = false; // fetching the current user's pro status
  bool _limitShown = false; // red "limit reached" box visible
  bool _limitPro = false; // which hint to show inside the red box

  bool get _fa => AppState.I.lang.value.isFa;

  /// Fresh index of [acc] (the list can mutate between build and tap).
  int _indexOf(RaviAccount acc) => AccountManager.I.accounts.indexWhere(
      (a) => a.username.toLowerCase() == acc.username.toLowerCase());

  // ---------- switch ----------

  Future<void> _switchTo(RaviAccount acc) async {
    if (_switching) return;
    final idx = _indexOf(acc);
    if (idx < 0) return;
    if (idx == AccountManager.I.activeIndex) {
      // Same account — just close (Telegram behaviour).
      Navigator.of(context).pop();
      return;
    }
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() {
      _switching = true;
      _limitShown = false;
    });
    final ok = await AppState.I.switchAccount(idx);
    if (!mounted) return;
    setState(() => _switching = false);
    if (ok) {
      navigator.pop();
      final displayName = acc.name.isNotEmpty ? acc.name : acc.username;
      messenger.showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        backgroundColor: p.text,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        content: Text(
          _fa ? 'به حساب $displayName وارد شدید' : 'Signed in as $displayName',
          style: TextStyle(
              fontSize: 12.5, fontWeight: FontWeight.w700, color: p.bg),
        ),
      ));
    } else {
      showGlassToast(context,
          _fa ? 'تعویض حساب ناموفق بود' : "Couldn't switch account",
          icon: Icons.error_outline_rounded, color: const Color(0xFFEF4444));
    }
  }

  // ---------- remove (long-press, non-active only) ----------

  Future<void> _removeAccount(RaviAccount acc) async {
    if (_switching) return;
    final s = AppState.I.str;
    final who = acc.name.isNotEmpty ? acc.name : acc.username;
    final confirmed = await showRaviModal(
      context,
      icon: Icons.person_remove_rounded,
      iconColor: const Color(0xFFEF4444),
      danger: true,
      title: _fa ? 'حذف این حساب؟' : 'Remove this account?',
      body: _fa
          ? '«$who» فقط از این دستگاه حذف می‌شود؛ از سرور خارج نمی‌شوید.'
          : '$who is removed from this device only — you stay signed in on the server.',
      okText: s.delete,
      cancelText: s.cancel,
    );
    if (!confirmed || !mounted) return;
    final idx = _indexOf(acc);
    if (idx < 0 || idx == AccountManager.I.activeIndex) return;
    await AccountManager.I.removeAt(idx); // local removal only
    if (!mounted) return;
    setState(() {}); // rebuild the sheet list
  }

  // ---------- add account ----------

  Future<void> _addAccount() async {
    if (_checkingLimit || _switching) return;
    final anchor = widget.anchor;
    final navigator = Navigator.of(context);
    setState(() {
      _checkingLimit = true;
      _limitShown = false;
    });
    // anyPro = the CURRENT user is Pro (raises the cap to 5). If the profile
    // fetch fails we stay conservative (normal cap = 3).
    final res = await ApiService.I.userProfile(AppState.I.me.value.username);
    final anyPro = res.ok && (res.data?['is_pro'] == true);
    if (!mounted) return;
    setState(() => _checkingLimit = false);
    if (AccountManager.I.canAddAccount(anyPro: anyPro)) {
      navigator.pop(); // close the sheet first…
      if (!anchor.mounted) return;
      Navigator.of(anchor, rootNavigator: true).push(
        MaterialPageRoute(builder: (_) => const AuthScreen()), // …then login
      );
      return;
    }
    setState(() {
      _limitShown = true;
      _limitPro = anyPro;
    });
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).brightness == Brightness.dark
        ? const Palette.dark()
        : const Palette.light();
    final s = AppState.I.str;
    final accounts = AccountManager.I.accounts;
    final activeIdx = AccountManager.I.activeIndex;

    return Container(
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                    color: p.border, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 11),
            Text(s.accounts,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16.5, fontWeight: FontWeight.w800, color: p.text)),
            const SizedBox(height: 3),
            Text(s.switchAccount,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: p.text2)),
            const SizedBox(height: 8),

            // subtle progress line while the account switch reconnects
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: _switching
                  ? LinearProgressIndicator(
                      key: const ValueKey<String>('switching'),
                      minHeight: 2,
                      backgroundColor: p.border,
                      color: p.accent,
                    )
                  : SizedBox(
                      key: const ValueKey<String>('idle'),
                      height: 2,
                      width: double.infinity,
                    ),
            ),

            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(14, 8, 14, 2),
                itemCount: accounts.length,
                itemBuilder: (context, i) => _AccountTile(
                  p: p,
                  account: accounts[i],
                  active: i == activeIdx,
                  busy: _switching,
                  onTap: () => _switchTo(accounts[i]),
                  onLongPress:
                      i == activeIdx ? null : () => _removeAccount(accounts[i]),
                ),
              ),
            ),

            if (_limitShown) _limitBox(p, s),

            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: _addButton(p, s),
            ),
          ],
        ),
      ),
    );
  }

  /// Red soft box — cap reached (3 normal / 5 Pro).
  Widget _limitBox(Palette p, S s) {
    const red = Color(0xFFEF4444);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 2, 14, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: red.withValues(alpha: .10),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: red.withValues(alpha: .25)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.error_outline_rounded, size: 16, color: red),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(s.accountLimitReached,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: red)),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Padding(
              padding: const EdgeInsetsDirectional.only(start: 23),
              child: Text(
                _limitPro ? s.accountLimitProHint : s.accountLimitNormalHint,
                style: TextStyle(fontSize: 10.5, color: p.text2),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Accent "Add account" button (spinner while the pro-status check runs).
  Widget _addButton(Palette p, S s) {
    return Material(
      color: p.accent,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _addAccount,
        child: Container(
          height: 48,
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_checkingLimit)
                const SizedBox(
                  width: 17,
                  height: 17,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white),
                )
              else
                const Icon(Icons.person_add_rounded,
                    size: 19, color: Colors.white),
              const SizedBox(width: 8),
              Text(s.addAccount,
                  style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w800,
                      color: Colors.white)),
            ],
          ),
        ),
      ),
    );
  }
}

/// One account row — p.bgSoft pill (radius 16), avatar 40, name + @username,
/// green check on the active account. Long-press (non-active) removes.
class _AccountTile extends StatelessWidget {
  final Palette p;
  final RaviAccount account;
  final bool active;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _AccountTile({
    required this.p,
    required this.account,
    required this.active,
    required this.busy,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final displayName =
        account.name.isNotEmpty ? account.name : account.username;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: p.bgSoft,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: busy ? null : onTap,
          onLongPress: (onLongPress == null || busy) ? null : onLongPress,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: active ? p.accent.withValues(alpha: .35) : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                RaviAvatar(
                    name: displayName, avatarPath: account.avatar, size: 40),
                const SizedBox(width: 11),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(displayName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: p.text)),
                      const SizedBox(height: 2),
                      Text('@${account.username}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 10.5, color: p.text2)),
                    ],
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.check_circle_rounded,
                      size: 19, color: Color(0xFF22C55E)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
