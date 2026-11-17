import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lastwave_desktop/ui/components/select.dart';

void main() {
  testWidgets('WaveSelect centers label with even top and bottom padding', (
    tester,
  ) async {
    String selected = 'track';
    await tester.pumpWidget(
      FluentApp(
        home: Center(
          child: SizedBox(
            width: 220,
            child: StatefulBuilder(
              builder: (context, setState) => WaveSelect<String>(
                expanded: true,
                value: selected,
                options: const [
                  WaveSelectOption(value: 'track', label: 'When track loaded'),
                  WaveSelectOption(value: 'off', label: 'Minimize normally'),
                ],
                onChanged: (v) => setState(() => selected = v),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    final triggerRect = tester.getRect(find.byType(AnimatedContainer));
    final textRect = tester.getRect(find.text('When track loaded'));
    final iconRect = tester.getRect(find.byIcon(FluentIcons.chevron_down));

    final topGap = textRect.top - triggerRect.top;
    final bottomGap = triggerRect.bottom - textRect.bottom;
    expect(triggerRect.height, 36);
    expect((topGap - bottomGap).abs(), lessThanOrEqualTo(0.5));
    expect(
      (textRect.center.dy - iconRect.center.dy).abs(),
      lessThanOrEqualTo(0.5),
    );
  });

  testWidgets(
      'WaveSelect shrink-wraps content under loose constraints when expanded is false',
      (tester) async {
    await tester.pumpWidget(
      FluentApp(
        home: Center(
          child: WaveSelect<String>(
            expanded: false,
            value: 'off',
            options: const [
              WaveSelectOption(value: 'off', label: 'Off'),
              WaveSelectOption(value: 'track', label: 'Track'),
            ],
            onChanged: (_) {},
          ),
        ),
      ),
    );
    await tester.pump();

    final triggerRect = tester.getRect(find.byType(AnimatedContainer));
    final textRect = tester.getRect(find.text('Off'));
    final iconRect = tester.getRect(find.byIcon(FluentIcons.chevron_down));

    // Must hug the short "Off" label rather than stretching across the 800px window.
    expect(triggerRect.width, lessThan(200));
    expect(triggerRect.height, 36);
    expect((textRect.center.dy - iconRect.center.dy).abs(), lessThanOrEqualTo(0.5));
  });
}
