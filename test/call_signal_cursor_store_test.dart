import 'package:backchat/services/call_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('loads zero when no call signal cursor is stored', () async {
    final CallSignalCursorStore store = CallSignalCursorStore();

    expect(await store.load('username:alice'), 0);
  });

  test('stores call signal cursors independently per user', () async {
    final CallSignalCursorStore store = CallSignalCursorStore();

    await store.save('username:alice', 18);
    await store.save('username:bob', 42);

    expect(await store.load('username:alice'), 18);
    expect(await store.load('username:bob'), 42);
  });
}
