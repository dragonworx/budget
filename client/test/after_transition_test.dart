// whenOpenTransitionCompletes: focus after the route / switcher
// animation finishes, not after a fixed delay.
import 'package:budget_client/widgets/after_transition.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('a dialog focuses the field once its open animation completes', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final wait = TransitionWait();
    addTearDown(wait.cancel);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  wait.schedule(context, focus.requestFocus);
                });
                return AlertDialog(
                  content: TextField(
                    key: const ValueKey('name'),
                    focusNode: focus,
                  ),
                );
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump(); // dialog is in, animation running
    expect(
      ModalRoute.of(tester.element(find.byType(TextField)))!.animation,
      isNotNull,
    );
    expect(
      ModalRoute.of(tester.element(find.byType(TextField)))!.animation!.status,
      AnimationStatus.forward,
    );
    expect(focus.hasFocus, isFalse);
    // Mid-transition: still not focused (no fixed delay has fired).
    await tester.pump(const Duration(milliseconds: 50));
    expect(focus.hasFocus, isFalse);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('an in-place switcher focuses after its fade completes', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final wait = TransitionWait();
    addTearDown(wait.cancel);
    var show = false;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            body: Column(
              children: [
                TextButton(
                  onPressed: () => setState(() => show = true),
                  child: const Text('open'),
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, anim) =>
                        FadeTransition(opacity: anim, child: child),
                    child: show
                        ? _FocusAfterFade(
                            key: const ValueKey('editor'),
                            focus: focus,
                            wait: wait,
                          )
                        : const SizedBox(key: ValueKey('list')),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(focus.hasFocus, isFalse);
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
  });

  testWidgets('cancel before the animation ends never runs the callback', (
    tester,
  ) async {
    var ran = false;
    final wait = TransitionWait();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  wait.schedule(context, () => ran = true);
                });
                return const AlertDialog(content: Text('x'));
              },
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    wait.cancel();
    await tester.pumpAndSettle();
    expect(ran, isFalse);
  });
}

class _FocusAfterFade extends StatefulWidget {
  const _FocusAfterFade({super.key, required this.focus, required this.wait});
  final FocusNode focus;
  final TransitionWait wait;

  @override
  State<_FocusAfterFade> createState() => _FocusAfterFadeState();
}

class _FocusAfterFadeState extends State<_FocusAfterFade> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.wait.schedule(context, widget.focus.requestFocus);
    });
  }

  @override
  Widget build(BuildContext context) =>
      TextField(key: const ValueKey('name'), focusNode: widget.focus);
}
