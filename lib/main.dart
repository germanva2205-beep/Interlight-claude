// InterLight: онбординг, настройки, калории, рецепты с ИИ, камера «Призрак», уведомления,
// шаги из Apple Health / Health Connect и наблюдения ИИ.
// Перед запуском выполните в папке проекта (подробности в SETUP.md):
//   flutter pub add shared_preferences http camera path_provider timezone flutter_timezone image permission_handler image_picker
//   flutter pub add flutter_local_notifications:^19.0.0 health:^13.3.0

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:health/health.dart' as hl;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart' show ImagePicker, ImageSource;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  final docs = await getApplicationDocumentsDirectory();
  final controller = SettingsController(prefs, docs.path);
  await NotificationService.instance.init();
  runApp(InterLightApp(controller: controller));
  unawaited(NotificationService.instance.reschedule(controller.s));
}

// ───────────────────────── Цвета ─────────────────────────

class AppColors {
  static const Color mint = Color(0xFF7FB3A8);
  static const Color peach = Color(0xFFFFE5D9);
  static const Color darkGraphite = Color(0xFF2D3436);
  static const Color fogGray = Color(0xFF95A5A6);
  static const Color white = Colors.white;
}

/// Адрес сервера с ИИ (backend/worker.js, без «/» на конце). Пока пусто — ИИ выключен.
const String kAiBaseUrl = 'https://still-resonance-ad71.germanva2205.workers.dev';

const int kBonusKcal = 150; // бонус за шаги, ккал
const int kWaterGoal = 8; // стаканов в день
const int kVitaminGoal = 2; // приёма витаминов в день
const int kWarmupGoal = 1; // разминка в день

const BoxDecoration kBackground = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFE8F5F0), Color(0xFFFFF0EB)],
  ),
);

// ───────────────────────── Настройки пользователя ─────────────────────────

enum Goal { lose, rhythm, energy }

String goalLabel(Goal g) {
  switch (g) {
    case Goal.lose:
      return 'Мягко похудеть';
    case Goal.rhythm:
      return 'Наладить режим';
    case Goal.energy:
      return 'Больше энергии';
  }
}

/// Привычка дня для сада.
class GardenHabit {
  final String label;
  final String detail;
  final bool done;
  const GardenHabit(this.label, this.detail, this.done);
}

/// Упражнение разминки с расходом калорий.
class Exercise {
  final String name;
  final int kcal;
  const Exercise(this.name, this.kcal);

  Map<String, dynamic> toJson() => {'name': name, 'kcal': kcal};

  factory Exercise.fromJson(Map<String, dynamic> j) =>
      Exercise((j['name'] as String?) ?? '', (j['kcal'] as num?)?.toInt() ?? 0);
}

/// Встроенная база упражнений (расход примерно за 5 минут).
const List<Exercise> kExerciseBase = [
  Exercise('Приседания', 30),
  Exercise('Планка', 25),
  Exercise('Джампинг Джек', 40),
  Exercise('Растяжка', 15),
  Exercise('Отжимания', 20),
  Exercise('Выпады', 28),
  Exercise('Бег на месте', 35),
];

/// Приём витамина, лекарства или добавки в заданное время.
class IntakeSlot {
  final int minute; // минуты от полуночи
  final String label;
  final bool done;
  const IntakeSlot(this.minute, this.label, {this.done = false});

  IntakeSlot copyWith({bool? done}) => IntakeSlot(minute, label, done: done ?? this.done);

  Map<String, dynamic> toJson() => {'minute': minute, 'label': label, 'done': done};

  factory IntakeSlot.fromJson(Map<String, dynamic> j) => IntakeSlot(
        (j['minute'] as num?)?.toInt() ?? 0,
        (j['label'] as String?) ?? '',
        done: (j['done'] as bool?) ?? false,
      );
}

class UserSettings {
  bool onboardingDone = false;
  String name = '';
  Goal goal = Goal.rhythm;
  bool isFemale = true;
  int age = 30;
  int heightCm = 170;
  int weightKg = 70;
  int stepsGoal = 8000;
  int lunchMin = 13 * 60; // минуты от полуночи
  int dinnerMin = 18 * 60;
  bool waterOn = true;
  bool vitaminsOn = true;
  bool warmupOn = true;
  bool checkinOn = true;
  bool stepsConnected = false; // шаги берутся из Apple Health / Health Connect
  bool aiPhotoOn = false; // можно ли отправлять фото на анализ ИИ
  bool plateAiConsent = false; // согласие на отправку фото блюд в ИИ
  bool quietOn = true;
  int quietStartMin = 22 * 60;
  int quietEndMin = 7 * 60;
  int calorieLimit = 0; // 0 = автоматически (рекомендованный ориентир)
  String logDate = ''; // день, к которому относятся калории ниже
  int lunchKcal = 0;
  int dinnerKcal = 0;
  int stepsToday = 0;
  int waterGlasses = 0;
  int vitaminDoses = 0;
  int warmups = 0;
  bool bonusClaimed = false;
  int activityLevel = 1; // 0 сидячий, 1 лёгкая, 2 умеренная, 3 высокая активность
  int healthLimit = 0; // 0 без ограничений, 1 суставы, 2 сердце
  int waterMl = 0; // выпито сегодня, мл
  int waterGoalMl = 2000;
  int waterGlassMl = 200; // размер базового стакана
  int waterCooldownMin = 30; // пауза между порциями
  int waterIntervalMin = 10; // шаг напоминаний о воде
  int waterNextAvailableMin = 0; // минута суток, с которой можно пить снова
  bool intakeRemindersOn = true;
  List<IntakeSlot> intakeSlots = [];
  List<Exercise> todayExercises = [];
  int gardenBanked = 0; // очки сада за прошлые дни
  int gardenGoodDays = 0; // дни, когда выполнено 3 привычки из 5 и больше

  /// Привычки дня. Очки не даются за калории и вес: сад растёт от заботы о себе.
  List<GardenHabit> get habits => [
        GardenHabit('Вода', '$waterMl / $waterGoalMl мл', waterMl >= waterGoalMl),
        GardenHabit(
          'Приёмы',
          '${intakeSlots.where((x) => x.done).length} / ${intakeSlots.length}',
          intakeSlots.isNotEmpty && intakeSlots.every((x) => x.done),
        ),
        GardenHabit(
          'Разминка',
          todayExercises.isNotEmpty ? '1 / 1' : '0 / 1',
          todayExercises.isNotEmpty,
        ),
        GardenHabit('Норма шагов', '$stepsToday / $stepsGoal', stepsToday >= stepsGoal),
        GardenHabit(
          'Обед и ужин записаны',
          '${(lunchKcal > 0 ? 1 : 0) + (dinnerKcal > 0 ? 1 : 0)} / 2',
          lunchKcal > 0 && dinnerKcal > 0,
        ),
      ];

  int get todayPoints => habits.where((h) => h.done).length;

  /// Все очки сада, включая сегодняшние.
  int get gardenTotal => gardenBanked + todayPoints;

  List<Meal> get meals => [
        Meal(lunchMin ~/ 60, lunchMin % 60, 'обеда'),
        Meal(dinnerMin ~/ 60, dinnerMin % 60, 'ужина'),
      ];

  /// Ориентир дневной калорийности (формула Миффлина — Сан-Жеора,
  /// лёгкая активность). Ниже безопасного минимума не опускается.
  int get calorieTarget {
    final bmr = 10 * weightKg + 6.25 * heightCm - 5 * age + (isFemale ? -161 : 5);
    var kcal = bmr * const [1.2, 1.375, 1.55, 1.725][activityLevel];
    if (goal == Goal.lose) kcal *= 0.85;
    final minimum = isFemale ? 1200 : 1500;
    final rounded = ((kcal / 50).round()) * 50;
    return max(minimum, rounded);
  }

  /// Оценка калорий, потраченных на ходьбу сверх покоя:
  /// длина шага ≈ 0,415 роста, расход ≈ 0,5 ккал на кг веса на километр.
  int kcalForSteps(int steps) {
    final stepKm = 0.415 * heightCm / 100000;
    final kcal = 0.5 * weightKg * steps * stepKm;
    return (kcal / 5).round() * 5;
  }

  /// Попадает ли время (минуты от полуночи) в тихие часы.
  bool isQuiet(int minute) {
    if (!quietOn) return false;
    if (quietStartMin <= quietEndMin) {
      return minute >= quietStartMin && minute < quietEndMin;
    }
    return minute >= quietStartMin || minute < quietEndMin;
  }

  /// Нижняя граница, ниже которой лимит поставить нельзя.
  int get minLimit => isFemale ? 1200 : 1500;

  /// Лимит на день: выбранный пользователем или рекомендованный.
  int get baseLimit =>
      calorieLimit > 0 ? max(calorieLimit, minLimit) : calorieTarget;

  /// Лимит на сегодня: норма плюс активность (шаги и разминка).
  int get effectiveLimit => dynamicLimit;

  /// Шагов для бонуса: личная норма плюс 2000.
  int get bonusSteps => stepsGoal + 2000;

  int get eatenKcal => lunchKcal + dinnerKcal;

  /// Калории от шагов за сегодня.
  int get stepsKcal => kcalForSteps(stepsToday);

  /// Калории от выполненных упражнений разминки.
  int get exerciseKcal => todayExercises.fold(0, (a, e) => a + e.kcal);

  /// Вся сегодняшняя активность, ккал.
  int get activityBurned => stepsKcal + exerciseKcal;

  /// Живой лимит: норма плюс активность.
  int get dynamicLimit => baseLimit + activityBurned;

  /// Съедено минус живой лимит: меньше нуля — дефицит, больше — профицит.
  int get netBalance => eatenKcal - dynamicLimit;

  /// Три совета на старт по данным анкеты.
  List<String> get lifestyleTips => [
        goal == Goal.lose
            ? 'Мягкий дефицит: держитесь около $baseLimit ккал в день и не урезайте ниже $minLimit.'
            : 'Ориентир по калориям — около $baseLimit ккал в день.',
        activityLevel <= 1
            ? 'Начните с $stepsGoal шагов в день: прогулка после еды помогает и пищеварению.'
            : 'Вы активны, поэтому не забывайте про шаги ($stepsGoal в день) и восстановление.',
        healthLimit == 1
            ? 'Для разминки выбирайте упражнения с малой нагрузкой на суставы: растяжка, планка.'
            : healthLimit == 2
                ? 'При проблемах с сердцем наращивайте нагрузку плавно и согласуйте её с врачом.'
                : 'Пейте воду в течение дня: цель — $waterGoalMl мл.',
      ];
}

class SettingsController extends ChangeNotifier {
  SettingsController(this._prefs, this.docsPath) {
    _load();
    unawaited(_save());
  }

  final SharedPreferences _prefs;

  /// Папка приложения, где лежат фото чек-апов.
  final String docsPath;
  UserSettings s = UserSettings();
  List<CheckIn> checkIns = [];
  String insightText = '';
  Timer? _remindTimer;
  bool _syncing = false;

  Future<void> setInsight(String text) async {
    insightText = text;
    await _prefs.setString('insightText', text);
    notifyListeners();
  }

  /// Подтягивает шаги за сегодня из Apple Health / Health Connect.
  Future<void> syncSteps() async {
    if (!s.stepsConnected || _syncing) return;
    _syncing = true;
    try {
      final v = await StepService.instance.todaySteps();
      if (v != null && v != s.stepsToday) {
        await update((x) => x.stepsToday = v);
      }
    } finally {
      _syncing = false;
    }
  }

  String photoPath(CheckIn c) => '$docsPath/${c.fileName}';

