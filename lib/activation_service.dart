import 'package:cloud_firestore/cloud_firestore.dart';

/// نتيجة محاولة استبدال كود تفعيل.
enum ActivationResult {
  /// الكود صحيح ولم يُستخدم من قبل، وتم استهلاكه الآن.
  success,

  /// الكود فارغ.
  empty,

  /// الكود غير موجود في مجموعة `activation_codes`.
  notFound,

  /// الكود مستخدم مسبقاً.
  alreadyUsed,

  /// تعذّر إتمام المعاملة (خطأ شبكة/صلاحيات).
  error,
}

/// يتحقق من صحة [code] مقابل مجموعة `activation_codes` في Firestore ويستهلكه
/// مرة واحدة فقط ضمن معاملة ذرّية (transaction) لمنع إعادة الاستخدام.
///
/// بنية مستند الكود داخل المجموعة (معرّف المستند = الكود نفسه):
/// `{ "used": false }`
///
/// ملاحظة أمنية: للتحقق الفعلي يجب منع وصول العميل المباشر لهذه المجموعة عبر
/// `firestore.rules` ونقل الاستدعاء إلى Cloud Function.
Future<ActivationResult> redeemActivationCode(
  FirebaseFirestore firestore,
  String code, {
  String? uid,
}) async {
  final String trimmed = code.trim();
  if (trimmed.isEmpty) return ActivationResult.empty;

  final DocumentReference ref =
      firestore.collection('activation_codes').doc(trimmed);

  try {
    return await firestore.runTransaction<ActivationResult>((tx) async {
      final DocumentSnapshot snap = await tx.get(ref);
      if (!snap.exists) return ActivationResult.notFound;

      final Map<String, dynamic> data =
          (snap.data() as Map<String, dynamic>?) ?? {};
      if (data['used'] == true) return ActivationResult.alreadyUsed;

      tx.update(ref, {
        'used': true,
        'usedBy': uid,
        'usedAt': FieldValue.serverTimestamp(),
      });
      return ActivationResult.success;
    });
  } catch (_) {
    return ActivationResult.error;
  }
}
