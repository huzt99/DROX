import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import 'activation_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'تطبيق إدارة المشتركين',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        fontFamily: 'Cairo', // يمكن تغيير الخط حسب الرغبة
      ),
      home: const MainAppScreen(),
    );
  }
}

class MainAppScreen extends StatefulWidget {
  const MainAppScreen({Key? key}) : super(key: key);

  @override
  State<MainAppScreen> createState() => _MainAppScreenState();
}

class _MainAppScreenState extends State<MainAppScreen> {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // ملاحظة أمنية: لا يتم تخزين كود التفعيل داخل الكود المصدري.
  // يتم التحقق من الأكواد مقابل مجموعة `activation_codes` في Firestore.
  // راجع lib/activation_service.dart.

  // متسلسلات التجربة والتفعيل
  bool _isActivated = false;
  bool _isTrialActive = false;
  bool _trialExpired = false;
  int _trialSecondsLeft = 15 * 60; // 15 دقيقة
  Timer? _trialTimer;

  // بيانات التليجرام الخاصة بالمستخدم
  String? _botToken;
  String? _chatId;

  @override
  void initState() {
    super.initState();
    _checkUserStatus();
  }

  @override
  void dispose() {
    _trialTimer?.cancel();
    super.dispose();
  }

  // 1. التحقق من حالة التفعيل والحساب
  Future<void> _checkUserStatus() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null) {
      DocumentSnapshot userDoc =
          await _firestore.collection('users').doc(currentUser.uid).get();
      if (userDoc.exists && userDoc.data() != null) {
        Map<String, dynamic> data = userDoc.data() as Map<String, dynamic>;
        setState(() {
          _isActivated = data['isActivated'] ?? false;
          _botToken = data['botToken'];
          _chatId = data['chatId'];
        });
      }
    }
  }

  // 2. بدء الوضع التجريبي (15 دقيقة)
  void _startTrial() {
    setState(() {
      _isTrialActive = true;
      _trialExpired = false;
      _trialSecondsLeft = 15 * 60;
    });

    _trialTimer?.cancel();
    _trialTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_trialSecondsLeft > 0) {
        setState(() {
          _trialSecondsLeft--;
        });
      } else {
        timer.cancel();
        setState(() {
          _isTrialActive = false;
          _trialExpired = true;
        });
        _showTrialExpiredDialog();
      }
    });
  }

  // تنبيه انتهاء الفترة التجريبية
  void _showTrialExpiredDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("انتهت الفترة التجريبية"),
        content: const Text(
            "لقد انتهت الـ 15 دقيقة التجريبية. يرجى شراء التطبيق وتفعيله لاستمرار الاستخدام."),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _showActivationDialog();
            },
            child: const Text("شراء وتفعيل التطبيق"),
          ),
        ],
      ),
    );
  }

  // 3. نافذة أدخل كود التفعيل
  void _showActivationDialog() {
    final TextEditingController codeController = TextEditingController();
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("تفعيل التطبيق"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("أدخل كود التفعيل الذي حصلت عليه بعد الشراء:"),
            const SizedBox(height: 10),
            TextField(
              controller: codeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "كود التفعيل",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("إلغاء"),
          ),
          ElevatedButton(
            onPressed: () async {
              final ActivationResult result = await redeemActivationCode(
                _firestore,
                codeController.text,
                uid: _auth.currentUser?.uid,
              );

              if (result == ActivationResult.success) {
                Navigator.pop(context);
                await _activateAppInFirebase();
              } else {
                Navigator.pop(context);
                messenger.showSnackBar(
                  SnackBar(content: Text(_activationErrorMessage(result))),
                );
              }
            },
            child: const Text("تفعيل الآن"),
          ),
        ],
      ),
    );
  }

  // رسالة الخطأ المناسبة لنتيجة التحقق من كود التفعيل
  String _activationErrorMessage(ActivationResult result) {
    switch (result) {
      case ActivationResult.alreadyUsed:
        return "كود التفعيل مستخدم مسبقاً!";
      case ActivationResult.notFound:
        return "كود التفعيل غير صحيح!";
      case ActivationResult.empty:
        return "يرجى إدخال كود التفعيل.";
      case ActivationResult.error:
        return "تعذّر التحقق من الكود، حاول مرة أخرى.";
      case ActivationResult.success:
        return "";
    }
  }

  // ربط التفعيل بحساب المستخدم في Firebase
  Future<void> _activateAppInFirebase() async {
    User? currentUser = _auth.currentUser;
    if (currentUser != null) {
      await _firestore.collection('users').doc(currentUser.uid).set({
        'isActivated': true,
        'email': currentUser.email,
        'activatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      setState(() {
        _isActivated = true;
        _isTrialActive = false;
      });

      _trialTimer?.cancel();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("تم تفعيل التطبيق بنجاح وربطه بحسابك!")),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("يرجى تسجيل الدخول بالحساب أولاً لتثبيت التفعيل.")),
      );
    }
  }

  // 4. نافذة إعدادات وتفعيل إشعارات التليجرام
  void _showTelegramConfigDialog() {
    final TextEditingController tokenController =
        TextEditingController(text: _botToken);
    final TextEditingController chatIdController =
        TextEditingController(text: _chatId);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("إعدادات إشعارات التليجرام"),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "1. أنشئ بوت مجاني عبر @BotFather واحصل على الـ Token.\n"
                "2. أضف البوت إلى قناتك أو مجموعتك كـ Admin.\n"
                "3. ادخل Token ومعرف القناة (Chat ID) أدناه:",
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
              const SizedBox(height: 15),
              TextField(
                controller: tokenController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "Bot Token",
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: chatIdController,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: "Chat ID (مثال: @mychannel أو 123456-)",
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("إلغاء"),
          ),
          ElevatedButton(
            onPressed: () async {
              String token = tokenController.text.trim();
              String chatId = chatIdController.text.trim();

              if (token.isNotEmpty && chatId.isNotEmpty) {
                User? currentUser = _auth.currentUser;
                if (currentUser != null) {
                  await _firestore
                      .collection('users')
                      .doc(currentUser.uid)
                      .set({
                    'botToken': token,
                    'chatId': chatId,
                  }, SetOptions(merge: true));

                  setState(() {
                    _botToken = token;
                    _chatId = chatId;
                  });

                  Navigator.pop(context);

                  // إرسال إشعار تجريبي للتأكد
                  await _sendTelegramNotification(
                      "🚀 تم ربط بوت التليجرام بنجاح مع تطبيقك!");

                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text("تم حفظ البيانات وإرسال رسالة تجريبية!")),
                  );
                }
              }
            },
            child: const Text("حفظ واختبار"),
          ),
        ],
      ),
    );
  }

  // 5. دالة إرسال الإشعارات للتليجرام
  Future<void> _sendTelegramNotification(String message) async {
    if (_botToken == null ||
        _chatId == null ||
        _botToken!.isEmpty ||
        _chatId!.isEmpty) {
      return;
    }

    final url = Uri.parse('https://api.telegram.org/bot$_botToken/sendMessage');
    try {
      await http.post(
        url,
        body: {
          'chat_id': _chatId,
          'text': message,
        },
      );
    } catch (e) {
      print("خطأ في إرسال إشعار التليجرام: $e");
    }
  }

  // تنسيق وقت التجربة
  String _formatTime(int seconds) {
    int minutes = seconds ~/ 60;
    int remainingSeconds = seconds % 60;
    return '${minutes.toString().padLeft(2, '0')}:${remainingSeconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("التطبيق الرئيسي"),
        actions: [
          // زر تفعيل إشعارات التليجرام أعلى الشاشة
          IconButton(
            icon: const Icon(Icons.send),
            tooltip: "تفعيل إشعارات التليجرام",
            onPressed: _showTelegramConfigDialog,
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // شريط حالة التفعيل أو الفترة التجريبية
            if (_isActivated)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.green.shade100,
                child: const Row(
                  children: [
                    Icon(Icons.check_circle, color: Colors.green),
                    SizedBox(width: 10),
                    Text("التطبيق مفعل بنجاح (النسخة الكاملة)",
                        style: TextStyle(
                            color: Colors.green, fontWeight: FontWeight.bold)),
                  ],
                ),
              )
            else if (_isTrialActive)
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.orange.shade100,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text("الوضع التجريبي نشط",
                        style: TextStyle(
                            color: Colors.orange, fontWeight: FontWeight.bold)),
                    Text("الوقت المتبقي: ${_formatTime(_trialSecondsLeft)}",
                        style: const TextStyle(
                            color: Colors.red, fontWeight: FontWeight.bold)),
                  ],
                ),
              )
            else
              Container(
                padding: const EdgeInsets.all(12),
                color: Colors.red.shade100,
                child: const Text(
                    "التطبيق غير مفعل. يرجى الشراء أو بدء التجربة.",
                    style: TextStyle(
                        color: Colors.red, fontWeight: FontWeight.bold)),
              ),

            const SizedBox(height: 30),

            // أزرار التحكم والعمليات
            if (!_isActivated && !_isTrialActive) ...[
              ElevatedButton.icon(
                icon: const Icon(Icons.timer),
                label: const Text("دخول تجريبي (15 دقيقة)"),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    padding: const EdgeInsets.all(15)),
                onPressed: _trialExpired ? null : _startTrial,
              ),
              const SizedBox(height: 15),
              ElevatedButton.icon(
                icon: const Icon(Icons.shopping_cart),
                label: const Text("شراء وتفعيل التطبيق"),
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    padding: const EdgeInsets.all(15)),
                onPressed: _showActivationDialog,
              ),
            ],

            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 20),

            // محتوى التطبيق الداخلي (يفتح عند التفعيل أو في فترة التجربة)
            if (_isActivated || _isTrialActive) ...[
              const Text("واجهة الخدمات والمشتركين",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 15),
              ElevatedButton(
                onPressed: () {
                  // مثال لإرسال إشعار تجريبي عند تسديد مشترك
                  _sendTelegramNotification(
                      "💰 إشعار تسديد:\nقام المشترك أحمد بتسديد المبلغ.");
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content:
                            Text("تم إجراء العملية وإرسال الإشعار للتليجرام!")),
                  );
                },
                child: const Text("تسديد مشترك (تجربة إرسال إشعار)"),
              ),
            ] else
              const Center(
                child: Text(
                    "يرجى تفعيل التطبيق أو اختيار الدخول التجريبي للوصول للخدمات."),
              ),
          ],
        ),
      ),
    );
  }
}