  void _loadCheckIns() {
    final raw = _prefs.getString('checkIns');
    if (raw == null) return;
    try {
      checkIns = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(CheckIn.fromJson)
          .where((c) => c.fileName.isNotEmpty)
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));
    } catch (_) {
      checkIns = [];
    }
  }

  Future<void> _saveCheckIns() async {
    await _prefs.setString('checkIns', jsonEncode(checkIns.map((c) => c.toJson()).toList()));
  }

  Future<void> _deletePhoto(CheckIn c) async {
    try {
      final f = File(photoPath(c));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<void> addCheckIn(CheckIn c) async {
    checkIns.add(c);
    checkIns.sort((a, b) => a.date.compareTo(b.date));
    await _saveCheckIns();
    // Свежий вес сразу идёт в расчёт ориентира по калориям.
    await update((x) => x.weightKg = max(40, min(160, (c.weightG / 1000).round())));
  }

  Future<void> deleteCheckIn(CheckIn c) async {
    checkIns.remove(c);
    await _deletePhoto(c);
    await _saveCheckIns();
    notifyListeners();
  }

  void _scheduleReminders() {
    _remindTimer?.cancel();
    _remindTimer = Timer(const Duration(seconds: 2), () {
      NotificationService.instance.reschedule(s);
    });
  }

  void _load() {
    final d = UserSettings();
    s.onboardingDone = _prefs.getBool('onboardingDone') ?? d.onboardingDone;
    s.name = _prefs.getString('name') ?? d.name;
    final goalIndex = _prefs.getInt('goal') ?? d.goal.index;
    s.goal = Goal.values[max(0, min(Goal.values.length - 1, goalIndex))];
    s.isFemale = _prefs.getBool('isFemale') ?? d.isFemale;
    s.age = _prefs.getInt('age') ?? d.age;
    s.heightCm = _prefs.getInt('heightCm') ?? d.heightCm;
    s.weightKg = _prefs.getInt('weightKg') ?? d.weightKg;
    s.stepsGoal = _prefs.getInt('stepsGoal') ?? d.stepsGoal;
    s.lunchMin = _prefs.getInt('lunchMin') ?? d.lunchMin;
    s.dinnerMin = _prefs.getInt('dinnerMin') ?? d.dinnerMin;
    s.waterOn = _prefs.getBool('waterOn') ?? d.waterOn;
    s.vitaminsOn = _prefs.getBool('vitaminsOn') ?? d.vitaminsOn;
    s.warmupOn = _prefs.getBool('warmupOn') ?? d.warmupOn;
    s.checkinOn = _prefs.getBool('checkinOn') ?? d.checkinOn;
    s.stepsConnected = _prefs.getBool('stepsConnected') ?? d.stepsConnected;
    s.aiPhotoOn = _prefs.getBool('aiPhotoOn') ?? d.aiPhotoOn;
    s.plateAiConsent = _prefs.getBool('plateAiConsent') ?? d.plateAiConsent;
    s.quietOn = _prefs.getBool('quietOn') ?? d.quietOn;
    s.quietStartMin = _prefs.getInt('quietStartMin') ?? d.quietStartMin;
    s.quietEndMin = _prefs.getInt('quietEndMin') ?? d.quietEndMin;
    s.calorieLimit = _prefs.getInt('calorieLimit') ?? d.calorieLimit;
    s.logDate = _prefs.getString('logDate') ?? '';
    s.lunchKcal = _prefs.getInt('lunchKcal') ?? 0;
    s.dinnerKcal = _prefs.getInt('dinnerKcal') ?? 0;
    s.stepsToday = _prefs.getInt('stepsToday') ?? 0;
    s.waterGlasses = _prefs.getInt('waterGlasses') ?? 0;
    s.vitaminDoses = _prefs.getInt('vitaminDoses') ?? 0;
    s.warmups = _prefs.getInt('warmups') ?? 0;
    s.bonusClaimed = _prefs.getBool('bonusClaimed') ?? false;
    s.activityLevel = max(0, min(3, _prefs.getInt('activityLevel') ?? d.activityLevel));
    s.healthLimit = max(0, min(2, _prefs.getInt('healthLimit') ?? d.healthLimit));
    s.waterMl = _prefs.getInt('waterMl') ?? 0;
    s.waterGoalMl = _prefs.getInt('waterGoalMl') ?? d.waterGoalMl;
    s.waterGlassMl = _prefs.getInt('waterGlassMl') ?? d.waterGlassMl;
    s.waterCooldownMin = _prefs.getInt('waterCooldownMin') ?? d.waterCooldownMin;
    s.waterIntervalMin = _prefs.getInt('waterIntervalMin') ?? d.waterIntervalMin;
    s.waterNextAvailableMin = _prefs.getInt('waterNextAvailableMin') ?? 0;
    s.intakeRemindersOn = _prefs.getBool('intakeRemindersOn') ?? d.intakeRemindersOn;
    s.intakeSlots = _decodeList(_prefs.getString('intakeSlots'), IntakeSlot.fromJson)
      ..sort((a, b) => a.minute.compareTo(b.minute));
    s.todayExercises = _decodeList(_prefs.getString('todayExercises'), Exercise.fromJson);
    s.gardenBanked = _prefs.getInt('gardenBanked') ?? 0;
    s.gardenGoodDays = _prefs.getInt('gardenGoodDays') ?? 0;
    _loadCheckIns();
    insightText = _prefs.getString('insightText') ?? '';
    _rolloverIfNewDay();
  }

  static List<T> _decodeList<T>(String? raw, T Function(Map<String, dynamic>) fromJson) {
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).whereType<Map<String, dynamic>>().map(fromJson).toList();
    } catch (_) {
      return [];
    }
  }

  static String _todayKey() {
    final n = DateTime.now();
    return '${n.year}-${twoDigits(n.month)}-${twoDigits(n.day)}';
  }

  /// Наступил новый день — калории приёмов пищи обнуляются.
  bool _rolloverIfNewDay() {
    final today = _todayKey();
    if (s.logDate == today) return false;
    if (s.logDate.isNotEmpty) {
      final points = s.todayPoints; // очки уходящего дня
      s.gardenBanked += points;
      if (points >= 3) s.gardenGoodDays += 1;
    }
    s.logDate = today;
    s.lunchKcal = 0;
    s.dinnerKcal = 0;
    s.stepsToday = 0;
    s.waterGlasses = 0;
    s.vitaminDoses = 0;
    s.warmups = 0;
    s.bonusClaimed = false;
    s.waterMl = 0;
    s.waterNextAvailableMin = 0;
    s.intakeSlots = [for (final x in s.intakeSlots) x.copyWith(done: false)];
    s.todayExercises = [];
    return true;
  }

  Future<void> checkNewDay() async {
    if (_rolloverIfNewDay()) {
      notifyListeners();
      await _save();
    }
  }

  Future<void> _save() async {
    await _prefs.setBool('onboardingDone', s.onboardingDone);
    await _prefs.setString('name', s.name);
    await _prefs.setInt('goal', s.goal.index);
    await _prefs.setBool('isFemale', s.isFemale);
    await _prefs.setInt('age', s.age);
    await _prefs.setInt('heightCm', s.heightCm);
    await _prefs.setInt('weightKg', s.weightKg);
    await _prefs.setInt('stepsGoal', s.stepsGoal);
    await _prefs.setInt('lunchMin', s.lunchMin);
    await _prefs.setInt('dinnerMin', s.dinnerMin);
    await _prefs.setBool('waterOn', s.waterOn);
    await _prefs.setBool('vitaminsOn', s.vitaminsOn);
    await _prefs.setBool('warmupOn', s.warmupOn);
    await _prefs.setBool('checkinOn', s.checkinOn);
    await _prefs.setBool('stepsConnected', s.stepsConnected);
    await _prefs.setBool('aiPhotoOn', s.aiPhotoOn);
    await _prefs.setBool('plateAiConsent', s.plateAiConsent);
    await _prefs.setBool('quietOn', s.quietOn);
    await _prefs.setInt('quietStartMin', s.quietStartMin);
    await _prefs.setInt('quietEndMin', s.quietEndMin);
    await _prefs.setInt('calorieLimit', s.calorieLimit);
    await _prefs.setString('logDate', s.logDate);
    await _prefs.setInt('lunchKcal', s.lunchKcal);
    await _prefs.setInt('dinnerKcal', s.dinnerKcal);
    await _prefs.setInt('stepsToday', s.stepsToday);
    await _prefs.setInt('waterGlasses', s.waterGlasses);
    await _prefs.setInt('vitaminDoses', s.vitaminDoses);
    await _prefs.setInt('warmups', s.warmups);
    await _prefs.setBool('bonusClaimed', s.bonusClaimed);
    await _prefs.setInt('activityLevel', s.activityLevel);
    await _prefs.setInt('healthLimit', s.healthLimit);
    await _prefs.setInt('waterMl', s.waterMl);
    await _prefs.setInt('waterGoalMl', s.waterGoalMl);
    await _prefs.setInt('waterGlassMl', s.waterGlassMl);
    await _prefs.setInt('waterCooldownMin', s.waterCooldownMin);
    await _prefs.setInt('waterIntervalMin', s.waterIntervalMin);
    await _prefs.setInt('waterNextAvailableMin', s.waterNextAvailableMin);
    await _prefs.setBool('intakeRemindersOn', s.intakeRemindersOn);
    await _prefs.setString('intakeSlots', jsonEncode(s.intakeSlots.map((x) => x.toJson()).toList()));
    await _prefs.setString('todayExercises', jsonEncode(s.todayExercises.map((x) => x.toJson()).toList()));
    await _prefs.setInt('gardenBanked', s.gardenBanked);
    await _prefs.setInt('gardenGoodDays', s.gardenGoodDays);
  }

  Future<void> update(void Function(UserSettings s) change) async {
    _rolloverIfNewDay();
    change(s);
    notifyListeners();
    _scheduleReminders();
    await _save();
  }

  Future<void> reset() async {
    for (final c in checkIns) {
      await _deletePhoto(c);
    }
    checkIns = [];
    _remindTimer?.cancel();
    await NotificationService.instance.cancelAll();
    await _prefs.clear();
    insightText = '';
    s = UserSettings();
    notifyListeners();
  }
}

// ───────────────────────── Логика интервалов ─────────────────────────

class Meal {
  final int hour;
  final int minute;
  final String genitive; // «до …» (обеда, ужина)
  const Meal(this.hour, this.minute, this.genitive);

  String get time => fmtMinutes(hour * 60 + minute);
}

class FastingStatus {
  final Duration remaining;
  final double progress;
  final Meal nextMeal;
  final bool isEatingWindow;

  const FastingStatus({
    required this.remaining,
    required this.progress,
    required this.nextMeal,
    required this.isEatingWindow,
  });

  static FastingStatus compute(DateTime now, List<Meal> meals) {
    final points = <MapEntry<DateTime, Meal>>[];
    for (var d = -1; d <= 1; d++) {
      for (final m in meals) {
        points.add(MapEntry(
          DateTime(now.year, now.month, now.day + d, m.hour, m.minute),
          m,
        ));
      }
    }
    points.sort((a, b) => a.key.compareTo(b.key));

    final next = points.firstWhere((p) => p.key.isAfter(now));
    final prev = points.lastWhere((p) => !p.key.isAfter(now));

    final total = next.key.difference(prev.key);
    final elapsed = now.difference(prev.key);

    return FastingStatus(
      remaining: next.key.difference(now),
      progress: (elapsed.inSeconds / total.inSeconds).clamp(0.0, 1.0),
      nextMeal: next.value,
      isEatingWindow: elapsed < const Duration(minutes: 45),
    );
  }
}

String twoDigits(int n) => n.toString().padLeft(2, '0');

String fmtMinutes(int m) => '${twoDigits(m ~/ 60)}:${twoDigits(m % 60)}';

String formatDuration(Duration d) {
  final totalMinutes = (d.inSeconds + 59) ~/ 60;
  final h = totalMinutes ~/ 60;
  final m = totalMinutes % 60;
  if (h == 0) return '$m мин';
  return '$h ч $m мин';
}

String greetingFor(DateTime now) {
  final h = now.hour;
  if (h >= 5 && h < 12) return 'Доброе утро';
  if (h >= 12 && h < 18) return 'Добрый день';
  if (h >= 18 && h < 23) return 'Добрый вечер';
  return 'Доброй ночи';
}

// ───────────────────────── Приложение ─────────────────────────

class InterLightApp extends StatelessWidget {
  final SettingsController controller;
  const InterLightApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'InterLight',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: AppColors.mint),
        useMaterial3: true,
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (context, _) => controller.s.onboardingDone
            ? MainDashboard(controller: controller)
            : OnboardingFlow(controller: controller),
      ),
    );
  }
}

// ───────────────────────── Общие виджеты форм ─────────────────────────

class SectionCard extends StatelessWidget {
  final String title;
  final Widget child;
  const SectionCard({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 15,
            offset: const Offset(0, 5),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppColors.darkGraphite,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class ChoiceWrap<T> extends StatelessWidget {
  final List<T> options;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onSelected;

  const ChoiceWrap({
    super.key,
    required this.options,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final o in options)
          ChoiceChip(
            label: Text(labelOf(o)),
            selected: o == selected,
            selectedColor: AppColors.mint.withValues(alpha: 0.35),
            onSelected: (_) => onSelected(o),
          ),
      ],
    );
  }
}

class SliderRow extends StatelessWidget {
  final String label;
  final int value;
  final int min;
  final int max;
  final String unit;
  final ValueChanged<int> onChanged;

  const SliderRow({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: AppColors.fogGray, fontSize: 15)),
            Text(
              '$value $unit',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.darkGraphite,
                fontSize: 15,
              ),
            ),
          ],
        ),
        Slider(
          value: value.toDouble().clamp(min.toDouble(), max.toDouble()),
          min: min.toDouble(),
          max: max.toDouble(),
          divisions: max - min,
          activeColor: AppColors.mint,
          onChanged: (v) => onChanged(v.round()),
        ),
      ],
    );
  }
}

class TimeTile extends StatelessWidget {
  final String label;
  final int minutes;
  final VoidCallback onTap;

  const TimeTile({super.key, required this.label, required this.minutes, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(label, style: const TextStyle(color: AppColors.darkGraphite)),
      trailing: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.mint.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          fmtMinutes(minutes),
          style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.darkGraphite),
        ),
      ),
      onTap: onTap,
    );
  }
}

Future<int?> pickTime(BuildContext context, int minutes) async {
  final t = await showTimePicker(
    context: context,
    initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
  );
  return t == null ? null : t.hour * 60 + t.minute;
}

Future<void> editMeal(BuildContext context, SettingsController c, {required bool lunch}) async {
  final picked = await pickTime(context, lunch ? c.s.lunchMin : c.s.dinnerMin);
  if (picked == null || !context.mounted) return;
  final lunchMin = lunch ? picked : c.s.lunchMin;
  final dinnerMin = lunch ? c.s.dinnerMin : picked;
  if (dinnerMin - lunchMin < 120) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Между обедом и ужином должно быть минимум 2 часа')),
    );
    return;
  }
  await c.update((s) {
    s.lunchMin = lunchMin;
    s.dinnerMin = dinnerMin;
  });
}

// ───────────────────────── Блоки полей (для онбординга и настроек) ─────────────────────────

class PersonalFields extends StatefulWidget {
  final SettingsController controller;
  const PersonalFields({super.key, required this.controller});

  @override
  State<PersonalFields> createState() => _PersonalFieldsState();
}

class _PersonalFieldsState extends State<PersonalFields> {
  late final TextEditingController _name =
      TextEditingController(text: widget.controller.s.name);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Как к вам обращаться?',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => c.update((s) => s.name = v),
          ),
          const SizedBox(height: 16),
          const Text('Ваша цель', style: TextStyle(color: AppColors.fogGray)),
          const SizedBox(height: 8),
          ChoiceWrap<Goal>(
            options: Goal.values,
            selected: c.s.goal,
            labelOf: goalLabel,
            onSelected: (g) => c.update((s) => s.goal = g),
          ),
        ],
      ),
    );
  }
}

class BodyFields extends StatelessWidget {
  final SettingsController controller;
  const BodyFields({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChoiceWrap<bool>(
            options: const [true, false],
            selected: c.s.isFemale,
            labelOf: (f) => f ? 'Женщина' : 'Мужчина',
            onSelected: (v) => c.update((s) => s.isFemale = v),
          ),
          const SizedBox(height: 8),
          SliderRow(
            label: 'Возраст',
            value: c.s.age,
            min: 18,
            max: 80,
            unit: 'лет',
            onChanged: (v) => c.update((s) => s.age = v),
          ),
          SliderRow(
            label: 'Рост',
            value: c.s.heightCm,
            min: 140,
            max: 210,
            unit: 'см',
            onChanged: (v) => c.update((s) => s.heightCm = v),
          ),
          SliderRow(
            label: 'Вес',
            value: c.s.weightKg,
            min: 40,
            max: 160,
            unit: 'кг',
            onChanged: (v) => c.update((s) => s.weightKg = v),
          ),
        ],
      ),
    );
  }
}

