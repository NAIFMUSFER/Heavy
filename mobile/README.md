# JANA Mobile

تطبيق عميل React Native / Expo منفصل عن موقع الويب، ويستخدم API الإنتاج نفسه عبر Bearer access token.

## الموجود حاليًا

- متجر المنتجات والسلال من قاعدة JANA الحية.
- سلة محلية محفوظة على الجهاز.
- تسجيل دخول وإنشاء حساب، مع حفظ access token في Expo SecureStore.
- العناوين، التحقق من التغطية، المواعيد المتاحة، إنشاء Quote وتأكيد طلب COD.
- قائمة الطلبات وتفاصيلها، ومعالجة قرار البدائل المعلقة.
- حماية طلبات التغيير بـ Idempotency-Key؛ الطلبات عبر Bearer لا تعتمد على CSRF الخاص بالويب.

## التشغيل المحلي

```bash
cd mobile
npm install
npx expo start
```

API الافتراضي: `https://jana-fresh-app.onrender.com`.

## حالة الإصدار

هذا مصدر تطبيق جوال فعلي وليس WebView، لكنه لم يُبنَ بعد كـ IPA/APK/AAB ولم يخضع لاختبار جهاز حقيقي أو App Store / Google Play. يلزم حساب Expo/EAS أو بيئة Xcode/Android Build قبل اعتباره build نهائيًا.
