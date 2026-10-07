import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:my_app/activation_service.dart';

/// يُنشئ نسخة Firestore وهمية تحتوي على مجموعة `activation_codes`.
Future<FakeFirebaseFirestore> seedCodes(
  Map<String, bool> codes, // الكود -> هل هو مستخدم؟
) async {
  final fs = FakeFirebaseFirestore();
  for (final entry in codes.entries) {
    await fs.collection('activation_codes').doc(entry.key).set({
      'used': entry.value,
    });
  }
  return fs;
}

void main() {
  group('redeemActivationCode', () {
    test('الكود الفارغ يُرفض', () async {
      final fs = await seedCodes({'12345': false});
      expect(await redeemActivationCode(fs, '', uid: 'u1'),
          ActivationResult.empty);
      expect(await redeemActivationCode(fs, '   ', uid: 'u1'),
          ActivationResult.empty);
    });

    test('الكود غير الموجود يُرفض', () async {
      final fs = await seedCodes({'12345': false});
      expect(await redeemActivationCode(fs, '99999', uid: 'u1'),
          ActivationResult.notFound);
    });

    test('الكود الصحيح غير المستخدم يُقبل ويُستهلك', () async {
      final fs = await seedCodes({'12345': false});
      final result = await redeemActivationCode(fs, '12345', uid: 'u1');
      expect(result, ActivationResult.success);

      final doc = await fs.collection('activation_codes').doc('12345').get();
      expect(doc.data()?['used'], true);
      expect(doc.data()?['usedBy'], 'u1');
      expect(doc.data()?['usedAt'], isNotNull);
    });

    test('إعادة استخدام نفس الكود تُرفض', () async {
      final fs = await seedCodes({'12345': false});
      expect(await redeemActivationCode(fs, '12345', uid: 'u1'),
          ActivationResult.success);
      expect(await redeemActivationCode(fs, '12345', uid: 'u2'),
          ActivationResult.alreadyUsed);
    });

    test('الكود المستخدم مسبقاً يُرفض', () async {
      final fs = await seedCodes({'AAA': true});
      expect(await redeemActivationCode(fs, 'AAA', uid: 'u1'),
          ActivationResult.alreadyUsed);
    });

    test('المسافات الزائدة حول الكود تُقتطع', () async {
      final fs = await seedCodes({'12345': false});
      expect(await redeemActivationCode(fs, '  12345  ', uid: 'u1'),
          ActivationResult.success);
    });
  });
}