class CalorieCard extends StatelessWidget {
  final SettingsController controller;
  const CalorieCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.peach,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '≈ ${controller.s.calorieTarget} ккал в день',
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: AppColors.darkGraphite,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Это ориентир, а не предписание. Если есть вопросы к питанию, '
              'обсудите их с врачом.',
              style: TextStyle(fontSize: 13, color: AppColors.darkGraphite),
            ),
          ],
        ),
      ),
    );
  }
}

class StepsGoalFields extends StatelessWidget {
  final SettingsController controller;
  const StepsGoalFields({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => ChoiceWrap<int>(
        options: const [5000, 6000, 8000, 10000],
        selected: c.s.stepsGoal,
        labelOf: (v) => '$v шагов',
        onSelected: (v) => c.update((s) => s.stepsGoal = v),
      ),
    );
  }
}

class MealFields extends StatelessWidget {
  final SettingsController controller;
  const MealFields({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        children: [
          TimeTile(
            label: 'Обед',
            minutes: c.s.lunchMin,
            onTap: () => editMeal(context, c, lunch: true),
          ),
          TimeTile(
            label: 'Ужин',
            minutes: c.s.dinnerMin,
            onTap: () => editMeal(context, c, lunch: false),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Шаги: Health Connect / Apple Health ─────────────────────────

class StepService {
  StepService._();
  static final StepService instance = StepService._();

  final hl.Health _health = hl.Health();
  bool _configured = false;

  /// Причина последней неудачи, показывается пользователю.
  String? lastProblem;

  Future<void> _configure() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  Future<bool> connect() async {
    lastProblem = null;
    try {
      await _configure();
      if (Platform.isAndroid) {
        await ph.Permission.activityRecognition.request();
      }
      final ok = await _health.requestAuthorization(
        [hl.HealthDataType.STEPS],
        permissions: [hl.HealthDataAccess.READ],
      );
      if (!ok) {
        lastProblem = Platform.isIOS
            ? 'Доступ к шагам не разрешён. Его можно включить в приложении «Здоровье» '
                'в разделе «Данные», затем «Источники».'
            : 'Доступ к шагам не разрешён. Проверьте, что в Health Connect включено '
                'разрешение для InterLight.';
        await _offerInstallIfNeeded();
      }
      return ok;
    } catch (_) {
      lastProblem = 'Не удалось подключить шагомер.';
      await _offerInstallIfNeeded();
      return false;
    }
  }

  /// На Android до 14 версии Health Connect ставится отдельным приложением.
  Future<void> _offerInstallIfNeeded() async {
    if (!Platform.isAndroid) return;
    try {
      final status = await _health.getHealthConnectSdkStatus();
      final text = status.toString().toLowerCase();
      if (text.contains('unavailable')) {
        lastProblem = 'Нужно установить или обновить Health Connect. '
            'Открываю магазин приложений.';
        await _health.installHealthConnect();
      }
    } catch (_) {}
  }

  Future<int?> todaySteps() async {
    try {
      await _configure();
      final now = DateTime.now();
      return await _health.getTotalStepsInInterval(
        DateTime(now.year, now.month, now.day),
        now,
      );
    } catch (_) {
      return null;
    }
  }
}

class StepsCard extends StatelessWidget {
  final SettingsController controller;
  const StepsCard({super.key, required this.controller});

  Future<void> _connect(BuildContext context) async {
    final ok = await StepService.instance.connect();
    if (!context.mounted) return;
    if (ok) {
      await controller.update((s) => s.stepsConnected = true);
      await controller.syncSteps();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(StepService.instance.lastProblem ?? 'Не удалось подключить шагомер.')),
      );
    }
  }

  void _showInfo(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Как считаются калории'),
        content: const Text(
          'Это оценка калорий, которые вы тратите при ходьбе сверх покоя. '
          'Она зависит от вашего веса и роста: длина шага берётся от роста, '
          'а расход примерно 0,5 ккал на килограмм веса на километр пути. '
          'Реальные значения могут заметно отличаться, поэтому считайте это подсказкой, '
          'а не точным измерением.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Понятно')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.s;
        final steps = s.stepsToday;
        final goal = s.stepsGoal;
        final bonus = s.bonusSteps;
        final progress = (steps / bonus).clamp(0.0, 1.0);
        final status = steps >= bonus
            ? 'Бонус открыт 🍫'
            : steps >= goal
                ? 'До бонуса: ${bonus - steps}'
                : 'До нормы: ${goal - steps}';
        final source = Platform.isIOS ? 'Apple Health' : 'Health Connect';

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.directions_walk, color: AppColors.mint, size: 24),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Моя активность сегодня',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppColors.darkGraphite,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Как считаются калории',
                    icon: const Icon(Icons.info_outline, color: AppColors.fogGray),
                    onPressed: () => _showInfo(context),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '$steps',
                    style: const TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.bold,
                      color: AppColors.darkGraphite,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text('шагов', style: TextStyle(fontSize: 15, color: AppColors.fogGray)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppColors.peach,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '≈ ${s.kcalForSteps(steps)} ккал',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppColors.darkGraphite,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 12,
                child: LayoutBuilder(
                  builder: (context, cons) => Stack(
                    children: [
                      Positioned.fill(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: progress,
                            backgroundColor: Colors.grey[200],
                            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.mint),
                          ),
                        ),
                      ),
                      // Отметка нормы на шкале.
                      Positioned(
                        left: cons.maxWidth * goal / bonus - 1,
                        top: 0,
                        bottom: 0,
                        child: Container(width: 2, color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                status,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.darkGraphite,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Норма: $goal шагов · ≈ ${s.kcalForSteps(goal)} ккал',
                style: const TextStyle(fontSize: 13, color: AppColors.fogGray),
              ),
              Text(
                'Бонус: $bonus шагов · ≈ ${s.kcalForSteps(bonus)} ккал',
                style: const TextStyle(fontSize: 13, color: AppColors.fogGray),
              ),
              const SizedBox(height: 6),
              if (s.stepsConnected)
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Шаги из $source, обновляются сами.',
                        style: const TextStyle(fontSize: 12, color: AppColors.fogGray),
                      ),
                    ),
                    TextButton(
                      onPressed: () => c.update((x) => x.stepsConnected = false),
                      child: const Text('Отключить'),
                    ),
                  ],
                )
              else
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        style: TextButton.styleFrom(alignment: Alignment.centerLeft),
                        icon: const Icon(Icons.sync),
                        label: Text('Подключить $source'),
                        onPressed: () => _connect(context),
                      ),
                    ),
                    IconButton(
                      tooltip: '+1000 шагов (вручную)',
                      icon: const Icon(Icons.add_circle_outline, color: AppColors.mint),
                      onPressed: () => c.update((x) => x.stepsToday += 1000),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── Наблюдение ИИ ─────────────────────────

/// Адрес сервера для наблюдений ИИ (маршрут /insight из recipe_backend.js).
/// Пока пусто — показывается простое наблюдение по вашим данным без ИИ и без отправки фото.
const String kInsightApiUrl = kAiBaseUrl == '' ? '' : '$kAiBaseUrl/insight';

String localInsight(List<CheckIn> list) {
  if (list.isEmpty) return '';
  if (list.length == 1) {
    return 'Первый чек-ап сохранён: это ваша точка отсчёта. На следующей неделе '
        'сравним и посмотрим на динамику.';
  }
  final first = list.first;
  final last = list.last;
  final days = max(1, last.date.difference(first.date).inDays);
  final diff = last.weightG - first.weightG;
  final weeks = max(days / 7, 1.0);
  final weeklyPct = (diff.abs() / first.weightG * 100) / weeks;

  if (diff.abs() <= 300) {
    return 'За $days дн. вес почти не изменился (${fmtKg(last.weightG)} кг). '
        'Стабильность тоже результат: режим работает, а вы продолжаете делать чек-апы.';
  }
  if (diff < 0) {
    if (weeklyPct > 1.0) {
      return 'За $days дн. вес снизился на ${fmtKg(-diff)} кг, и темп довольно быстрый. '
          'Не торопите процесс: если чувствуете слабость или усталость, '
          'обсудите питание с врачом.';
    }
    return 'За $days дн. вес снизился на ${fmtKg(-diff)} кг. Спокойный темп — '
        'как раз то, что нужно. Продолжайте в своём ритме.';
  }
  return 'За $days дн. вес вырос на ${fmtKg(diff)} кг. Недельные колебания нормальны: '
      'вода, сон, соль. Смотрите на тенденцию за несколько недель, а не на одно взвешивание.';
}

Uint8List _smallJpeg(String path) {
  final decoded = img.decodeImage(File(path).readAsBytesSync());
  if (decoded == null) throw Exception('bad image');
  var picture = img.bakeOrientation(decoded);
  if (picture.width > 640) picture = img.copyResize(picture, width: 640);
  return Uint8List.fromList(img.encodeJpg(picture, quality: 75));
}

/// Уменьшение фото в отдельном потоке, чтобы не тормозить интерфейс.
Future<Uint8List> smallJpegFromFile(String path) => Isolate.run(() => _smallJpeg(path));

class InsightService {
  static Future<String> fetch(SettingsController c, {required bool withPhotos}) async {
    final list = c.checkIns;
    if (kInsightApiUrl.isEmpty) return localInsight(list);

    final recent = list.length > 12 ? list.sublist(list.length - 12) : list;
    final body = <String, dynamic>{
      'checkIns': [
        for (final e in recent) {'date': e.date.toIso8601String(), 'weightG': e.weightG},
      ],
    };
    if (withPhotos && list.length >= 2) {
      final firstPath = c.photoPath(list.first);
      final lastPath = c.photoPath(list.last);
      final first = await smallJpegFromFile(firstPath);
      final last = await smallJpegFromFile(lastPath);
      body['photos'] = {'first': base64Encode(first), 'last': base64Encode(last)};
    }

    final res = await http
        .post(
          Uri.parse(kInsightApiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final text = (data['insight'] ?? '').toString().trim();
    if (text.isEmpty) throw Exception('empty');
    return text;
  }
}

// ───────────────────────── Мини-циферблаты дня ─────────────────────────

class MiniDial extends StatelessWidget {
  final String label;
  final IconData icon;
  final int value;
  final int goal;
  final String? valueText;
  final bool isLocked;
  final String? lockText;
  final VoidCallback onAdd;
  final VoidCallback? onUndo;

  const MiniDial({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.goal,
    required this.onAdd,
    this.onUndo,
    this.valueText,
    this.isLocked = false,
    this.lockText,
  });

  @override
  Widget build(BuildContext context) {
    final color = isLocked ? AppColors.fogGray : AppColors.mint;
    return Material(
      color: AppColors.white,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onAdd,
        onLongPress: onUndo,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 52,
                height: 52,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox.expand(
                      child: CircularProgressIndicator(
                        value: goal <= 0 ? 0.0 : (value / goal).clamp(0.0, 1.0),
                        strokeWidth: 5,
                        backgroundColor: Colors.grey[200],
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                    Icon(icon, size: 20, color: color),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(fontSize: 12, color: AppColors.fogGray)),
              Text(
                isLocked && lockText != null ? lockText! : (valueText ?? '$value / $goal'),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: AppColors.darkGraphite,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _hhmm(int minute) => '${twoDigits(minute ~/ 60)}:${twoDigits(minute % 60)}';

class DailyTrackers extends StatefulWidget {
  final SettingsController controller;
  const DailyTrackers({super.key, required this.controller});

  @override
  State<DailyTrackers> createState() => _DailyTrackersState();
}

class _DailyTrackersState extends State<DailyTrackers> {
  Timer? _tick;

  SettingsController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _waterLeftSec() > 0) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Сколько секунд осталось до следующей порции воды.
  int _waterLeftSec() {
    final n = DateTime.now();
    final nowSec = n.hour * 3600 + n.minute * 60 + n.second;
    return max(0, c.s.waterNextAvailableMin * 60 - nowSec);
  }

  String _mmss(int sec) => '${twoDigits(sec ~/ 60)}:${twoDigits(sec % 60)}';

  void _addWater(int ml) {
    final n = DateTime.now();
    final next = min(1439, n.hour * 60 + n.minute + c.s.waterCooldownMin);
    c.update((x) {
      x.waterMl += ml;
      x.waterNextAvailableMin = next;
    });
  }

  void _undoWater() {
    c.update((x) {
      x.waterMl = max(0, x.waterMl - x.waterGlassMl);
      x.waterNextAvailableMin = 0;
    });
  }

  Future<void> _waterSheet() async {
    if (_waterLeftSec() > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Следующая порция через ${_mmss(_waterLeftSec())}')),
      );
      return;
    }
    final sizes = <(String, int)>[
      ('Стакан', c.s.waterGlassMl),
      ('Кружка', 300),
      ('Бутылка', 500),
    ];
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in sizes)
              ListTile(
                leading: const Icon(Icons.water_drop_outlined, color: AppColors.mint),
                title: Text('${o.$1} · ${o.$2} мл'),
                onTap: () {
                  Navigator.pop(ctx);
                  _addWater(o.$2);
                },
              ),
            ListTile(
              leading: const Icon(Icons.undo),
              title: Text('Отменить последнюю порцию (−${c.s.waterGlassMl} мл)'),
              onTap: () {
                Navigator.pop(ctx);
                _undoWater();
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Отмена'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addSlot() async {
    var time = const TimeOfDay(hour: 9, minute: 0);
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Новый приём'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                decoration: const InputDecoration(hintText: 'Например, витамин D'),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.schedule),
                label: Text(_hhmm(time.hour * 60 + time.minute)),
                onPressed: () async {
                  final t = await showTimePicker(context: ctx, initialTime: time);
                  if (t != null) setD(() => time = t);
                },
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
          ],
        ),
      ),
    );
    final label = ctrl.text.trim();
    ctrl.dispose();
    if (ok != true) return;
    await c.update((x) {
      x.intakeSlots = [
        ...x.intakeSlots,
        IntakeSlot(time.hour * 60 + time.minute, label.isEmpty ? 'Приём' : label),
      ]..sort((a, b) => a.minute.compareTo(b.minute));
    });
  }

  Future<void> _intakeSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ListenableBuilder(
          listenable: c,
          builder: (ctx, _) {
            final slots = c.s.intakeSlots;
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
              child: ListView(
                shrinkWrap: true,
                children: [
                  const ListTile(
                    title: Text('Приёмы на сегодня', style: TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Смахните вправо, чтобы удалить.'),
                  ),
                  for (var i = 0; i < slots.length; i++)
                    Dismissible(
                      key: ValueKey('${slots[i].minute}-${slots[i].label}-$i'),
                      direction: DismissDirection.startToEnd,
                      background: Container(
                        color: AppColors.peach,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.only(left: 20),
                        child: const Icon(Icons.delete_outline),
                      ),
                      onDismissed: (_) => c.update((x) => x.intakeSlots = [
                            for (var j = 0; j < x.intakeSlots.length; j++)
                              if (j != i) x.intakeSlots[j],
                          ]),
                      child: CheckboxListTile(
                        activeColor: AppColors.mint,
                        value: slots[i].done,
                        title: Text(
                          slots[i].label,
                          style: TextStyle(
                            decoration: slots[i].done ? TextDecoration.lineThrough : null,
                          ),
                        ),
                        subtitle: Text(_hhmm(slots[i].minute)),
                        onChanged: (v) => c.update((x) => x.intakeSlots = [
                              for (var j = 0; j < x.intakeSlots.length; j++)
                                j == i ? x.intakeSlots[j].copyWith(done: v ?? false) : x.intakeSlots[j],
                            ]),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add, color: AppColors.mint),
                    title: const Text('Добавить приём'),
                    onTap: _addSlot,
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _customExercise() async {
    final nameCtrl = TextEditingController();
    final kcalCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Своё упражнение'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(hintText: 'Название')),
            TextField(
              controller: kcalCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'Ккал'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Добавить')),
        ],
      ),
    );
    final name = nameCtrl.text.trim();
    final kcal = int.tryParse(kcalCtrl.text.trim()) ?? 0;
    nameCtrl.dispose();
    kcalCtrl.dispose();
    if (ok != true || name.isEmpty || kcal <= 0) return;
    await c.update((x) => x.todayExercises = [...x.todayExercises, Exercise(name, min(kcal, 2000))]);
  }

  Future<void> _exerciseSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('Разминка (≈5 минут)', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
              for (final e in kExerciseBase)
                ListTile(
                  leading: const Icon(Icons.directions_run, color: AppColors.mint),
                  title: Text(e.name),
                  trailing: Text('${e.kcal} ккал'),
                  onTap: () {
                    Navigator.pop(ctx);
                    c.update((x) => x.todayExercises = [...x.todayExercises, e]);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Своё упражнение'),
                onTap: () {
                  Navigator.pop(ctx);
                  _customExercise();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.s;
        final left = _waterLeftSec();
        final doneSlots = s.intakeSlots.where((x) => x.done).length;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: MiniDial(
                    label: 'Вода, мл',
                    icon: Icons.water_drop_outlined,
                    value: s.waterMl,
                    goal: s.waterGoalMl,
                    valueText: '${s.waterMl}/${s.waterGoalMl}',
                    isLocked: left > 0,
                    lockText: '⏳ ${_mmss(left)}',
                    onAdd: _waterSheet,
                    onUndo: _undoWater,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MiniDial(
                    label: 'Приёмы',
                    icon: Icons.medication_outlined,
                    value: doneSlots,
                    goal: s.intakeSlots.length,
                    valueText: s.intakeSlots.isEmpty ? 'добавить' : '$doneSlots / ${s.intakeSlots.length}',
                    onAdd: _intakeSheet,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: MiniDial(
                    label: 'Разминка',
                    icon: Icons.directions_run,
                    value: s.todayExercises.isEmpty ? 0 : 1,
                    goal: 1,
                    valueText: '${s.exerciseKcal} ккал',
                    onAdd: _exerciseSheet,
                    onUndo: () => c.update((x) {
                      if (x.todayExercises.isNotEmpty) {
                        x.todayExercises = x.todayExercises.sublist(0, x.todayExercises.length - 1);
                      }
                    }),
                  ),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.only(top: 6, left: 4),
              child: Text(
                'Нажмите, чтобы отметить; у воды и разминки удерживайте, чтобы отменить последнее.',
                style: TextStyle(fontSize: 12, color: AppColors.fogGray),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Калории ─────────────────────────

/// Лимит калорий в день (для настроек).
class CalorieLimitFields extends StatelessWidget {
  final SettingsController controller;
  const CalorieLimitFields({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SliderRow(
            label: 'Лимит в день',
            value: c.s.baseLimit,
            min: c.s.minLimit,
            max: 3500,
            unit: 'ккал',
            onChanged: (v) => c.update((s) => s.calorieLimit = (v / 50).round() * 50),
          ),
          Builder(builder: (_) {
            final diff = c.s.baseLimit - c.s.calorieTarget;
            final far = diff.abs() > 300;
            return Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.peach,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Рекомендация: ${c.s.calorieTarget} ккал',
                    style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.darkGraphite),
                  ),
                  if (diff != 0)
                    Text(
                      diff < 0
                          ? 'Вы выбрали на ${-diff} ккал меньше нормы'
                          : 'Вы выбрали на $diff ккал больше нормы',
                      style: TextStyle(
                        fontSize: 13,
                        color: diff > 0 && far ? const Color(0xFFE59A7A) : AppColors.fogGray,
                      ),
                    ),
                ],
              ),
            );
          }),
          if (c.s.calorieLimit > 0)
            TextButton(
              onPressed: () => c.update((s) => s.calorieLimit = 0),
              child: Text('Вернуть рекомендованный (${c.s.calorieTarget} ккал)'),
            ),
          Text(
            'Ниже ${c.s.minLimit} ккал лимит поставить нельзя. '
            'Если нужен более строгий рацион, обсудите его с врачом.',
            style: const TextStyle(fontSize: 12, color: AppColors.fogGray),
          ),
        ],
      ),
    );
  }
}

Future<void> editKcal(BuildContext context, SettingsController c, {required bool lunch}) async {
  final current = lunch ? c.s.lunchKcal : c.s.dinnerKcal;
  final input = TextEditingController(text: current > 0 ? '$current' : '');
  final result = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(lunch ? 'Калории обеда' : 'Калории ужина'),
      content: TextField(
        controller: input,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: const InputDecoration(suffixText: 'ккал', border: OutlineInputBorder()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Отмена')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, int.tryParse(input.text.trim()) ?? 0),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
  if (result == null) return;
  final v = max(0, min(5000, result));
  await c.update((s) {
    if (lunch) {
      s.lunchKcal = v;
    } else {
      s.dinnerKcal = v;
    }
  });
}

/// Карточка «Калории сегодня» для главного экрана.
class MealKcalCard extends StatelessWidget {
  final SettingsController controller;
  const MealKcalCard({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.s;
        final limit = s.effectiveLimit;
        final eaten = s.eatenKcal;
        final base = s.baseLimit;
        final burned = s.activityBurned;
        final net = s.netBalance;
        final over = net > 0;
        final barColor = eaten > base ? const Color(0xFFE59A7A) : AppColors.mint;

        // Два приёма пищи в окне питания (интервальное голодание, например 16:8):
        // обед крупнее ужина; БЖУ по доле калорий: белки 25%, жиры 30%, углеводы 45%.
        String recommend(double share) {
          final k = (limit * share / 10).round() * 10;
          final p = (k * 0.25 / 4).round();
          final f = (k * 0.30 / 9).round();
          final cb = (k * 0.45 / 4).round();
          return 'Рекомендуем ≈ $k ккал · Б $p г · Ж $f г · У $cb г';
        }

        Widget mealRow(String label, int kcal, bool lunch) => InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => editKcal(context, c, lunch: lunch),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: const TextStyle(fontSize: 16, color: AppColors.darkGraphite)),
                          Text(
                            recommend(lunch ? 0.55 : 0.45),
                            style: const TextStyle(fontSize: 12, color: AppColors.fogGray),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      kcal > 0 ? '$kcal ккал' : 'Добавить',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: kcal > 0 ? AppColors.darkGraphite : AppColors.mint,
                      ),
                    ),
                    const SizedBox(width: 8),
                    const Icon(Icons.edit_outlined, size: 18, color: AppColors.fogGray),
                  ],
                ),
              ),
            );

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppColors.white,
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 15,
                offset: const Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(Icons.local_fire_department_outlined, color: AppColors.mint, size: 24),
                  SizedBox(width: 8),
                  Text(
                    'Баланс дня',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: AppColors.darkGraphite,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                over ? 'Профицит: +$net ккал' : 'Дефицит: $net ккал 🔥',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: over ? const Color(0xFFE59A7A) : AppColors.mint,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Цель: $base · Съедено: $eaten · Сожжено: $burned',
                style: const TextStyle(fontSize: 14, color: AppColors.fogGray),
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: LinearProgressIndicator(
                  value: (eaten / base).clamp(0.0, 1.0),
                  minHeight: 12,
                  backgroundColor: Colors.grey[200],
                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '🔥 Активность: −$burned ккал',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.darkGraphite,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '💡 Активность увеличивает ваш лимит. Можно есть больше, оставаясь в дефиците!',
                  style: TextStyle(fontSize: 12, color: AppColors.fogGray),
                ),
              ),
              const SizedBox(height: 6),
              mealRow('Обед', s.lunchKcal, true),
              const Divider(height: 1),
              mealRow('Ужин', s.dinnerKcal, false),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  icon: const Icon(Icons.photo_camera_outlined),
                  label: const Text('Посчитать по фото тарелки'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => PlateScreen(
                        controller: c,
                        lunch: s.lunchKcal == 0 || s.dinnerKcal > 0,
                      ),
                    ),
                  ),
                ),
              ),
              if (eaten > limit)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Ничего страшного: завтра новый день. Сегодня можно сделать '
                    'ужин или перекус полегче.',
                    style: TextStyle(fontSize: 13, color: AppColors.fogGray),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

// ───────────────────────── Чек-ап: данные ─────────────────────────

String fmtDate(DateTime d) => '${twoDigits(d.day)}.${twoDigits(d.month)}.${d.year}';

/// Граммы в килограммы с запятой: 68050 -> «68,05», 68500 -> «68,5», 68000 -> «68».
String fmtKg(int grams) {
  final whole = grams ~/ 1000;
  final frac = (grams % 1000) ~/ 10; // сотые доли килограмма
  if (frac == 0) return '$whole';
  if (frac % 10 == 0) return '$whole,${frac ~/ 10}';
  return '$whole,${twoDigits(frac)}';
}

class CheckIn {
  final DateTime date;
  final int weightG; // вес в граммах, шаг 50 г
  final String fileName; // имя файла в папке приложения

  const CheckIn({required this.date, required this.weightG, required this.fileName});

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'weightG': weightG,
        'file': fileName,
      };

  factory CheckIn.fromJson(Map<String, dynamic> j) => CheckIn(
        date: DateTime.tryParse((j['date'] ?? '').toString()) ?? DateTime.now(),
        weightG: (j['weightG'] as num?)?.round() ??
            (((j['weightKg'] as num?) ?? 0) * 1000).round(),
        fileName: (j['file'] ?? '').toString(),
      );
}

// ───────────────────────── Уведомления ─────────────────────────

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _permissionAsked = false;
  String _signature = '';

  static const NotificationDetails _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'reminders',
      'Напоминания',
      channelDescription: 'Вода, витамины, разминки и недельный чек-ап',
    ),
    iOS: DarwinNotificationDetails(),
  );

  Future<void> init() async {
    try {
      tzdata.initializeTimeZones();
      try {
        // В разных версиях пакета возвращается строка или объект с identifier.
        final dynamic info = await FlutterTimezone.getLocalTimezone();
        final String name = info is String ? info : (info.identifier as String);
        tz.setLocalLocation(tz.getLocation(name));
      } catch (_) {}
      await _plugin.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(
            requestAlertPermission: false,
            requestBadgePermission: false,
            requestSoundPermission: false,
          ),
        ),
      );
      _ready = true;
    } catch (_) {
      _ready = false;
    }
  }

  Future<bool> requestPermission() async {
    if (!_ready) return false;
    _permissionAsked = true;
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      final ios = _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
      final a = await android?.requestNotificationsPermission();
      final i = await ios?.requestPermissions(alert: true, badge: false, sound: true);
      return a ?? i ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> cancelAll() async {
    _signature = '';
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  /// Ближайший момент с нужным временем (и днём недели, если указан).
  tz.TZDateTime _next(int minutes, {int? weekday}) {
    final now = tz.TZDateTime.now(tz.local);
    var d = tz.TZDateTime(tz.local, now.year, now.month, now.day, minutes ~/ 60, minutes % 60);
    while (d.isBefore(now) || (weekday != null && d.weekday != weekday)) {
      d = tz.TZDateTime(tz.local, d.year, d.month, d.day + 1, minutes ~/ 60, minutes % 60);
    }
    return d;
  }

  Future<void> _daily(int id, int minutes, String title, String body) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      _next(minutes),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
    );
  }

  Future<void> _weekly(int id, int minutes, int weekday, String title, String body) {
    return _plugin.zonedSchedule(
      id,
      title,
      body,
      _next(minutes, weekday: weekday),
      _details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
    );
  }

  /// Мгновенное тестовое уведомление, чтобы проверить разрешения.
  Future<bool> showTest() async {
    if (!_ready) return false;
    try {
      if (!_permissionAsked) await requestPermission();
      await _plugin.show(999, 'InterLight', 'Уведомления работают 🌿', _details);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Пересоздаёт все напоминания по текущим настройкам.
  Future<void> reschedule(UserSettings s) async {
    if (!_ready) return;
    final sig = [
      s.onboardingDone,
      s.waterOn,
      s.vitaminsOn,
      s.warmupOn,
      s.checkinOn,
      s.quietOn,
      s.quietStartMin,
      s.quietEndMin,
      s.lunchMin,
    ].join('|');
    if (sig == _signature) return;
    _signature = sig;

    try {
      await _plugin.cancelAll();
      if (!s.onboardingDone) return;

      final any = s.waterOn || s.vitaminsOn || s.warmupOn || s.checkinOn;
      if (any && !_permissionAsked) await requestPermission();

      if (s.waterOn) {
        // 8:00, 10:00 … 22:00 — не чаще раза в 2 часа, кроме тихих часов.
        for (var i = 0; i < 8; i++) {
          final m = (8 + i * 2) * 60;
          if (s.isQuiet(m)) continue;
          await _daily(100 + i, m, 'Время для стакана воды 💧', 'Небольшая забота о себе.');
        }
      }
      if (s.vitaminsOn) {
        final times = [8 * 60 + 30, s.lunchMin];
        for (var i = 0; i < times.length; i++) {
          if (s.isQuiet(times[i])) continue;
          await _daily(200 + i, times[i], 'Напоминание о витаминах',
              'Если вы их принимаете, самое время.');
        }
      }
      if (s.warmupOn && !s.isQuiet(15 * 60)) {
        await _daily(300, 15 * 60, 'Микро-разминка на 5 минут',
            'Встаньте, потянитесь, пройдитесь по комнате.');
      }
      if (s.checkinOn) {
        final m = s.isQuiet(9 * 60) ? s.quietEndMin : 9 * 60;
        await _weekly(400, m, DateTime.sunday, 'Время недельного чек-апа 📸',
            'Утром натощак: вес и фото. Без оценок, просто отмечаем путь.');
      }
    } catch (_) {
      _signature = '';
    }
  }
}

// ───────────────────────── Вкладка «Прогресс» ─────────────────────────

class ProgressPage extends StatefulWidget {
  final SettingsController controller;
  const ProgressPage({super.key, required this.controller});

  @override
  State<ProgressPage> createState() => _ProgressPageState();
}

class _ProgressPageState extends State<ProgressPage> {
  double _pos = 0.5;
  bool _insightLoading = false;
  String? _insightError;

  Future<void> _loadInsight() async {
    final c = widget.controller;
    setState(() {
      _insightLoading = true;
      _insightError = null;
    });
    try {
      final text = await InsightService.fetch(c, withPhotos: c.s.aiPhotoOn);
      await c.setInsight(text);
    } catch (_) {
      if (mounted) {
        setState(() => _insightError =
            'Не удалось получить наблюдение. Проверьте интернет и попробуйте ещё раз.');
      }
    }
    if (mounted) setState(() => _insightLoading = false);
  }

  Future<void> _togglePhotos(bool on) async {
    final c = widget.controller;
    if (!on) {
      await c.update((s) => s.aiPhotoOn = false);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отправлять фото ИИ?'),
        content: const Text(
          'Для наблюдения первое и последнее фото будут уменьшены и отправлены на сервер '
          'приложения для анализа. Приложение не сохраняет их на сервере. '
          'Отключить это можно в любой момент.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Согласен')),
        ],
      ),
    );
    if (ok == true) await c.update((s) => s.aiPhotoOn = true);
  }

  Future<void> _openCamera() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => CheckInCameraScreen(controller: widget.controller)),
    );
  }

  Future<void> _confirmDelete(CheckIn c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Удалить запись?'),
        content: Text('Фото и вес за ${fmtDate(c.date)} будут удалены с телефона.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Удалить')),
        ],
      ),
    );
    if (ok == true) await widget.controller.deleteCheckIn(c);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final list = c.checkIns;
        final last = list.isEmpty ? null : list.last;

        String status;
        if (last == null) {
          status = 'Сделаем первое фото: это ваша точка отсчёта. Лучше утром натощак, '
              'в одной и той же одежде.';
        } else {
          final days = DateTime.now().difference(last.date).inDays;
          status = days >= 7
              ? 'Пора на чек-ап: прошло $days дн. с прошлого раза.'
              : 'Следующий чек-ап через ${7 - days} дн. Можно сделать и раньше.';
        }

        final weights = list.map((e) => e.weightG).toList();
        final diff = weights.length >= 2 ? weights.last - weights.first : 0;

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Text(
              'Прогресс',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.darkGraphite),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 16),
              child: Text(
                'Вес и фото раз в неделю, без ежедневных взвешиваний',
                style: TextStyle(fontSize: 15, color: AppColors.fogGray),
              ),
            ),
            SectionCard(
              title: 'Чек-ап недели',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(status, style: const TextStyle(fontSize: 15, color: AppColors.darkGraphite)),
                  if (last != null)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'На экране камеры вы увидите полупрозрачное фото прошлого раза: '
                        'совместите позу и расстояние.',
                        style: TextStyle(fontSize: 13, color: AppColors.fogGray),
                      ),
                    ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.mint,
                        foregroundColor: AppColors.darkGraphite,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _openCamera,
                      icon: const Icon(Icons.camera_alt_rounded),
                      label: const Text('Сделать фото недели'),
                    ),
                  ),
                ],
              ),
            ),
            if (list.length >= 2)
              SectionCard(
                title: 'До / После',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    BeforeAfterView(
                      beforePath: c.photoPath(list.first),
                      afterPath: c.photoPath(list.last),
                      pos: _pos,
                    ),
                    Slider(
                      value: _pos,
                      activeColor: AppColors.mint,
                      onChanged: (v) => setState(() => _pos = v),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(fmtDate(list.first.date),
                            style: const TextStyle(fontSize: 13, color: AppColors.fogGray)),
                        Text(fmtDate(list.last.date),
                            style: const TextStyle(fontSize: 13, color: AppColors.fogGray)),
                      ],
                    ),
                  ],
                ),
              ),
            if (list.isNotEmpty)
              SectionCard(
                title: 'Вес по неделям',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (list.length >= 2) ...[
                      SizedBox(
                        height: 100,
                        width: double.infinity,
                        child: CustomPaint(painter: WeightChartPainter(weights)),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        diff == 0
                            ? 'Вес стабилен: ${fmtKg(weights.last)} кг'
                            : 'Изменение за период: ${diff > 0 ? '+' : '−'}${fmtKg(diff.abs())} кг',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: AppColors.darkGraphite,
                        ),
                      ),
                      const SizedBox(height: 8),
                    ],
                    for (final e in list.reversed)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(10),
                              child: Image.file(
                                File(c.photoPath(e)),
                                width: 44,
                                height: 44,
                                cacheWidth: 120,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  width: 44,
                                  height: 44,
                                  color: Colors.grey[200],
                                  child: const Icon(Icons.image_not_supported_outlined, size: 20),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                fmtDate(e.date),
                                style: const TextStyle(fontSize: 15, color: AppColors.darkGraphite),
                              ),
                            ),
                            Text(
                              '${fmtKg(e.weightG)} кг',
                              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                            ),
                            IconButton(
                              tooltip: 'Удалить запись',
                              icon: const Icon(Icons.delete_outline, color: AppColors.fogGray),
                              onPressed: () => _confirmDelete(e),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            if (list.isNotEmpty)
              SectionCard(
                title: 'Наблюдение ИИ',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (c.insightText.isNotEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(14),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: AppColors.peach,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          c.insightText,
                          style: const TextStyle(
                            fontSize: 15,
                            height: 1.4,
                            color: AppColors.darkGraphite,
                          ),
                        ),
                      ),
                    if (_insightError != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          _insightError!,
                          style: const TextStyle(color: AppColors.darkGraphite),
                        ),
                      ),
                    if (kInsightApiUrl.isNotEmpty && list.length >= 2)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        activeThumbColor: AppColors.mint,
                        title: const Text('Учитывать фото'),
                        subtitle: const Text(
                          'Первое и последнее фото уменьшаются и отправляются на сервер приложения.',
                        ),
                        value: c.s.aiPhotoOn,
                        onChanged: _togglePhotos,
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.tonal(
                        onPressed: _insightLoading ? null : _loadInsight,
                        child: _insightLoading
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5),
                              )
                            : Text(c.insightText.isEmpty ? 'Получить наблюдение' : 'Обновить наблюдение'),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Это мягкая подсказка по вашим данным, а не оценка здоровья или внешности.',
                        style: TextStyle(fontSize: 12, color: AppColors.fogGray),
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              (c.s.aiPhotoOn && kInsightApiUrl.isNotEmpty)
                  ? 'Фото хранятся на вашем телефоне. Для наблюдения ИИ два снимка '
                      'отправляются на сервер приложения и не сохраняются там.'
                  : 'Фото хранятся только в приложении на вашем телефоне и никуда не отправляются.',
              style: const TextStyle(fontSize: 12, color: AppColors.fogGray),
            ),
          ],
        );
      },
    );
  }
}

