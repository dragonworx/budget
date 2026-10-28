import 'dart:async';
import 'dart:convert';

import 'package:budget_recurrence/budget_recurrence.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../boot/page_stub.dart'
    if (dart.library.js_interop) '../../boot/page_web.dart';
import '../../data/api_client.dart';
import '../../data/frequency.dart';
import '../../data/models.dart';
import '../../state/providers.dart';
import '../../theme/app_theme.dart';
import '../../widgets/money_text.dart';
import '../timeline/occurrence_dates.dart';
import '../timeline/occurrence_info.dart';

/// Shown wherever import is unavailable because no day is selected.
const importNeedsDayHint =
    'Select a day first: tap the dates under the timeline. '
    'Imported dates count from that day.';

/// Result of a successful import.
class ImportResult {
  const ImportResult(this.created, this.skipped, {this.createdIds = const []});
  final int created;
  final int skipped;

  /// Ids of the rows this import created (what its Undo removes).
  final List<String> createdIds;

  String get message {
    final parts = [
      'Imported $created event${created == 1 ? '' : 's'}',
      if (skipped > 0) '$skipped already existed (skipped)',
    ];
    return parts.join(' · ');
  }
}

/// Paste import into [streamId]: a Paste button reads the clipboard (a JSON
/// array of `EventImport`, day offsets from [root], the day selected
/// on the timeline); the server validates it and resolves the dates (dry
/// run), and the dialog previews one row per event. Import is
/// enabled once a paste is valid.
Future<ImportResult?> showImportDialog(
  BuildContext context, {
  required String streamId,
  required DateTime root,
}) {
  return showDialog<ImportResult>(
    context: context,
    builder: (_) => _ImportDialog(streamId: streamId, root: root),
  );
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog({required this.streamId, required this.root});
  final String streamId;

  /// The selected day; fixed for the dialog's lifetime.
  final DateTime root;
  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  /// The validated paste (what Import sends), or null.
  String? _raw;
  bool _reading = false;
  bool _importing = false;
  List<Map<String, dynamic>> _items = const [];
  List<String> _issues = const [];
  int _toCreate = 0;
  int _toSkip = 0;

  /// The read started from the press's pointer-up (inside the gesture, as
  /// iOS Safari requires); the button's onPressed then does nothing more.
  DateTime? _readStartedAt;

  final _tableScroll = ScrollController();

  @override
  void dispose() {
    _tableScroll.dispose();
    super.dispose();
  }

  void _pasteFromPointer() {
    if (_reading || _importing) return;
    _readStartedAt = DateTime.now();
    _paste();
  }

  void _pasteFromButton() {
    final t = _readStartedAt;
    if (t != null &&
        DateTime.now().difference(t) < const Duration(seconds: 1)) {
      return; // this press already started the read
    }
    _paste();
  }

  Future<void> _paste() async {
    if (_reading || _importing) return;
    // Called synchronously from the tap: the clipboard read starts here.
    final read = readClipboardText();
    setState(() {
      _reading = true;
      _issues = const [];
    });
    String? text;
    try {
      text = await read;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _clearPreview();
        _issues = [
          'Couldn’t read the clipboard'
              '${e is ClipboardReadException ? ' ($e)' : ''}. Allow '
              'clipboard access for this site (on iPhone, tap Paste when '
              'Safari asks), then try again.',
        ];
      });
      return;
    }
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() {
        _reading = false;
        _clearPreview();
        _issues = const [
          'The clipboard is empty. Copy the events JSON, then tap '
              'Paste.',
        ];
      });
      return;
    }
    try {
      final res = await ref
          .read(eventRepositoryProvider)
          .import(widget.streamId, text, root: widget.root, dryRun: true);
      if (!mounted) return;
      setState(() {
        _reading = false;
        _raw = text;
        _items = (res['items'] as List).cast<Map<String, dynamic>>();
        _toCreate = res['toCreate'] as int? ?? _items.length;
        _toSkip = res['toSkip'] as int? ?? 0;
        _issues = const [];
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _clearPreview();
        _issues = _issuesFrom(e);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _clearPreview();
        _issues = [friendlyMessage(e)];
      });
    }
  }

  void _clearPreview() {
    _raw = null;
    _items = const [];
    _toCreate = 0;
    _toSkip = 0;
  }

  static String friendlyMessage(Object e) => '$e';

  List<String> _issuesFrom(ApiException e) {
    try {
      final body = jsonDecode(e.body ?? '');
      final details = body is Map ? body['details'] : null;
      if (details is List && details.isNotEmpty) {
        return [
          for (final d in details)
            d is Map ? (d['text'] ?? d['message']).toString() : '$d',
        ];
      }
    } catch (_) {}
    return [e.message];
  }

  Future<void> _import() async {
    final raw = _raw;
    if (raw == null) return;
    setState(() => _importing = true);
    try {
      final res = await ref
          .read(eventRepositoryProvider)
          .import(widget.streamId, raw, root: widget.root);
      if (!mounted) return;
      Navigator.of(context).pop(
        ImportResult(
          res['created'] as int? ?? 0,
          res['skipped'] as int? ?? 0,
          createdIds: [
            for (final id in res['createdIds'] as List? ?? const []) '$id',
          ],
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _clearPreview();
        _issues = _issuesFrom(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valid = _raw != null && _items.isNotEmpty && _issues.isEmpty;
    final busy = _reading || _importing;
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 520;
    return AlertDialog(
      // Phones: header, paste and preview scroll instead of overflowing.
      scrollable: true,
      // Phones: tighter margins so the four columns fit the width.
      insetPadding: narrow
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 24)
          : null,
      titlePadding: narrow ? const EdgeInsets.fromLTRB(16, 20, 16, 0) : null,
      contentPadding: narrow ? const EdgeInsets.fromLTRB(16, 16, 16, 8) : null,
      title: const Text('Import events'),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text.rich(
              key: const ValueKey('import-root'),
              TextSpan(
                children: [
                  const TextSpan(text: 'Dates count from '),
                  TextSpan(
                    text: formatOccurrenceDate(widget.root),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const TextSpan(text: ' (the selected day).'),
                ],
              ),
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              // The read starts on pointer-up, inside the tap (iOS Safari);
              // onPressed covers keyboard / assistive activation.
              child: Listener(
                onPointerUp: (_) => _pasteFromPointer(),
                child: FilledButton.tonalIcon(
                  key: const ValueKey('import-paste'),
                  onPressed: busy ? null : _pasteFromButton,
                  icon: _reading
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.content_paste_rounded),
                  label: Text(
                    _reading
                        ? 'Reading…'
                        : (_raw == null ? 'Paste' : 'Paste again'),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            if (_issues.isNotEmpty) _issuesBox(theme),
            if (_items.isNotEmpty)
              _previewTable(
                theme,
                narrow: narrow,
                // The dialog's content width (less the table border): no
                // LayoutBuilder, the scrollable AlertDialog measures
                // intrinsics.
                tableWidth:
                    (size.width - (narrow ? 2 * 12 + 2 * 16 : 2 * 40 + 2 * 24))
                        .clamp(0, 640) -
                    2,
                maxHeight: (size.height * 0.5).clamp(140, 420),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('import-confirm'),
          onPressed: valid && _toCreate > 0 && !busy ? _import : null,
          child: Text(
            _importing
                ? 'Importing…'
                : valid
                ? (_toCreate == 0 ? 'Nothing new' : 'Import $_toCreate')
                : 'Import',
          ),
        ),
      ],
    );
  }

  Widget _issuesBox(ThemeData theme) {
    final fg = theme.colorScheme.onErrorContainer;
    return Container(
      key: const ValueKey('import-error'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_issues.length > 1 || _issues.first.startsWith('['))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                'Nothing can be imported until every item is valid '
                '(${_issues.length} problem${_issues.length == 1 ? '' : 's'}):',
                style: theme.textTheme.labelMedium?.copyWith(color: fg),
              ),
            ),
          for (final issue in _issues.take(12))
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                _issues.length > 1 || issue.startsWith('[')
                    ? '• $issue'
                    : issue,
                style: theme.textTheme.bodySmall?.copyWith(color: fg),
              ),
            ),
          if (_issues.length > 12)
            Text(
              '… and ${_issues.length - 12} more',
              style: theme.textTheme.bodySmall?.copyWith(color: fg),
            ),
        ],
      ),
    );
  }

  Widget _previewTable(
    ThemeData theme, {
    required double maxHeight,
    required bool narrow,
    required double tableWidth,
  }) {
    final summary = [
      '${_items.length} event${_items.length == 1 ? '' : 's'}',
      if (_toSkip > 0) '$_toSkip already exist (will be skipped)',
    ].join(' · ');
    final head = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      letterSpacing: 0.4,
    );
    final cellStyle = narrow
        ? theme.textTheme.bodySmall
        : theme.textTheme.bodyMedium;
    final sub =
        (narrow ? theme.textTheme.labelSmall : theme.textTheme.bodySmall)
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget cell(Widget child, {bool end = false}) => Padding(
      padding: EdgeInsets.symmetric(horizontal: narrow ? 4 : 8, vertical: 8),
      child: Align(
        alignment: end ? Alignment.centerRight : Alignment.centerLeft,
        child: child,
      ),
    );
    final rows = <TableRow>[
      TableRow(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: theme.dividerColor)),
        ),
        children: [
          cell(Text('DATE', style: head)),
          cell(Text('NAME', style: head)),
          cell(Text('AMOUNT', style: head), end: true),
          cell(Text('FREQUENCY', style: head)),
        ],
      ),
      for (final (i, item) in _items.indexed)
        _row(i, item, cell, cellStyle, sub, theme, narrow),
    ];
    return Column(
      key: const ValueKey('import-preview'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(summary, style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: theme.dividerColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Scrollbar(
              controller: _tableScroll,
              thumbVisibility: true,
              child: SingleChildScrollView(
                key: const ValueKey('import-preview-scroll'),
                controller: _tableScroll,
                // The table fills the width, the name column taking what the
                // others leave (wrapping); only a very narrow screen scrolls
                // it sideways.
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Padding(
                    // Room for the scrollbar thumb (phones: the frequency
                    // column's slack takes it; every pixel goes to columns).
                    padding: EdgeInsets.only(right: narrow ? 0 : 10),
                    child: SizedBox(
                      width:
                          (tableWidth < 320 ? 320 : tableWidth) -
                          (narrow ? 0 : 10),
                      child: Table(
                        key: const ValueKey('import-preview-table'),
                        defaultColumnWidth: const IntrinsicColumnWidth(),
                        columnWidths: const {
                          1: MaxColumnWidth(
                            FlexColumnWidth(),
                            FixedColumnWidth(72),
                          ),
                        },
                        defaultVerticalAlignment:
                            TableCellVerticalAlignment.middle,
                        children: rows,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  TableRow _row(
    int i,
    Map<String, dynamic> item,
    Widget Function(Widget, {bool end}) cell,
    TextStyle? style,
    TextStyle? sub,
    ThemeData theme,
    bool narrow,
  ) {
    final credit = item['direction'] == 'credit';
    final name = (item['name'] as String?)?.isNotEmpty == true
        ? item['name'] as String
        : '(unnamed)';
    final exists = item['exists'] == true;
    final amount = num.tryParse('${item['amount']}') ?? 0;
    final strike = exists
        ? const TextStyle(decoration: TextDecoration.lineThrough)
        : const TextStyle();
    final (freq, detail) = importFrequency(item);
    final notes = [
      ?detail,
      if ((item['skippedDates'] as List?)?.isNotEmpty == true)
        '${(item['skippedDates'] as List).length} skipped',
      if (item['enabled'] == false) 'excluded',
      if (exists) 'already exists',
    ];
    return TableRow(
      key: ValueKey('import-row-$i'),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
        ),
      ),
      children: [
        cell(
          Text(
            _day(item['startDate']),
            key: ValueKey('import-row-$i-date'),
            style: style?.merge(strike),
            softWrap: false,
          ),
        ),
        cell(
          Text(
            name,
            key: ValueKey('import-row-$i-name'),
            style: style?.merge(strike),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        cell(
          Text(
            formatSignedAmount(credit ? amount : -amount),
            key: ValueKey('import-row-$i-amount'),
            softWrap: false,
            style: style
                ?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: credit ? AppTheme.creditColor : AppTheme.debitColor,
                )
                .merge(strike),
          ),
          end: true,
        ),
        cell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                freq,
                key: ValueKey('import-row-$i-frequency'),
                style: style,
                softWrap: false,
              ),
              if (notes.isNotEmpty)
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: narrow ? 84 : 140),
                  child: Text(
                    notes.join(' · '),
                    style: sub,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// A server `YYYY-MM-DD` as "Mon 12 Jan 2026" (as-is if unparseable).
  static String _day(Object? iso) {
    final d = _parseDay(iso);
    return d == null ? '$iso' : formatOccurrenceDate(d);
  }
}

DateTime? _parseDay(Object? iso) {
  final p = '$iso'.split('-').map(int.tryParse).toList();
  if (p.length != 3 || p.contains(null)) return null;
  return DateTime(p[0]!, p[1]!, p[2]!);
}

/// A previewed item's frequency: the structured rule's phrase when the
/// server sends one ("Every week on Mon, Tue", "Monthly on the 1st and
/// 15th"), else the editor's wording ("Once", "Weekly", "Fortnightly",
/// "Monthly", or "Every 5 days" when no preset matches), and its end
/// ("until 26 Jan 2027", "12 times"), if any.
@visibleForTesting
(String, String?) importFrequency(Map<String, dynamic> item) {
  if (item['recurrenceMode'] == 'once') return ('Once', null);
  final n = item['interval'] as int? ?? 1;
  final unit = RecurrenceUnit.values.firstWhere(
    (u) => u.name == item['unit'],
    orElse: () => RecurrenceUnit.months,
  );
  final preset = FrequencyPreset.of(once: false, interval: n, unit: unit);
  final name = unit.name;
  var label = preset != FrequencyPreset.custom
      ? preset.label
      : (n == 1
            ? 'Every ${name.substring(0, name.length - 1)}'
            : 'Every $n $name');
  final freq = item['frequency'];
  final start = _parseDay(item['startDate']);
  if (freq is Map && start != null) {
    try {
      final f = Frequency.fromJson(freq.cast<String, dynamic>());
      if (f.days.isNotEmpty) {
        label = describeFrequency(f, toRuleDate(start), compact: true);
      }
    } on FormatException {
      // Keep the cadence wording.
    }
  }
  final end = switch (item['endMode']) {
    'until_date' => switch (_parseDay(item['endDate'])) {
      final d? => 'until ${DateFormat('d MMM y').format(d)}',
      null => null,
    },
    'count' => '${item['occurrenceCount']} times',
    _ => null,
  };
  return (label, end);
}
