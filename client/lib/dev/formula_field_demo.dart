// Standalone harness for FormulaField (spec 011). Not imported by the app:
// build with `flutter build web -t lib/dev/formula_field_demo.dart`.
// Until the rollout (013) the field is only used here and in tests.
import 'package:budget_formula/budget_formula.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import '../boot/boot_loader.dart';
import '../theme/app_theme.dart';
import '../widgets/formula/formula_field.dart';

VariableValue _v(String name, String value, VariableUnit unit) =>
    VariableValue(name, Decimal.parse(value), unit);

final VariableScope demoScope = VariableScope(
  variables: [
    _v('rent', '1200', VariableUnit.money),
    _v('rego', '850', VariableUnit.money),
    _v('fare', '4.5', VariableUnit.money),
    _v('rate', '5.5', VariableUnit.percent),
    _v('weeks', '52', VariableUnit.number),
    _v('salary', '90000', VariableUnit.money),
    _v('groceries_weekly_family_of_four', '320', VariableUnit.money),
  ],
  descriptions: const {
    'rent': 'Fortnightly rent, unit 4',
    'rate': 'Home loan rate',
    'salary': 'Gross yearly',
  },
);

void main() {
  runApp(const FormulaDemoApp());
  // The page's boot overlay (web/index.html) waits for this.
  BootLoader.finishWhenReady(authReady: Future.value(false));
}

class FormulaDemoApp extends StatelessWidget {
  const FormulaDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'FormulaField demo',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.dark(),
    home: const FormulaDemoPage(),
  );
}

class FormulaDemoPage extends StatefulWidget {
  const FormulaDemoPage({super.key});

  @override
  State<FormulaDemoPage> createState() => _FormulaDemoPageState();
}

class _FormulaDemoPageState extends State<FormulaDemoPage> {
  final _top = FormulaEditingController();
  final _bottom = FormulaEditingController(text: r'$rent / 2');
  final _plain = TextEditingController(text: '12.50');
  String _status = 'Nothing submitted';
  int _saves = 0;

  @override
  void dispose() {
    _top.dispose();
    _bottom.dispose();
    _plain.dispose();
    super.dispose();
  }

  void _submitted(String where, FormulaValue v) => setState(() {
    _saves++;
    _status =
        'Submitted #$_saves $where: value=${v.value} expr=${v.expr} '
        'error=${v.message}';
  });

  Future<void> _openEditor() async {
    final c = FormulaEditingController(text: r'($rent + 50) * 2');
    final saved = await showDialog<FormulaValue>(
      context: context,
      builder: (context) => _EditorDialog(controller: c),
    );
    c.dispose();
    if (!mounted) return;
    setState(
      () => _status = saved == null
          ? 'Dialog closed without saving'
          : 'Dialog saved: value=${saved.value} expr=${saved.expr}',
    );
  }

  @override
  // The status doubles as the page title so browser tests can read it.
  Widget build(BuildContext context) =>
      Title(title: _status, color: Colors.black, child: _page());

  Widget _page() => Scaffold(
    appBar: AppBar(title: const Text('FormulaField demo')),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              FormulaField(
                key: const ValueKey('demo-top'),
                spec: fieldSpecs['event.amount']!,
                scope: demoScope,
                controller: _top,
                label: 'Amount',
                prefixText: '\$ ',
                hintText: '0.00',
                formulasEnabled: true,
                onSubmitted: (v) => _submitted('top', v),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('demo-plain'),
                controller: _plain,
                decoration: const InputDecoration(labelText: 'Plain field'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                key: const ValueKey('demo-open-dialog'),
                onPressed: _openEditor,
                child: const Text('Open editor dialog'),
              ),
              const SizedBox(height: 12),
              Text(_status, key: const ValueKey('demo-status')),
            ],
          ),
        ),
        // Near the bottom: the list flips above.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: FormulaField(
            key: const ValueKey('demo-bottom'),
            spec: fieldSpecs['event.amount']!,
            scope: demoScope,
            controller: _bottom,
            label: 'Amount each time',
            prefixText: '\$ ',
            hintText: '0.00',
            formulasEnabled: true,
            onSubmitted: (v) => _submitted('bottom', v),
          ),
        ),
      ],
    ),
  );
}

class _EditorDialog extends StatelessWidget {
  const _EditorDialog({required this.controller});
  final FormulaEditingController controller;

  @override
  Widget build(BuildContext context) {
    void save() {
      final v = controller.formula;
      if (v.isValid) Navigator.of(context).pop(v);
    }

    return AlertDialog(
      key: const ValueKey('demo-dialog'),
      title: const Text('Edit event'),
      content: SizedBox(
        width: 420,
        child: FormulaField(
          key: const ValueKey('editor-amount'),
          spec: fieldSpecs['event.amount']!,
          scope: demoScope,
          controller: controller,
          label: 'Amount',
          prefixText: '\$ ',
          hintText: '0.00',
          autofocus: true,
          formulasEnabled: true,
          onSubmitted: (_) => save(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: save, child: const Text('Save')),
      ],
    );
  }
}