class _LeftClipper extends CustomClipper<Rect> {
  final double fraction;
  _LeftClipper(this.fraction);

  @override
  Rect getClip(Size size) => Rect.fromLTWH(0, 0, size.width * fraction, size.height);

  @override
  bool shouldReclip(covariant _LeftClipper old) => old.fraction != fraction;
}

class BeforeAfterView extends StatelessWidget {
  final String beforePath;
  final String afterPath;
  final double pos;

  const BeforeAfterView({
    super.key,
    required this.beforePath,
    required this.afterPath,
    required this.pos,
  });

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 3 / 4,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(
          builder: (context, cons) => Stack(
            children: [
              Positioned.fill(child: Image.file(
                  File(afterPath),
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFFE0E6E5)),
                )),
              Positioned.fill(
                child: ClipRect(
                  clipper: _LeftClipper(pos),
                  child: Image.file(
                    File(beforePath),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFFE0E6E5)),
                  ),
                ),
              ),
              Positioned(
                left: cons.maxWidth * pos - 1.5,
                top: 0,
                bottom: 0,
                child: Container(width: 3, color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class WeightChartPainter extends CustomPainter {
  final List<int> values;
  const WeightChartPainter(this.values);

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    final lo = values.reduce(min);
    final hi = values.reduce(max);
    final span = max(1, hi - lo);
    const pad = 10.0;

    Offset pt(int i) => Offset(
          pad + (size.width - 2 * pad) * i / (values.length - 1),
          size.height - pad - (size.height - 2 * pad) * (values[i] - lo) / span,
        );

    final line = Paint()
      ..color = AppColors.mint
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeJoin = StrokeJoin.round
      ..strokeCap = StrokeCap.round;
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    canvas.drawPath(path, line);

    final dot = Paint()..color = AppColors.mint;
    for (var i = 0; i < values.length; i++) {
      canvas.drawCircle(pt(i), 5, dot);
    }
  }

  @override
  bool shouldRepaint(covariant WeightChartPainter old) {
    if (old.values.length != values.length) return true;
    for (var i = 0; i < values.length; i++) {
      if (old.values[i] != values[i]) return true;
    }
    return false;
  }
}

// ───────────────────────── Камера «Призрак» ─────────────────────────

class SilhouettePainter extends CustomPainter {
  const SilhouettePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()
      ..color = Colors.white.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    final cx = size.width / 2;
    final w = size.width;
    final h = size.height;
    canvas.drawCircle(Offset(cx, h * 0.16), w * 0.09, p);
    final body = Path()
      ..moveTo(cx - w * 0.16, h * 0.27)
      ..lineTo(cx + w * 0.16, h * 0.27)
      ..moveTo(cx - w * 0.16, h * 0.27)
      ..lineTo(cx - w * 0.20, h * 0.58)
      ..lineTo(cx - w * 0.14, h * 0.95)
      ..moveTo(cx + w * 0.16, h * 0.27)
      ..lineTo(cx + w * 0.20, h * 0.58)
      ..lineTo(cx + w * 0.14, h * 0.95);
    canvas.drawPath(body, p);
  }

  @override
  bool shouldRepaint(covariant SilhouettePainter old) => false;
}

