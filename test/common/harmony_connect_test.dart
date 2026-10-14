import 'package:fl_clash/common/harmony_connect.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses profile-update-interval from yaml and headers', () {
    const yaml = '''
proxies: []
profile-update-interval: 3600
''';
    expect(profileUpdateIntervalFromYaml(yaml), const Duration(hours: 1));
    expect(profileUpdateIntervalFromHeader('7200'), const Duration(hours: 2));
    expect(profileUpdateIntervalFromValue(0), isNull);
  });
}
