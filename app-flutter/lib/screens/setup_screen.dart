import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../src/rust/bridge.dart';
import '../state/datieve_state.dart';
import '../theme/css_tokens.dart';
import '../theme/datieve_theme.dart';
import '../utils/setup_helpers.dart';
import '../widgets/ui/auth_shell.dart';
import '../widgets/ui/button.dart';
import '../widgets/ui/input.dart';
import '../widgets/datieve_widgets.dart';

const _totalSteps = 7;

/// Exact port of `SetupWizard` from App.tsx (lines 676–1097).
class SetupScreen extends StatelessWidget {
  final DatieveState state;
  final bool embedded;

  const SetupScreen({super.key, required this.state, this.embedded = false});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final wide = MediaQuery.sizeOf(context).width >= 1024;

    final card = Container(
      margin: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: tw.white,
        borderRadius: BorderRadius.circular(Tw.radiusXl),
        border: Border.all(color: tw.slate200),
        boxShadow: [
          BoxShadow(
            color: c.ink.withValues(alpha: 0.04),
            blurRadius: 4,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: wide
          ? IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: 280, child: _Aside(state: state)),
                  Expanded(child: _Main(state: state)),
                ],
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Aside(state: state),
                _Main(state: state),
              ],
            ),
    );

    final body = SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1024),
          child: card,
        ),
      ),
    );

    if (embedded) {
      return ColoredBox(color: tw.slate50, child: body);
    }
    return AuthPageScaffold(
      colors: c,
      themeToggle: ThemeToggle(
        dark: state.isDark,
        colors: c,
        onToggle: () => state.setTheme(state.isDark ? 'light' : 'dark'),
      ),
      child: body,
    );
  }
}

class _Aside extends StatelessWidget {
  final DatieveState state;