class _WeightDialog extends StatefulWidget {
  final int initial; // в граммах
  const _WeightDialog({required this.initial});

  @override
  State<_WeightDialog> createState() => _WeightDialogState();
}

class _WeightDialogState extends State<_WeightDialog> {
  static const int _min = 40000;
  static const int _max = 160000;
  static const int _step = 50;

  static int _snap(int g) => max(_min, min(_max, (g / _step).round() * _step));

  late int _w = _snap(widget.initial);

  void _nudge(int delta) => setState(() => _w = _snap(_w + delta));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Ваш вес сегодня'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              IconButton(
                tooltip: 'Минус 50 г',
                icon: const Icon(Icons.remove_circle_outline, color: AppColors.mint),
                onPressed: () => _nudge(-_step),
              ),
              Text(
                '${fmtKg(_w)} кг',
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              ),
              IconButton(
                tooltip: 'Плюс 50 г',
                icon: const Icon(Icons.add_circle_outline, color: AppColors.mint),
                onPressed: () => _nudge(_step),
              ),
            ],
          ),
          const Text('Шаг 50 г', style: TextStyle(fontSize: 13, color: AppColors.fogGray)),
          Slider(
            value: _w.toDouble(),
            min: _min.toDouble(),
            max: _max.toDouble(),
            divisions: (_max - _min) ~/ _step,
            activeColor: AppColors.mint,
            onChanged: (v) => setState(() => _w = _snap(v.round())),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Не сохранять')),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.mint,
            foregroundColor: AppColors.darkGraphite,
          ),
          onPressed: () => Navigator.pop(context, _w),
          child: const Text('Сохранить'),
        ),
      ],
    );
  }
}

class CheckInCameraScreen extends StatefulWidget {
  final SettingsController controller;
  const CheckInCameraScreen({super.key, required this.controller});

  @override
  State<CheckInCameraScreen> createState() => _CheckInCameraScreenState();
}

