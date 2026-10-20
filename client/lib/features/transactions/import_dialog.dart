import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/api_client.dart';
import '../../state/providers.dart';
import '../../widgets/money_text.dart';

/// Result of a successful import.
class ImportResult {
  const ImportResult(this.created, this.skipped);
  final int created;
  final int skipped;

  String get message {
    final parts = [
      'Imported $created transaction${created == 1 ? '' : 's'}',
      if (skipped > 0) '$skipped already existed (skipped)',
    ];
    return parts.join(' · ');
  }
}

/// Paste-a-JSON-array import into [poolId]. The server validates (dry
/// run) as you type; Import is enabled once the whole paste is valid.
Future<ImportResult?> showImportDialog(
  BuildContext context, {
  required String poolId,
}) {
  return showDialog<ImportResult>(
    context: context,
    builder: (_) => _ImportDialog(poolId: poolId),
  );
}

class _ImportDialog extends ConsumerStatefulWidget {
  const _ImportDialog({required this.poolId});
  final String poolId;
  @override
  ConsumerState<_ImportDialog> createState() => _ImportDialogState();
}

class _Issue {
  _Issue(this.text);
  final String text;
}

class _ImportDialogState extends ConsumerState<_ImportDialog> {
  final _controller = TextEditingController();
  Timer? _debounce;
  int _requestSeq = 0;
  bool _checking = false;
  bool _importing = false;
  List<Map<String, dynamic>> _items = const [];
  List<_Issue> _issues = const [];
  int _toCreate = 0;
  int _toSkip = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _validate);
  }

  Future<void> _validate() async {
    final raw = _controller.text;
    final seq = ++_requestSeq;
    if (raw.trim().isEmpty) {
      setState(() {
        _items = const [];
        _issues = const [];
        _checking = false;
      });
      return;
    }
    setState(() => _checking = true);
    try {
      final res = await ref
          .read(transactionRepositoryProvider)
          .import(widget.poolId, raw, dryRun: true);
      if (seq != _requestSeq || !mounted) return;
      setState(() {
        _items = (res['items'] as List).cast<Map<String, dynamic>>();
        _toCreate = res['toCreate'] as int? ?? _items.length;
        _toSkip = res['toSkip'] as int? ?? 0;
        _issues = const [];
        _checking = false;
      });
    } on ApiException catch (e) {
      if (seq != _requestSeq || !mounted) return;
      setState(() {
        _items = const [];
        _issues = _issuesFrom(e);
        _checking = false;
      });
    } catch (e) {
      if (seq != _requestSeq || !mounted) return;
      setState(() {
        _items = const [];
        _issues = [_Issue(e.toString())];
        _checking = false;
      });
    }
  }

  List<_Issue> _issuesFrom(ApiException e) {
    try {
      final body = jsonDecode(e.body ?? '');
      final details = body is Map ? body['details'] : null;
      if (details is List && details.isNotEmpty) {
        return [
          for (final d in details)
            _Issue(d is Map ? (d['text'] ?? d['message']).toString() : '$d'),
        ];
      }
    } catch (_) {}
    return [_Issue(e.message)];
  }

  Future<void> _import() async {
    setState(() => _importing = true);
    try {
      final res = await ref
          .read(transactionRepositoryProvider)
          .import(widget.poolId, _controller.text);
      if (!mounted) return;
      Navigator.of(context).pop(
        ImportResult(res['created'] as int? ?? 0, res['skipped'] as int? ?? 0),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _importing = false;
        _items = const [];
        _issues = _issuesFrom(e);
      });
    }
  }

  String _frequency(Map<String, dynamic> item) {
    final start = item['startDate'];
    if (item['recurrenceMode'] == 'once') return 'Once on $start';
    final n = item['interval'] as int? ?? 1;
    final unit = (item['unit'] as String? ?? 'months');
    final every = n == 1
        ? 'Every ${unit.substring(0, unit.length - 1)}'
        : 'Every $n $unit';
    final end = switch (item['endMode']) {
      'until_date' => ' until ${item['endDate']}',
      'count' => ' × ${item['occurrenceCount']}',
      _ => '',
    };
    return '$every from $start$end';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valid = _items.isNotEmpty && _issues.isEmpty && !_checking;
    return AlertDialog(
      title: const Text('Import transactions'),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Paste a JSON array of transactions (```json fences are fine). '
              'Items with an id that already exists in this pool are skipped.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('import-paste'),
              controller: _controller,
              onChanged: _onChanged,
              minLines: 6,
              maxLines: 10,
              autofocus: true,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              decoration: const InputDecoration(
                hintText: '[ { "name": "Rent", "direction": "debit", ... } ]',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            if (_checking) const LinearProgressIndicator(minHeight: 2),
            if (_issues.isNotEmpty) _issuesBox(theme),
            if (_items.isNotEmpty) _previewBox(theme),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _importing ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: valid && _toCreate > 0 && !_importing ? _import : null,
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
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Fix ${_issues.length} problem${_issues.length == 1 ? '' : 's'} to import (nothing is imported until all items are valid):',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 6),
            for (final issue in _issues)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '• ${issue.text}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _previewBox(ThemeData theme) {
    final summary = [
      '${_items.length} transaction${_items.length == 1 ? '' : 's'}',
      if (_toSkip > 0) '$_toSkip already exist (will be skipped)',
    ].join(' · ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(summary, style: theme.textTheme.labelLarge),
        const SizedBox(height: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 220),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _items.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final item = _items[i];
              final credit = item['direction'] == 'credit';
              final name = (item['name'] as String?)?.isNotEmpty == true
                  ? item['name'] as String
                  : '(unnamed)';
              final exists = item['exists'] == true;
              final skips = (item['skippedDates'] as List?)?.length ?? 0;
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  credit ? Icons.south_west : Icons.north_east,
                  size: 18,
                  color: credit ? Colors.green.shade700 : Colors.red.shade700,
                ),
                title: Text(
                  name,
                  overflow: TextOverflow.ellipsis,
                  style: exists
                      ? const TextStyle(decoration: TextDecoration.lineThrough)
                      : null,
                ),
                subtitle: Text(
                  [
                    _frequency(item),
                    if (skips > 0)
                      '$skips skipped date${skips == 1 ? '' : 's'}',
                    if (item['enabled'] == false) 'disabled',
                    if (exists) 'already exists',
                  ].join(' · '),
                ),
                trailing: Text(
                  '${credit ? '+' : '−'}$moneySymbol${item['amount']}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: credit ? Colors.green.shade800 : Colors.red.shade800,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