  const _Aside({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final s = state.setup;

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: tw.slate50,
        border: Border(
          bottom: BorderSide(color: tw.slate200),
          right: MediaQuery.sizeOf(context).width >= 1024
              ? BorderSide(color: tw.slate200)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextButton(
            onPressed: state.setupBack,
            style: TextButton.styleFrom(
              padding: EdgeInsets.zero,
              foregroundColor: tw.slate500,
              alignment: Alignment.centerLeft,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Transform.rotate(
                  angle: 3.14159,
                  child: const Icon(LucideIcons.chevronRight, size: 14),
                ),
                const SizedBox(width: 8),
                const Text(
                  'All Agents',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: tw.slate900,
              borderRadius: BorderRadius.circular(Tw.radiusLg),
            ),
            child: Icon(LucideIcons.settings, color: tw.onBrand, size: 21),
          ),
          const SizedBox(height: 20),
          Text(
            'INITIAL SETUP',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 2.4,
              color: tw.slate400,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.stepTitle,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.5,
              color: tw.ink,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            s.stepDesc,
            style: TextStyle(fontSize: 13, height: 1.6, color: tw.slate500),
          ),
          const SizedBox(height: 32),
          Row(
            children: List.generate(_totalSteps, (i) {
              final n = i + 1;
              return Expanded(
                child: Container(
                  height: 6,
                  margin: EdgeInsets.only(right: i < _totalSteps - 1 ? 6 : 0),
                  decoration: BoxDecoration(
                    color: n <= s.step ? tw.slate900 : tw.slate200,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 16),
          Text(
            'Step ${s.step} of $_totalSteps',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: tw.slate400,
            ),
          ),
        ],
      ),
    );
  }
}

class _Main extends StatelessWidget {
  final DatieveState state;

  const _Main({required this.state});

  @override
  Widget build(BuildContext context) {
    final c = state.colors;
    final tw = Tw(c);
    final s = state.setup;

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: MediaQuery.sizeOf(context).width >= 1024 ? 40 : 32,
        vertical: MediaQuery.sizeOf(context).width >= 1024 ? 40 : 32,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: colorMix(tw.slate50, tw.white, 0.7),
              borderRadius: BorderRadius.circular(Tw.radiusXl),
              border: Border.all(color: tw.slate200),
            ),
            child: _StepBody(state: state),
          ),
          if (state.setupError.isNotEmpty) ...[
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: tw.red50,
                borderRadius: BorderRadius.circular(Tw.radius2xl),
                border: Border.all(color: tw.red100),
              ),
              child: Text(
                state.setupError,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: tw.red700,
                ),
              ),
            ),
          ],
          const SizedBox(height: 64),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              DatieveUiButton(
                label: 'Back',
                variant: DatieveButtonVariant.ghost,
                colors: c,
                onPressed: state.setupBack,
              ),
              DatieveUiButton(
                label: state.setupLoading
                    ? 'Please wait...'
                    : s.step == _totalSteps
                        ? 'Confirm & Deploy'
                        : 'Continue',
                colors: c,
                disabled: state.setupLoading,
                onPressed: state.setupLoading
                    ? null
                    : () {
                        if (s.step == _totalSteps) {
                          state.setupFinish();
                        } else {
                          state.setupNext();
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StepBody extends StatefulWidget {
  final DatieveState state;

  const _StepBody({required this.state});

  @override
  State<_StepBody> createState() => _StepBodyState();
}

class _StepBodyState extends State<_StepBody> {
  String _confirmAdmin = '';
  String _confirmManage = '';
  final List<String> _confirmUserCodes = [];

  void _ensureConfirmUsers(int len) {
    while (_confirmUserCodes.length < len) _confirmUserCodes.add('');
  }

  List<String> _validWatchedPaths(SetupStateDto s) =>
      s.watchedPaths.map((p) => p.trim()).where((p) => p.isNotEmpty).toList();

  @override
  Widget build(BuildContext context) {
    final c = widget.state.colors;
    final tw = Tw(c);
    final s = widget.state.setup;

    switch (s.step) {
      case 1:
        return DatieveUiInput(
          label: 'Agent Name',
          placeholder: 'e.g. Home Server',
          value: s.friendlyName,
          colors: c,
          onChanged: (v) => widget.state.patchSetup(s.copyWith(friendlyName: v)),
        );
      case 2:
        final mismatch = _confirmAdmin.isNotEmpty && _confirmAdmin != s.adminCode;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DatieveUiInput(
              label: 'Admin Username',
              placeholder: 'e.g. admin',
              value: s.adminUsername,
              colors: c,
              onChanged: (v) => widget.state.patchSetup(s.copyWith(adminUsername: v)),
            ),
            const SizedBox(height: 16),
            DatieveUiInput(
              label: 'Admin Password',
              placeholder: 'Strong password',
              value: s.adminCode,
              obscure: true,
              showToggle: true,
              colors: c,
              onChanged: (v) => widget.state.patchSetup(s.copyWith(adminCode: v)),
            ),
            const SizedBox(height: 12),
            DatieveUiInput(
              label: 'Confirm Password',
              placeholder: 'Repeat password',
              obscure: true,
              showToggle: true,
              colors: c,
              onChanged: (v) => setState(() => _confirmAdmin = v),
            ),
            if (mismatch) ...[
              const SizedBox(height: 8),
              Text(
                'Passwords do not match.',
                style: TextStyle(fontSize: 11, color: tw.red500),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'The admin account has full access to all indexed files and settings.',
              style: TextStyle(fontSize: 12, color: tw.slate400),
            ),
          ],
        );
      case 3:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < s.watchedPaths.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _PathField(
                        value: s.watchedPaths[i],
                        placeholder: '/mnt/nas/archive',
                        colors: c,
                        onChanged: (v) {
                          final paths = List<String>.from(s.watchedPaths);
                          paths[i] = v;
                          widget.state.patchSetup(s.copyWith(watchedPaths: paths));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _IconFieldButton(
                      icon: LucideIcons.folder,
                      colors: c,
                      onPressed: () {},
                    ),
                    if (s.watchedPaths.length > 1) ...[
                      const SizedBox(width: 8),
                      _IconFieldButton(
                        icon: LucideIcons.x,
                        colors: c,
                        danger: true,
                        onPressed: () {
                          final paths = List<String>.from(s.watchedPaths)..removeAt(i);
                          widget.state.patchSetup(s.copyWith(watchedPaths: paths));
                        },
                      ),
                    ],
                  ],
                ),
              ),
            TextButton(
              onPressed: () =>
                  widget.state.patchSetup(s.copyWith(watchedPaths: [...s.watchedPaths, ''])),
              style: TextButton.styleFrom(alignment: Alignment.centerLeft),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.plusCircle, size: 16, color: tw.slate400),
                  const SizedBox(width: 12),
                  Text(
                    'ADD PATH',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      color: tw.slate400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      case 4:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(32),
              decoration: BoxDecoration(
                color: tw.white,
                borderRadius: BorderRadius.circular(Tw.radius2xl),
                border: Border.all(color: tw.line),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Exclude hidden files and folders',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tw.ink,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'IGNORE NAMES STARTING WITH A DOT',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            color: tw.slate400,
                          ),
                        ),
                      ],
                    ),
                  ),
                  _Toggle(
                    value: s.excludeHidden,
                    colors: c,
                    onChanged: (v) => widget.state.patchSetup(s.copyWith(excludeHidden: v)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 40),
            Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 12),
              child: Text(
                'WILDCARD PATTERNS',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 2,
                  color: tw.slate400,
                ),
              ),
            ),
            for (var i = 0; i < s.exclusionPatterns.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: _PathField(
                        value: s.exclusionPatterns[i],
                        placeholder: 'e.g. *temp*',
                        colors: c,
                        onChanged: (v) {
                          final patterns = List<String>.from(s.exclusionPatterns);
                          patterns[i] = v;
                          widget.state.patchSetup(s.copyWith(exclusionPatterns: patterns));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    _IconFieldButton(
                      icon: LucideIcons.x,
                      colors: c,
                      danger: true,
                      onPressed: () {
                        final patterns = List<String>.from(s.exclusionPatterns)..removeAt(i);
                        widget.state.patchSetup(s.copyWith(exclusionPatterns: patterns));
                      },
                    ),
                  ],
                ),
              ),
            TextButton(
              onPressed: () => widget.state.patchSetup(
                s.copyWith(exclusionPatterns: [...s.exclusionPatterns, '']),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(LucideIcons.plusCircle, size: 14, color: tw.slate400),
                  const SizedBox(width: 8),
                  Text(
                    'ADD PATTERN',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      color: tw.slate400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      case 5:
        final roots = _validWatchedPaths(s);
        _ensureConfirmUsers(s.users.length);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < s.users.length; i++) ...[
              Container(
                padding: const EdgeInsets.all(24),
                margin: const EdgeInsets.only(bottom: 32),
                decoration: BoxDecoration(
                  color: tw.white,
                  borderRadius: BorderRadius.circular(Tw.radiusXl),
                  border: Border.all(color: tw.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: DatieveUiInput(
                            label: 'Username',
                            placeholder: 'Alex',
                            value: s.users[i].username,
                            colors: c,
                            onChanged: (v) {
                              final users = List<SetupUserDto>.from(s.users);
                              users[i] = users[i].copyWith(username: v);
                              widget.state.patchSetup(s.copyWith(users: users));
                            },
                          ),
                        ),
                        const SizedBox(width: 24),
                        Expanded(
                          child: DatieveUiInput(
                            label: 'User Code',
                            placeholder: '••••••••',
                            value: s.users[i].code,
                            obscure: true,
                            showToggle: true,
                            colors: c,
                            onChanged: (v) {
                              final users = List<SetupUserDto>.from(s.users);
                              users[i] = users[i].copyWith(code: v);
                              widget.state.patchSetup(s.copyWith(users: users));
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    DatieveUiInput(
                      label: 'Confirm Code',
                      placeholder: 'Repeat code',
                      obscure: true,
                      showToggle: true,
                      colors: c,
                      onChanged: (v) => setState(() {
                        _ensureConfirmUsers(i + 1);
                        _confirmUserCodes[i] = v;
                      }),
                    ),
                    if (_confirmUserCodes[i].isNotEmpty &&
                        _confirmUserCodes[i] != s.users[i].code) ...[
                      const SizedBox(height: 6),
                      Text(
                        'Codes do not match.',
                        style: TextStyle(fontSize: 11, color: tw.red500),
                      ),
                    ],
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 8),
                      child: Text(
                        'ALLOWED PATHS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                          color: tw.slate400,
                        ),
                      ),
                    ),
                    Text(
                      'Enter watched root paths or sub-paths within them (e.g. /barrel/A).',
                      style: TextStyle(fontSize: 10, color: tw.slate400),
                    ),
                    const SizedBox(height: 12),
                    for (var j = 0; j < s.users[i].allowedPaths.length; j++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: _PathField(
                                value: s.users[i].allowedPaths[j],
                                placeholder: roots.isNotEmpty ? roots.first : '/mnt/nas/data',
                                colors: c,
                                soft: true,
                                onChanged: (v) {
                                  final users = List<SetupUserDto>.from(s.users);
                                  final paths = List<String>.from(users[i].allowedPaths);
                                  paths[j] = v;
                                  users[i] = users[i].copyWith(allowedPaths: paths);
                                  widget.state.patchSetup(s.copyWith(users: users));
                                },
                              ),
                            ),
                            if (s.users[i].allowedPaths.length > 1) ...[
                              const SizedBox(width: 8),
                              _IconFieldButton(
                                icon: LucideIcons.x,
                                colors: c,
                                danger: true,
                                onPressed: () {
                                  final users = List<SetupUserDto>.from(s.users);
                                  final paths = List<String>.from(users[i].allowedPaths)..removeAt(j);
                                  users[i] = users[i].copyWith(allowedPaths: paths);
                                  widget.state.patchSetup(s.copyWith(users: users));
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final wp in roots)
                          _ChipButton(
                            label: '+ $wp',
                            colors: c,
                            onPressed: () {
                              final users = List<SetupUserDto>.from(s.users);
                              final paths = [...users[i].allowedPaths, wp];
                              users[i] = users[i].copyWith(allowedPaths: paths);
                              widget.state.patchSetup(s.copyWith(users: users));
                            },
                          ),
                        _ChipButton(
                          label: '+ Custom path',
                          colors: c,
                          dashed: true,
                          onPressed: () {
                            final users = List<SetupUserDto>.from(s.users);
                            final paths = [...users[i].allowedPaths, ''];
                            users[i] = users[i].copyWith(allowedPaths: paths);
                            widget.state.patchSetup(s.copyWith(users: users));
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () {
                        final users = List<SetupUserDto>.from(s.users)..removeAt(i);
                        widget.state.patchSetup(s.copyWith(users: users));
                      },
                      child: Text(
                        'REMOVE USER',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2,
                          color: tw.slate300,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            OutlinedButton(
              onPressed: () => widget.state.patchSetup(s.copyWith(
                users: [
                  ...s.users,
                  const SetupUserDto(username: '', code: '', allowedPaths: ['']),
                ],
              )),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 20),
                side: BorderSide(color: tw.slate200, style: BorderStyle.solid),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(Tw.radius2xl),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.plus, size: 16, color: tw.slate400),
                  const SizedBox(width: 12),
                  Text(
                    'ADD USER',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                      color: tw.slate400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      case 6:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: tw.slate50,
                borderRadius: BorderRadius.circular(Tw.radius2xl),
                border: Border.all(color: tw.line),
              ),
              child: Text(
                'This password is required to save any configuration changes. Everyone logged in can view settings, but only the person who knows this password can apply them.',
                style: TextStyle(fontSize: 12, height: 1.6, color: tw.slate500),
              ),
            ),
            const SizedBox(height: 32),
            DatieveUiInput(
              label: 'Management Password',
              placeholder: 'Strong password',
              value: s.managePassword,
              obscure: true,
              showToggle: true,
              colors: c,
              onChanged: (v) => widget.state.patchSetup(s.copyWith(managePassword: v)),
            ),
            const SizedBox(height: 12),
            DatieveUiInput(
              label: 'Confirm Password',
              placeholder: 'Repeat password',
              obscure: true,
              showToggle: true,
              colors: c,
              onChanged: (v) => setState(() => _confirmManage = v),
            ),
            if (_confirmManage.isNotEmpty && _confirmManage != s.managePassword) ...[
              const SizedBox(height: 8),
              Text(
                'Passwords do not match.',
                style: TextStyle(fontSize: 11, color: tw.red500),
              ),
            ],
          ],
        );
      case 7:
        final roots = _validWatchedPaths(s);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'AGENT',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                          color: tw.slate300,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        s.friendlyName,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: tw.ink,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.state.agent?.ip ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: tw.slate400,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'INDEXED PATHS',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2,
                          color: tw.slate300,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (final p in roots)
                        Text(
                          p,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: tw.slate600,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Divider(color: tw.line),
            const SizedBox(height: 12),
            Text(
              'EXCLUSIONS',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w900,
                letterSpacing: 2,
                color: tw.slate300,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (s.excludeHidden)
                  _SummaryChip(label: 'Hidden files (.*)', colors: c),
                for (final p in s.exclusionPatterns.where((x) => x.trim().isNotEmpty))
                  _SummaryChip(label: p, colors: c),
                if (!s.excludeHidden &&
                    s.exclusionPatterns.where((x) => x.trim().isNotEmpty).isEmpty)
                  Text('None', style: TextStyle(fontSize: 10, color: tw.slate400)),
              ],
            ),
            const SizedBox(height: 24),
            Divider(color: tw.line),
            const SizedBox(height: 12),
            Text('ADMIN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: tw.slate300)),
            const SizedBox(height: 8),
            Text(s.adminUsername, style: TextStyle(fontWeight: FontWeight.w700, color: tw.ink)),
            Text(
              'Full file access to all indexed folders',
              style: TextStyle(fontSize: 10, color: tw.slate400),
            ),
            const SizedBox(height: 24),
            Divider(color: tw.line),
            const SizedBox(height: 12),
            Text('CONFIG MANAGEMENT', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: tw.slate300)),
            const SizedBox(height: 8),
            Text('Password protected', style: TextStyle(fontWeight: FontWeight.w700, color: tw.ink)),
            Text('Required to save settings changes', style: TextStyle(fontSize: 10, color: tw.slate400)),
            const SizedBox(height: 24),
            Divider(color: tw.line),
            const SizedBox(height: 12),
            Text(
              'USERS (${s.users.length})',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 2, color: tw.slate300),
            ),
            const SizedBox(height: 16),
            for (final u in s.users)
              Container(
                width: double.infinity,
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: tw.white,
                  borderRadius: BorderRadius.circular(Tw.radiusXl),
                  border: Border.all(color: tw.line),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(u.username, style: TextStyle(fontWeight: FontWeight.w700, color: tw.ink)),
                    const SizedBox(height: 4),
                    for (final p in u.allowedPaths.where((x) => x.trim().isNotEmpty))
                      Text(p, style: TextStyle(fontSize: 10, fontFamily: 'monospace', color: tw.slate400)),
                  ],
                ),
              ),
            const SizedBox(height: 24),
            Divider(color: tw.line),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: tw.amber50,
                border: Border.all(color: const Color(0xFFFDE68A)),
                borderRadius: BorderRadius.circular(Tw.radiusXl),
              ),
              child: RichText(
                text: TextSpan(
                  style: TextStyle(fontSize: 12, height: 1.6, color: tw.amber700),
                  children: const [
                    TextSpan(
                      text: 'Initial indexing runs at full speed. ',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    TextSpan(
                      text: 'On a typical NAS hard drive, expect roughly 1–5 minutes per million files (faster on SSD). The app stays fully usable while indexing runs in the background.',
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _PathField extends StatelessWidget {
  final String value;
  final String placeholder;
  final DatieveColors colors;
  final bool soft;
  final ValueChanged<String> onChanged;

  const _PathField({
    required this.value,
    required this.placeholder,
    required this.colors,
    required this.onChanged,
    this.soft = false,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return TextField(
      controller: TextEditingController(text: value)
        ..selection = TextSelection.collapsed(offset: value.length),
      onChanged: onChanged,
      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: tw.ink),
      decoration: InputDecoration(
        hintText: placeholder,
        filled: true,
        fillColor: soft ? tw.slate50 : tw.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tw.radiusXl),
          borderSide: BorderSide(color: tw.slate200),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tw.radiusXl),
          borderSide: BorderSide(color: tw.slate200),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Tw.radiusXl),
          borderSide: BorderSide(color: tw.slate900),
        ),
      ),
    );
  }
}

class _IconFieldButton extends StatefulWidget {
  final IconData icon;
  final DatieveColors colors;
  final VoidCallback onPressed;
  final bool danger;

  const _IconFieldButton({
    required this.icon,
    required this.colors,
    required this.onPressed,
    this.danger = false,
  });

  @override
  State<_IconFieldButton> createState() => _IconFieldButtonState();
}

class _IconFieldButtonState extends State<_IconFieldButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tw.white,
            borderRadius: BorderRadius.circular(Tw.radiusXl),
            border: Border.all(
              color: widget.danger && _hovered
                  ? tw.red100
                  : _hovered
                      ? tw.slate400
                      : tw.slate200,
            ),
          ),
          child: Icon(
            widget.icon,
            size: 18,
            color: widget.danger && _hovered ? tw.red500 : _hovered ? tw.ink : tw.slate400,
          ),
        ),
      ),
    );
  }
}