class _CheckInCameraScreenState extends State<CheckInCameraScreen>
    with WidgetsBindingObserver {
  CameraController? _camera;
  String? _error;
  bool _busy = false;
  bool _initializing = false;
  int? _countdown;
  double _ghostOpacity = 0.4;
  bool _flipGhost = false; // задняя камера не зеркальная
  bool _useTimer = true;

  CheckIn? get _last =>
      widget.controller.checkIns.isEmpty ? null : widget.controller.checkIns.last;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    super.dispose();
  }

  /// Камеру нужно освобождать, когда приложение уходит в фон, и включать заново.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && !_busy) {
      final cam = _camera;
      if (cam != null) {
        setState(() => _camera = null);
        cam.dispose();
      }
    } else if (state == AppLifecycleState.resumed && _camera == null && _error == null) {
      _initCamera();
    }
  }

  Future<void> _initCamera() async {
    if (_initializing) return;
    _initializing = true;
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        if (mounted) setState(() => _error = 'Камера не найдена.');
        return;
      }
      final cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cams.first,
      );
      final ctrl = CameraController(cam, ResolutionPreset.high, enableAudio: false);
      await ctrl.initialize();
      if (!mounted) {
        await ctrl.dispose();
        return;
      }
      setState(() => _camera = ctrl);
    } on CameraException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.code.startsWith('CameraAccess')
            ? 'Нет доступа к камере. Разрешите его в настройках телефона.'
            : 'Не удалось запустить камеру.';
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Не удалось запустить камеру.');
    } finally {
      _initializing = false;
    }
  }

  Future<void> _shoot() async {
    final cam = _camera;
    if (cam == null || _busy) return;
    setState(() => _busy = true);

    if (_useTimer) {
      for (var i = 5; i > 0; i--) {
        if (!mounted) return;
        setState(() => _countdown = i);
        await Future.delayed(const Duration(seconds: 1));
      }
      if (!mounted) return;
      setState(() => _countdown = null);
    }

    try {
      final shot = await cam.takePicture();
      final name = 'checkin_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final target = '${widget.controller.docsPath}/$name';
      await File(shot.path).copy(target);
      try {
        await File(shot.path).delete();
      } catch (_) {}
      if (!mounted) return;

      final weight = await showDialog<int>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _WeightDialog(
          initial: _last?.weightG ?? widget.controller.s.weightKg * 1000,
        ),
      );
      if (weight == null) {
        // Пользователь не стал сохранять запись: убираем и фото.
        try {
          await File(target).delete();
        } catch (_) {}
        if (mounted) setState(() => _busy = false);
        return;
      }
      await widget.controller.addCheckIn(
        CheckIn(date: DateTime.now(), weightG: weight, fileName: name),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось сохранить фото. Попробуйте ещё раз.')),
      );
    }
  }

  Widget _preview() {
    final cam = _camera!;
    final last = _last;
    Widget? ghost;
    if (last != null) {
      ghost = Image.file(
        File(widget.controller.photoPath(last)),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
      );
      if (_flipGhost) ghost = Transform.flip(flipX: true, child: ghost);
      ghost = Opacity(opacity: _ghostOpacity, child: ghost);
    }
    return Center(
      child: AspectRatio(
        aspectRatio: 1 / cam.value.aspectRatio,
        child: Stack(
          fit: StackFit.expand,
          children: [
            CameraPreview(cam),
            if (ghost != null)
              ghost
            else
              const IgnorePointer(child: CustomPaint(painter: SilhouettePainter())),
            if (_countdown != null)
              Center(
                child: Text(
                  '$_countdown',
                  style: const TextStyle(
                    fontSize: 96,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 12, color: Colors.black54)],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasGhost = _last != null;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Закрыть',
                  icon: const Icon(Icons.close, color: Colors.white),
                  onPressed: () => Navigator.of(context).pop(),
                ),
                const Expanded(
                  child: Text(
                    'Фото недели',
                    style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            Expanded(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white, fontSize: 16),
                        ),
                      ),
                    )
                  : _camera == null
                      ? const Center(child: CircularProgressIndicator())
                      : _preview(),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: Column(
                children: [
                  Text(
                    hasGhost
                        ? 'Совместите себя с полупрозрачным фото прошлого раза.'
                        : 'Встаньте в полный рост так, чтобы совпасть с контуром.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  if (hasGhost)
                    Row(
                      children: [
                        const Icon(Icons.layers_outlined, color: Colors.white),
                        Expanded(
                          child: Slider(
                            value: _ghostOpacity,
                            min: 0.1,
                            max: 0.8,
                            activeColor: AppColors.mint,
                            onChanged: (v) => setState(() => _ghostOpacity = v),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Отразить прошлое фото',
                          icon: const Icon(Icons.flip, color: Colors.white),
                          onPressed: () => setState(() => _flipGhost = !_flipGhost),
                        ),
                      ],
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            Switch(
                              value: _useTimer,
                              activeThumbColor: AppColors.mint,
                              onChanged: _busy ? null : (v) => setState(() => _useTimer = v),
                            ),
                            const Flexible(
                              child: Text(
                                'Таймер 5 с',
                                style: TextStyle(color: Colors.white, fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      SizedBox(
                        width: 76,
                        height: 76,
                        child: Material(
                          color: Colors.white,
                          shape: const CircleBorder(side: BorderSide(color: AppColors.mint, width: 5)),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: (_busy || _camera == null) ? null : _shoot,
                            child: Center(
                              child: _busy
                                  ? const SizedBox(
                                      width: 24,
                                      height: 24,
                                      child: CircularProgressIndicator(strokeWidth: 2.5),
                                    )
                                  : const Icon(Icons.camera_alt, color: AppColors.darkGraphite, size: 30),
                            ),
                          ),
                        ),
                      ),
                      const Expanded(child: SizedBox()),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ───────────────────────── Рецепты с ИИ ─────────────────────────

/// Адрес вашего сервера, который обращается к ИИ (см. recipe_backend.js).
/// Пока пусто — работает встроенная небольшая база рецептов.
/// Ключ ИИ в приложение класть нельзя: он должен храниться только на сервере.
const String kRecipeApiUrl = kAiBaseUrl == '' ? '' : '$kAiBaseUrl/recipes';

class Recipe {
  final String title;
  final int minutes;
  final int kcal;
  final int protein;
  final int fat;
  final int carbs;
  final List<String> ingredients;
  final List<String> steps;

  const Recipe({
    required this.title,
    required this.minutes,
    required this.kcal,
    required this.protein,
    required this.fat,
    required this.carbs,
    required this.ingredients,
    required this.steps,
  });

  factory Recipe.fromJson(Map<String, dynamic> j) {
    List<String> strings(Object? v) =>
        ((v as List?) ?? const []).map((e) => e.toString()).toList();
    int number(Object? v) => (v as num?)?.round() ?? 0;
    return Recipe(
      title: (j['title'] ?? '').toString(),
      minutes: number(j['minutes']),
      kcal: number(j['kcal']),
      protein: number(j['protein']),
      fat: number(j['fat']),
      carbs: number(j['carbs']),
      ingredients: strings(j['ingredients']),
      steps: strings(j['steps']),
    );
  }
}

abstract class RecipeService {
  Future<List<Recipe>> suggest({
    required List<String> ingredients,
    required int maxKcal,
    required String meal,
  });
}

/// Запрос к вашему серверу, который уже обращается к ИИ.
class RemoteRecipeService implements RecipeService {
  final String url;
  const RemoteRecipeService(this.url);

  @override
  Future<List<Recipe>> suggest({
    required List<String> ingredients,
    required int maxKcal,
    required String meal,
  }) async {
    final res = await http
        .post(
          Uri.parse(url),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'ingredients': ingredients, 'maxKcal': maxKcal, 'meal': meal}),
        )
        .timeout(const Duration(seconds: 40));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    return ((data['recipes'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Recipe.fromJson)
        .toList();
  }
}

class _LocalEntry {
  final Recipe recipe;
  final List<String> tags;
  const _LocalEntry(this.recipe, this.tags);
}

/// Маленькая встроенная база для работы без сервера.
class LocalRecipeService implements RecipeService {
  static const List<_LocalEntry> _all = [
    _LocalEntry(
      Recipe(
        title: 'Курица с брокколи и рисом',
        minutes: 25,
        kcal: 420,
        protein: 36,
        fat: 11,
        carbs: 44,
        ingredients: ['Куриная грудка 150 г', 'Брокколи 150 г', 'Варёный рис 100 г', 'Оливковое масло 1 ч. л.'],
        steps: ['Нарежьте курицу и обжарьте 7–8 минут.', 'Добавьте брокколи и тушите 5 минут.', 'Подавайте с рисом.'],
      ),
      ['курица', 'брокколи', 'рис'],
    ),
    _LocalEntry(
      Recipe(
        title: 'Омлет с овощами',
        minutes: 10,
        kcal: 280,
        protein: 20,
        fat: 19,
        carbs: 6,
        ingredients: ['Яйца 3 шт.', 'Помидор 1 шт.', 'Болгарский перец ½ шт.', 'Соль, зелень'],
        steps: ['Нарежьте овощи и слегка обжарьте.', 'Залейте взбитыми яйцами.', 'Готовьте под крышкой 4–5 минут.'],
      ),
      ['яйца', 'яйцо', 'помидор', 'перец', 'шпинат'],
    ),
    _LocalEntry(
      Recipe(
        title: 'Гречка с грибами',
        minutes: 25,
        kcal: 360,
        protein: 14,
        fat: 9,
        carbs: 54,
        ingredients: ['Гречка варёная 150 г', 'Шампиньоны 150 г', 'Лук ½ шт.', 'Растительное масло 1 ч. л.'],
        steps: ['Обжарьте лук и грибы 8 минут.', 'Добавьте гречку и прогрейте 2 минуты.', 'Посолите и подавайте.'],
      ),
      ['гречка', 'грибы', 'шампиньоны', 'лук'],
    ),
    _LocalEntry(
      Recipe(
        title: 'Запечённая рыба с овощами',
        minutes: 30,
        kcal: 400,
        protein: 34,
        fat: 18,
        carbs: 20,
        ingredients: ['Филе белой рыбы 180 г', 'Кабачок 1 шт.', 'Помидор 1 шт.', 'Лимон, специи'],
        steps: ['Выложите рыбу и овощи на противень.', 'Сбрызните лимоном и посыпьте специями.', 'Запекайте 20 минут при 190 °C.'],
      ),
      ['рыба', 'кабачок', 'помидор', 'лимон'],
    ),
    _LocalEntry(
      Recipe(
        title: 'Овощной суп с чечевицей',
        minutes: 35,
        kcal: 320,
        protein: 17,
        fat: 6,
        carbs: 52,
        ingredients: ['Чечевица 60 г', 'Морковь 1 шт.', 'Лук ½ шт.', 'Картофель 1 шт.'],
        steps: ['Обжарьте лук и морковь 5 минут.', 'Добавьте чечевицу, картофель и воду.', 'Варите 20 минут до мягкости.'],
      ),
      ['чечевица', 'морковь', 'лук', 'картофель'],
    ),
    _LocalEntry(
      Recipe(
        title: 'Творог с ягодами',
        minutes: 5,
        kcal: 180,
        protein: 22,
        fat: 4,
        carbs: 14,
        ingredients: ['Творог 5% 150 г', 'Ягоды 80 г'],
        steps: ['Смешайте творог с ягодами.', 'По желанию добавьте каплю мёда.'],
      ),
      ['творог', 'ягоды', 'яблоко'],
    ),
  ];

  @override
  Future<List<Recipe>> suggest({
    required List<String> ingredients,
    required int maxKcal,
    required String meal,
  }) async {
    final want = ingredients.map((e) => e.toLowerCase()).where((e) => e.length >= 3).toList();
    int score(_LocalEntry e) =>
        e.tags.where((t) => want.any((w) => t.contains(w) || w.contains(t))).length;

    final fit = _all.where((e) => e.recipe.kcal <= maxKcal && score(e) > 0).toList()
      ..sort((a, b) => score(b).compareTo(score(a)));
    return fit.take(3).map((e) => e.recipe).toList();
  }
}

class RecipesPage extends StatefulWidget {
  final SettingsController controller;
  const RecipesPage({super.key, required this.controller});

  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  final TextEditingController _input = TextEditingController();
  final List<String> _items = [];
  late bool _lunch = widget.controller.s.lunchKcal == 0;
  bool _loading = false;
  String? _error;
  List<Recipe>? _results;

  RecipeService get _service =>
      kRecipeApiUrl.isEmpty ? LocalRecipeService() : const RemoteRecipeService(kRecipeApiUrl);

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  /// Сколько ккал можно потратить на выбранный приём пищи.
  int get _maxKcal {
    final s = widget.controller.s;
    final thisMeal = _lunch ? s.lunchKcal : s.dinnerKcal;
    final left = s.effectiveLimit - (s.eatenKcal - thisMeal);
    // Если ужин ещё не записан, часть лимита оставляем на него.
    final share = (_lunch && s.dinnerKcal == 0) ? left * 0.6 : left.toDouble();
    return max(0, (share / 10).round() * 10);
  }

  void _add() {
    final text = _input.text.trim();
    if (text.isEmpty || _items.length >= 15) return;
    if (_items.any((e) => e.toLowerCase() == text.toLowerCase())) {
      _input.clear();
      return;
    }
    setState(() {
      _items.add(text);
      _results = null;
    });
    _input.clear();
  }

  Future<void> _search() async {
    if (_items.isEmpty) return;
    final limit = _maxKcal;
    if (limit < 100) {
      setState(() {
        _results = null;
        _error = 'На сегодня лимит почти исчерпан. Завтра новый день, тогда и подберём рецепты.';
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _results = null;
    });
    try {
      final list = await _service.suggest(
        ingredients: List.of(_items),
        maxKcal: limit,
        meal: _lunch ? 'обед' : 'ужин',
      );
      final fit = list.where((r) => r.title.isNotEmpty && r.kcal > 0 && r.kcal <= limit + 50).toList();
      if (!mounted) return;
      setState(() {
        _results = fit;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Не удалось получить рецепты. Проверьте интернет и попробуйте ещё раз.';
        _loading = false;
      });
    }
  }

  Future<void> _log(Recipe r) async {
    final lunch = _lunch;
    await widget.controller.update((s) {
      if (lunch) {
        s.lunchKcal = r.kcal;
      } else {
        s.dinnerKcal = r.kcal;
      }
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Записано: ${r.title}, ${r.kcal} ккал')),
    );
  }

  Widget _pill(String text, {bool strong = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: strong ? AppColors.peach : const Color(0xFFEEF3F2),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 13,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
            color: AppColors.darkGraphite,
          ),
        ),
      );

  Widget _recipeCard(Recipe r) {
    final mealName = _lunch ? 'обед' : 'ужин';
    return SectionCard(
      title: r.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _pill('${r.kcal} ккал', strong: true),
              _pill('Б ${r.protein}'),
              _pill('Ж ${r.fat}'),
              _pill('У ${r.carbs}'),
              _pill('${r.minutes} мин'),
            ],
          ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            shape: const Border(),
            collapsedShape: const Border(),
            title: const Text('Состав и приготовление', style: TextStyle(fontSize: 15)),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final i in r.ingredients)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('• $i', style: const TextStyle(fontSize: 14)),
                ),
              const SizedBox(height: 8),
              for (var n = 0; n < r.steps.length; n++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text('${n + 1}. ${r.steps[n]}', style: const TextStyle(fontSize: 14)),
                ),
              const SizedBox(height: 8),
            ],
          ),
          SizedBox(
            width: double.infinity,
            child: FilledButton.tonal(
              onPressed: () => _log(r),
              child: Text('Записать в $mealName'),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final s = widget.controller.s;
        final left = s.effectiveLimit - s.eatenKcal;
        final reserve = _lunch && s.dinnerKcal == 0;

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Text(
              'Рецепты',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.darkGraphite),
            ),
            const SizedBox(height: 4),
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Подберём блюдо под остаток ваших калорий',
                style: TextStyle(fontSize: 15, color: AppColors.fogGray),
              ),
            ),
            SectionCard(
              title: 'Что в холодильнике?',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _input,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _add(),
                          decoration: const InputDecoration(
                            labelText: 'Продукт',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        onPressed: _add,
                        tooltip: 'Добавить продукт',
                        style: IconButton.styleFrom(backgroundColor: AppColors.mint),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  if (_items.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        for (final e in _items)
                          InputChip(
                            label: Text(e),
                            onDeleted: () => setState(() {
                              _items.remove(e);
                              _results = null;
                            }),
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  ChoiceWrap<bool>(
                    options: const [true, false],
                    selected: _lunch,
                    labelOf: (v) => v ? 'Обед' : 'Ужин',
                    onSelected: (v) => setState(() {
                      _lunch = v;
                      _results = null;
                    }),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: AppColors.peach,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Подберём до $_maxKcal ккал',
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: AppColors.darkGraphite,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Остаток дня: ${max(0, left)} из ${s.effectiveLimit} ккал'
                          '${reserve ? '. Часть оставляем на ужин.' : ''}',
                          style: const TextStyle(fontSize: 13, color: AppColors.darkGraphite),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.mint,
                        foregroundColor: AppColors.darkGraphite,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: (_items.isEmpty || _loading) ? null : _search,
                      child: _loading
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 2.5),
                            )
                          : const Text('Найти рецепты'),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_error!, style: const TextStyle(color: AppColors.darkGraphite)),
              ),
            if (_results != null && _results!.isEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  'Подходящих рецептов не нашлось. Попробуйте добавить другие продукты.',
                  style: TextStyle(color: AppColors.darkGraphite),
                ),
              ),
            if (_results != null) ...[for (final r in _results!) _recipeCard(r)],
            const Text(
              'Рецепты подбираются автоматически, калории и БЖУ приблизительные. '
              'При аллергиях и особых диетах проверяйте состав.',
              style: TextStyle(fontSize: 12, color: AppColors.fogGray),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Онбординг ─────────────────────────

class OnboardingFlow extends StatefulWidget {
  final SettingsController controller;
  const OnboardingFlow({super.key, required this.controller});

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  static const int _lastPage = 3;
  final PageController _pages = PageController();
  int _page = 0;
  bool _accepted = false;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_page == _lastPage) {
      await NotificationService.instance.requestPermission();
      await widget.controller.update((s) {
        s.name = s.name.trim();
        s.onboardingDone = true;
      });
      return;
    }
    await _pages.nextPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _back() async {
    await _pages.previousPage(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Widget _scroll(List<Widget> children) => SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _heading(String title, String subtitle) => Padding(
        padding: const EdgeInsets.only(bottom: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: AppColors.darkGraphite,
              ),
            ),
            const SizedBox(height: 6),
            Text(subtitle, style: const TextStyle(fontSize: 16, color: AppColors.fogGray)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final canNext = _page != 0 || _accepted;

    return Scaffold(
      body: Container(
        decoration: kBackground,
        child: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: PageView(
                  controller: _pages,
                  physics: const NeverScrollableScrollPhysics(),
                  onPageChanged: (i) => setState(() => _page = i),
                  children: [
                    // 0. Приветствие и важная информация
                    _scroll([
                      _heading('InterLight', 'Твой мягкий вход в здоровый ритм.'),
                      const SectionCard(
                        title: 'Прежде чем начать',
                        child: Text(
                          'Приложение для взрослых (18+) и не заменяет врача. '
                          'Оно не подходит при беременности, кормлении грудью, диабете, '
                          'расстройствах пищевого поведения и других заболеваниях, '
                          'при которых нужен особый режим питания. В таких случаях '
                          'сначала проконсультируйтесь с врачом.',
                          style: TextStyle(fontSize: 15, color: AppColors.darkGraphite),
                        ),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        activeColor: AppColors.mint,
                        value: _accepted,
                        onChanged: (v) => setState(() => _accepted = v ?? false),
                        title: const Text('Мне есть 18 лет, я прочитал(а) и понимаю'),
                      ),
                    ]),
                    // 1. Имя и цель
                    _scroll([
                      _heading('Знакомимся', 'Расскажите немного о себе.'),
                      SectionCard(
                        title: 'О вас',
                        child: PersonalFields(controller: c),
                      ),
                    ]),
                    // 2. Параметры
                    _scroll([
                      _heading('Параметры', 'Нужны для ориентира по калориям.'),
                      SectionCard(title: 'Ваши данные', child: BodyFields(controller: c)),
                      CalorieCard(controller: c),
                    ]),
                    // 3. Шаги и режим питания
                    _scroll([
                      _heading('Ритм дня', 'Всё можно изменить позже в настройках.'),
                      SectionCard(
                        title: 'Норма шагов в день',
                        child: StepsGoalFields(controller: c),
                      ),
                      SectionCard(
                        title: 'Время приёмов пищи',
                        child: MealFields(controller: c),
                      ),
                    ]),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
                child: Row(
                  children: [
                    if (_page > 0)
                      TextButton(onPressed: _back, child: const Text('Назад'))
                    else
                      const SizedBox(width: 64),
                    const Spacer(),
                    Row(
                      children: [
                        for (var i = 0; i <= _lastPage; i++)
                          Container(
                            width: i == _page ? 20 : 8,
                            height: 8,
                            margin: const EdgeInsets.symmetric(horizontal: 3),
                            decoration: BoxDecoration(
                              color: i == _page
                                  ? AppColors.mint
                                  : AppColors.mint.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(4),
                            ),
                          ),
                      ],
                    ),
                    const Spacer(),
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: AppColors.mint),
                      onPressed: canNext ? _next : null,
                      child: Text(_page == _lastPage ? 'Начать' : 'Далее'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Сад ─────────────────────────

const int kPointsPerFlower = 15;
const List<String> kFlowerEmoji = ['🌷', '🌻', '🌼', '🌸', '🌺', '💐'];
const Color kMutedText = Color(0xFF5F6F73);

String gardenStage(int flowers) {
  if (flowers >= 12) return 'Цветущий сад';
  if (flowers >= 6) return 'Пышный сад';
  if (flowers >= 3) return 'Маленький сад';
  if (flowers >= 1) return 'Первые цветы';
  return 'Росток';
}

String plantEmoji(int progress) => progress < 5 ? '🌱' : (progress < 10 ? '🌿' : '🌷');

class GardenPage extends StatelessWidget {
  final SettingsController controller;
  const GardenPage({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final s = c.s;
        final total = s.gardenTotal;
        final flowers = total ~/ kPointsPerFlower;
        final progress = total % kPointsPerFlower;
        final toNext = kPointsPerFlower - progress;
        const shown = 36;

        final badges = <(String, String, String, bool)>[
          ('🌱', 'Первый росток', 'Первое очко за привычку', total >= 1),
          ('🌷', 'Первый цветок', '$kPointsPerFlower очков', flowers >= 1),
          ('💐', 'Пять цветов', 'Сад из пяти цветов', flowers >= 5),
          ('☀️', 'Неделя заботы', '7 дней, где выполнено 3 привычки', s.gardenGoodDays >= 7),
          ('🌳', 'Месяц заботы', '30 таких дней', s.gardenGoodDays >= 30),
          ('📸', 'Первый чек-ап', 'Первое фото недели', c.checkIns.isNotEmpty),
        ];

        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            const Text(
              'Сад',
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: AppColors.darkGraphite),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 16),
              child: Text(
                'Растёт от заботы о себе. Пропущенные дни ничего не портят.',
                style: TextStyle(fontSize: 15, color: kMutedText),
              ),
            ),
            SectionCard(
              title: gardenStage(flowers),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(child: Text(plantEmoji(progress), style: const TextStyle(fontSize: 72))),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: LinearProgressIndicator(
                      value: progress / kPointsPerFlower,
                      minHeight: 12,
                      backgroundColor: Colors.grey[200],
                      valueColor: const AlwaysStoppedAnimation<Color>(AppColors.mint),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'До нового цветка: $toNext очк. Всего очков: $total',
                    style: const TextStyle(fontSize: 14, color: AppColors.darkGraphite),
                  ),
                  if (flowers > 0) ...[
                    const SizedBox(height: 12),
                    Semantics(
                      label: 'Цветов в саду: $flowers',
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (var i = 0; i < min(flowers, shown); i++)
                            Text(kFlowerEmoji[i % kFlowerEmoji.length], style: const TextStyle(fontSize: 30)),
                          if (flowers > shown)
                            Text('+${flowers - shown}', style: const TextStyle(fontSize: 18)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            SectionCard(
              title: 'Сегодня: ${s.todayPoints} из ${s.habits.length}',
              child: Column(
                children: [
                  for (final h in s.habits)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            h.done ? Icons.check_circle : Icons.radio_button_unchecked,
                            color: h.done ? AppColors.mint : kMutedText,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(h.label, style: const TextStyle(fontSize: 16, color: AppColors.darkGraphite)),
                          ),
                          Text(h.detail, style: const TextStyle(fontSize: 14, color: kMutedText)),
                        ],
                      ),
                    ),
                  const SizedBox(height: 4),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'За калории и вес очки не начисляются: сад растёт от привычек.',
                      style: TextStyle(fontSize: 12, color: kMutedText),
                    ),
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Награды',
              child: LayoutBuilder(
                builder: (context, cons) {
                  final w = (cons.maxWidth - 12) / 2;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final b in badges)
                        SizedBox(
                          width: w,
                          child: Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: b.$4 ? AppColors.peach : const Color(0xFFEEF3F2),
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                b.$4
                                    ? Text(b.$1, style: const TextStyle(fontSize: 28))
                                    : const Icon(Icons.lock_outline, size: 28, color: kMutedText),
                                const SizedBox(height: 4),
                                Text(
                                  b.$2,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                    color: AppColors.darkGraphite,
                                  ),
                                ),
                                Text(
                                  b.$4 ? 'Получено' : b.$3,
                                  style: const TextStyle(fontSize: 12, color: kMutedText),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ───────────────────────── Калории по фото тарелки ─────────────────────────

/// Адрес сервера для распознавания блюд (маршрут /plate из recipe_backend.js).
/// Пока пусто: можно только ввести калории вручную.
const String kPlateApiUrl = kAiBaseUrl == '' ? '' : '$kAiBaseUrl/plate';

class PlateItem {
  final String name;
  final int grams;
  final int kcal;
  const PlateItem(this.name, this.grams, this.kcal);
}

class PlateResult {
  final List<PlateItem> items;
  final String confidence; // low, medium или high
  final String note;
  const PlateResult(this.items, this.confidence, this.note);
}

class PlateService {
  static Future<PlateResult> analyze(Uint8List jpeg) async {
    final res = await http
        .post(
          Uri.parse(kPlateApiUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'photo': base64Encode(jpeg)}),
        )
        .timeout(const Duration(seconds: 60));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}');
    final data = jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
    final items = <PlateItem>[];
    for (final e in (data['items'] as List? ?? const [])) {
      if (e is! Map) continue;
      final name = (e['name'] ?? '').toString().trim();
      final kcal = (e['kcal'] as num?)?.round() ?? 0;
      if (name.isEmpty || kcal <= 0) continue;
      items.add(PlateItem(name, (e['grams'] as num?)?.round() ?? 0, kcal));
    }
    return PlateResult(
      items,
      (data['confidence'] ?? 'low').toString(),
      (data['note'] ?? '').toString().trim(),
    );
  }
}

class PlateScreen extends StatefulWidget {
  final SettingsController controller;
  final bool lunch;
  const PlateScreen({super.key, required this.controller, required this.lunch});

  @override
  State<PlateScreen> createState() => _PlateScreenState();
}

class _PlateScreenState extends State<PlateScreen> {
  late bool _lunch = widget.lunch;
  Uint8List? _photo;
  PlateResult? _result;
  bool _loading = false;
  String? _error;
  final Set<int> _removed = {};
  double _scale = 1.0;

  int get _total {
    final r = _result;
    if (r == null) return 0;
    var sum = 0;
    for (var i = 0; i < r.items.length; i++) {
      if (!_removed.contains(i)) sum += r.items[i].kcal;
    }
    return (sum * _scale / 5).round() * 5;
  }

  Future<bool> _ensureConsent() async {
    final c = widget.controller;
    if (c.s.plateAiConsent) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Отправить фото блюда?'),
        content: const Text(
          'Фото будет уменьшено и отправлено на сервер приложения, а затем в сервис ИИ '
          'для оценки калорий. Сервер приложения его не сохраняет; обработку у поставщика '
          'ИИ регулируют его условия. Согласие можно отозвать на этом экране.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Не отправлять')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Согласен')),
        ],
      ),
    );
    if (ok != true) return false;
    await c.update((s) => s.plateAiConsent = true);
    return true;
  }

  Future<void> _pick(ImageSource source) async {
    if (_loading) return;
    if (!await _ensureConsent() || !mounted) return;
    if (source == ImageSource.camera && Platform.isAndroid) {
      final st = await ph.Permission.camera.request();
      if (!mounted) return;
      if (!st.isGranted) {
        setState(() => _error =
            'Нет доступа к камере. Разрешите его в настройках телефона или выберите фото из галереи.');
        return;
      }
    }
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 960, imageQuality: 75);
      if (x == null || !mounted) return;
      final bytes = await x.readAsBytes();
      if (!mounted) return;
      setState(() {
        _photo = bytes;
        _result = null;
        _removed.clear();
        _scale = 1.0;
        _error = null;
        _loading = true;
      });
      final result = await PlateService.analyze(bytes);
      if (!mounted) return;
      setState(() {
        _result = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Не удалось распознать блюдо. Попробуйте ещё раз или введите калории вручную.';
      });
    }
  }

  Future<void> _save() async {
    final total = _total;
    if (total <= 0) return;
    final lunch = _lunch;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    await widget.controller.update((s) {
      if (lunch) {
        s.lunchKcal += total;
      } else {
        s.dinnerKcal += total;
      }
    });
    nav.pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Добавлено к ${lunch ? 'обеду' : 'ужину'}: $total ккал')),
    );
  }

  String _confidenceText(String c) {
    switch (c) {
      case 'high':
        return 'Оценка довольно уверенная';
      case 'medium':
        return 'Оценка примерная';
      default:
        return 'Оценка очень приблизительная';
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final r = _result;
    final current = _lunch ? c.s.lunchKcal : c.s.dinnerKcal;
    final mealGen = _lunch ? 'обеду' : 'ужину';

    return Scaffold(
      appBar: AppBar(title: const Text('Калории по фото')),
      body: Container(
        decoration: kBackground,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              ChoiceWrap<bool>(
                options: const [true, false],
                selected: _lunch,
                labelOf: (v) => v ? 'Обед' : 'Ужин',
                onSelected: (v) => setState(() => _lunch = v),
              ),
              const SizedBox(height: 16),
              if (kPlateApiUrl.isEmpty)
                SectionCard(
                  title: 'Распознавание пока не подключено',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Оно заработает после подключения сервера (инструкция в SETUP.md). '
                        'Пока калории можно записать вручную.',
                        style: TextStyle(fontSize: 15, color: AppColors.darkGraphite),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.tonal(
                          onPressed: () async {
                            await editKcal(context, c, lunch: _lunch);
                            if (context.mounted) Navigator.pop(context);
                          },
                          child: const Text('Ввести калории вручную'),
                        ),
                      ),
                    ],
                  ),
                )
              else ...[
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.mint,
                          foregroundColor: AppColors.darkGraphite,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: _loading ? null : () => _pick(ImageSource.camera),
                        icon: const Icon(Icons.photo_camera_outlined),
                        label: const Text('Снять'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
                        onPressed: _loading ? null : () => _pick(ImageSource.gallery),
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('Из галереи'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text(
                  'Снимайте блюдо сверху при хорошем свете, чтобы была видна вся тарелка.',
                  style: TextStyle(fontSize: 13, color: kMutedText),
                ),
                const SizedBox(height: 16),
              ],
              if (_photo != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.memory(_photo!, height: 220, width: double.infinity, fit: BoxFit.cover),
                ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(_error!, style: const TextStyle(color: AppColors.darkGraphite)),
                ),
              if (r != null) ...[
                const SizedBox(height: 16),
                SectionCard(
                  title: r.items.isEmpty ? 'Еду разобрать не удалось' : 'Что нашлось',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < r.items.length; i++)
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                r.items[i].grams > 0
                                    ? '${r.items[i].name} · ${r.items[i].grams} г'
                                    : r.items[i].name,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: _removed.contains(i) ? kMutedText : AppColors.darkGraphite,
                                  decoration:
                                      _removed.contains(i) ? TextDecoration.lineThrough : null,
                                ),
                              ),
                            ),
                            Text('${r.items[i].kcal} ккал', style: const TextStyle(fontSize: 14)),
                            IconButton(
                              tooltip: _removed.contains(i) ? 'Вернуть' : 'Убрать',
                              icon: Icon(_removed.contains(i) ? Icons.undo : Icons.close, size: 20),
                              onPressed: () => setState(() {
                                if (!_removed.remove(i)) _removed.add(i);
                              }),
                            ),
                          ],
                        ),
                      if (r.items.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        ChoiceWrap<double>(
                          options: const [0.75, 1.0, 1.25],
                          selected: _scale,
                          labelOf: (v) => v < 1 ? 'Порция меньше' : (v > 1 ? 'Порция больше' : 'Как на фото'),
                          onSelected: (v) => setState(() => _scale = v),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.peach,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            'Итого ≈ $_total ккал',
                            style: const TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppColors.darkGraphite,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Text(
                        '${_confidenceText(r.confidence)}. Погрешность по фото может быть заметной.'
                        '${r.note.isEmpty ? '' : ' ${r.note}'}',
                        style: const TextStyle(fontSize: 13, color: kMutedText),
                      ),
                    ],
                  ),
                ),
                if (r.items.isNotEmpty)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.mint,
                        foregroundColor: AppColors.darkGraphite,
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _total > 0 ? _save : null,
                      child: Text('Добавить к $mealGen: +$_total ккал'),
                    ),
                  ),
                if (r.items.isNotEmpty && current > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Сейчас записано: $current ккал',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 13, color: kMutedText),
                    ),
                  ),
              ],
              if (c.s.plateAiConsent && kPlateApiUrl.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () async {
                      await c.update((s) => s.plateAiConsent = false);
                      if (mounted) {
                        setState(() {
                          _photo = null;
                          _result = null;
                        });
                      }
                    },
                    child: const Text('Отозвать согласие на отправку фото'),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Каркас с навигацией ─────────────────────────

class MainDashboard extends StatefulWidget {
  final SettingsController controller;
  const MainDashboard({super.key, required this.controller});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int _currentIndex = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      HomePage(controller: widget.controller),
      ProgressPage(controller: widget.controller),
      RecipesPage(controller: widget.controller),
      GardenPage(controller: widget.controller),
      SettingsPage(controller: widget.controller),
    ];

    return Scaffold(
      body: Container(
        decoration: kBackground,
        child: SafeArea(
          child: IndexedStack(index: _currentIndex, children: pages),
        ),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: AppColors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, -5),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BottomNavigationBar(
            currentIndex: _currentIndex,
            onTap: (i) => setState(() => _currentIndex = i),
            backgroundColor: Colors.transparent,
            elevation: 0,
            selectedItemColor: AppColors.mint,
            unselectedItemColor: AppColors.fogGray,
            type: BottomNavigationBarType.fixed,
            items: const [
              BottomNavigationBarItem(icon: Icon(Icons.home_rounded), label: 'Главная'),
              BottomNavigationBarItem(icon: Icon(Icons.camera_alt_rounded), label: 'Прогресс'),
              BottomNavigationBarItem(icon: Icon(Icons.restaurant_menu_rounded), label: 'Рецепты'),
              BottomNavigationBarItem(icon: Icon(Icons.local_florist_rounded), label: 'Сад'),
              BottomNavigationBarItem(icon: Icon(Icons.settings_rounded), label: 'Настройки'),
            ],
          ),
        ),
      ),
    );
  }
}

// ───────────────────────── Экран настроек ─────────────────────────

class SettingsPage extends StatelessWidget {
  final SettingsController controller;
  const SettingsPage({super.key, required this.controller});

  Future<void> _confirmReset(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Сбросить все данные?'),
        content: const Text('Настройки будут удалены, и онбординг начнётся заново.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Отмена')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Сбросить')),
        ],
      ),
    );
    if (ok == true) await controller.reset();
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 16),
            child: Text(
              'Настройки',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: AppColors.darkGraphite,
              ),
            ),
          ),
          SectionCard(title: 'Профиль', child: PersonalFields(controller: c)),
          SectionCard(
            title: 'Параметры',
            child: Column(
              children: [
                BodyFields(controller: c),
                const SizedBox(height: 8),
                CalorieCard(controller: c),
              ],
            ),
          ),
          SectionCard(
            title: 'Лимит калорий в день',
            child: CalorieLimitFields(controller: c),
          ),
          SectionCard(title: 'Норма шагов в день', child: StepsGoalFields(controller: c)),
          SectionCard(
            title: 'Вода',
            child: Column(
              children: [
                SliderRow(
                  label: 'Цель на день',
                  value: c.s.waterGoalMl,
                  min: 1000,
                  max: 4000,
                  unit: 'мл',
                  onChanged: (v) => c.update((s) => s.waterGoalMl = v),
                ),
                SliderRow(
                  label: 'Размер стакана',
                  value: c.s.waterGlassMl,
                  min: 150,
                  max: 400,
                  unit: 'мл',
                  onChanged: (v) => c.update((s) => s.waterGlassMl = v),
                ),
                SliderRow(
                  label: 'Пауза между порциями',
                  value: c.s.waterCooldownMin,
                  min: 15,
                  max: 120,
                  unit: 'мин',
                  onChanged: (v) => c.update((s) => s.waterCooldownMin = v),
                ),
              ],
            ),
          ),
          SectionCard(title: 'Время приёмов пищи', child: MealFields(controller: c)),
          SectionCard(
            title: 'Напоминания',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.mint,
                  title: const Text('Вода (каждые 2 часа)'),
                  value: c.s.waterOn,
                  onChanged: (v) => c.update((s) => s.waterOn = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.mint,
                  title: const Text('Витамины'),
                  value: c.s.vitaminsOn,
                  onChanged: (v) => c.update((s) => s.vitaminsOn = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.mint,
                  title: const Text('Микро-разминки'),
                  value: c.s.warmupOn,
                  onChanged: (v) => c.update((s) => s.warmupOn = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.mint,
                  title: const Text('Недельный чек-ап (воскресенье)'),
                  value: c.s.checkinOn,
                  onChanged: (v) => c.update((s) => s.checkinOn = v),
                ),
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Вода: каждые 2 часа с 08:00 до 22:00. Витамины: утром и в обед. '
                    'Разминка: днём. Чек-ап: воскресенье утром. В тихие часы уведомлений нет.',
                    style: TextStyle(fontSize: 12, color: AppColors.fogGray),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.notifications_active_outlined),
                    label: const Text('Проверить уведомления'),
                    onPressed: () async {
                      final ok = await NotificationService.instance.showTest();
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            ok
                                ? 'Тестовое уведомление отправлено.'
                                : 'Не удалось отправить. Проверьте разрешение на '
                                    'уведомления в настройках телефона.',
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Тихие часы',
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  activeThumbColor: AppColors.mint,
                  title: const Text('Не беспокоить'),
                  value: c.s.quietOn,
                  onChanged: (v) => c.update((s) => s.quietOn = v),
                ),
                if (c.s.quietOn) ...[
                  TimeTile(
                    label: 'С',
                    minutes: c.s.quietStartMin,
                    onTap: () async {
                      final m = await pickTime(context, c.s.quietStartMin);
                      if (m != null) await c.update((s) => s.quietStartMin = m);
                    },
                  ),
                  TimeTile(
                    label: 'До',
                    minutes: c.s.quietEndMin,
                    onTap: () async {
                      final m = await pickTime(context, c.s.quietEndMin);
                      if (m != null) await c.update((s) => s.quietEndMin = m);
                    },
                  ),
                ],
              ],
            ),
          ),
          Center(
            child: TextButton.icon(
              onPressed: () => _confirmReset(context),
              icon: const Icon(Icons.restart_alt, color: AppColors.fogGray),
              label: const Text(
                'Сбросить данные и начать заново',
                style: TextStyle(color: AppColors.fogGray),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ───────────────────────── Главная вкладка ─────────────────────────

class HomePage extends StatefulWidget {
  final SettingsController controller;
  const HomePage({super.key, required this.controller});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late DateTime _now;
  Timer? _ticker;
  int _tick = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _now = DateTime.now();
    widget.controller.syncSteps();
    _ticker = Timer.periodic(const Duration(seconds: 10), (_) {
      if (!mounted) return;
      widget.controller.checkNewDay();
      _tick++;
      if (_tick % 3 == 0) widget.controller.syncSteps(); // раз в 30 секунд
      setState(() => _now = DateTime.now());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.checkNewDay();
      widget.controller.syncSteps();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  void _showWhatCanIDo(FastingStatus status) {
    final canEat = status.isEatingWindow;
    final title = canEat ? 'Сейчас окно питания' : 'Сейчас интервал';
    final items = canEat
        ? const [
            'Полноценный приём пищи 🍽️',
            'Вода или чай — по желанию',
          ]
        : const [
            'Тёплая или обычная вода 💧',
            'Несладкий чай 🍵',
            'Чёрный кофе без сахара ☕',
            'Витамин C и водорастворимые витамины',
          ];

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) => Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: AppColors.darkGraphite,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              canEat
                  ? 'Следующий интервал начнётся примерно через 45 минут после еды.'
                  : 'До ${status.nextMeal.genitive}: ${formatDuration(status.remaining)}',
              style: const TextStyle(fontSize: 14, color: AppColors.fogGray),
            ),
            const SizedBox(height: 16),
            for (final item in items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle, color: AppColors.mint, size: 20),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(fontSize: 16, color: AppColors.darkGraphite),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.controller.s;
    final status = FastingStatus.compute(_now, settings.meals);

    final phrase = status.isEatingWindow
        ? 'Приятного аппетита! Сейчас окно питания.'
        : 'Всё по плану. Интервал работает.';

    final greeting = settings.name.trim().isEmpty
        ? '${greetingFor(_now)}!'
        : '${greetingFor(_now)}, ${settings.name.trim()}!';

    return LayoutBuilder(
      builder: (context, constraints) {
        final timerSize = min(280.0, constraints.maxWidth * 0.72);

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              greeting,
                              style: const TextStyle(
                                fontSize: 28,
                                fontWeight: FontWeight.bold,
                                color: AppColors.darkGraphite,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              phrase,
                              style: const TextStyle(fontSize: 16, color: AppColors.fogGray),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppColors.mint.withValues(alpha: 0.2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.person, color: AppColors.mint),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: FastingTimer(
                    size: timerSize,
                    progress: status.progress,
                    remainingTime: formatDuration(status.remaining),
                    nextMeal: 'До ${status.nextMeal.genitive} (${status.nextMeal.time})',
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                  child: Material(
                    color: AppColors.white.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(16),
                    elevation: 2,
                    shadowColor: AppColors.mint.withValues(alpha: 0.3),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _showWhatCanIDo(status),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.water_drop, color: AppColors.mint, size: 24),
                            SizedBox(width: 12),
                            Text(
                              'Что можно сейчас?',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w600,
                                color: AppColors.darkGraphite,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                  child: DailyTrackers(controller: widget.controller),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 14, 24, 0),
                  child: MealKcalCard(controller: widget.controller),
                ),
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: StepsCard(controller: widget.controller),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ───────────────────────── Круговой таймер ─────────────────────────

class FastingTimer extends StatelessWidget {
  final double size;
  final double progress;
  final String remainingTime;
  final String nextMeal;

  const FastingTimer({
    super.key,
    required this.size,
    required this.progress,
    required this.remainingTime,
    required this.nextMeal,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: CirclePainter(color: Colors.grey[200]!, strokeWidth: 12),
          ),
          CustomPaint(
            painter: CirclePainter(
              color: AppColors.mint,
              strokeWidth: 12,
              progress: progress,
              strokeCap: StrokeCap.round,
            ),
          ),
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      remainingTime,
                      style: const TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.bold,
                        color: AppColors.darkGraphite,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    nextMeal,
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 16, color: AppColors.fogGray),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CirclePainter extends CustomPainter {
  final Color color;
  final double strokeWidth;
  final double progress;
  final StrokeCap strokeCap;

  CirclePainter({
    required this.color,
    required this.strokeWidth,
    this.progress = 1.0,
    this.strokeCap = StrokeCap.butt,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = strokeCap;

    if (progress < 1.0) {
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -pi / 2,
        2 * pi * progress,
        false,
        paint,
      );
    } else {
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant CirclePainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.strokeCap != strokeCap;
}