class _Toggle extends StatelessWidget {
  final bool value;
  final DatieveColors colors;
  final ValueChanged<bool> onChanged;

  const _Toggle({
    required this.value,
    required this.colors,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return GestureDetector(
      onTap: () => onChanged(!value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 56,
        height: 32,
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: value ? tw.slate900 : tw.slate200,
          borderRadius: BorderRadius.circular(999),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 200),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: tw.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: [
                BoxShadow(color: colors.ink.withValues(alpha: 0.08), blurRadius: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChipButton extends StatefulWidget {
  final String label;
  final DatieveColors colors;
  final VoidCallback onPressed;
  final bool dashed;

  const _ChipButton({
    required this.label,
    required this.colors,
    required this.onPressed,
    this.dashed = false,
  });

  @override
  State<_ChipButton> createState() => _ChipButtonState();
}

class _ChipButtonState extends State<_ChipButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tw = Tw(widget.colors);
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: tw.slate50,
            borderRadius: BorderRadius.circular(Tw.radiusLg),
            border: Border.all(
              color: _hovered ? tw.slate900 : tw.slate200,
              style: widget.dashed ? BorderStyle.solid : BorderStyle.solid,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              color: _hovered ? tw.ink : tw.slate500,
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final String label;
  final DatieveColors colors;

  const _SummaryChip({required this.label, required this.colors});

  @override
  Widget build(BuildContext context) {
    final tw = Tw(colors);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: tw.slate100,
        borderRadius: BorderRadius.circular(Tw.radiusLg),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: tw.slate500),
      ),
    );
  }
}