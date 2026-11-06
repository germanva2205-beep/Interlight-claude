#!/usr/bin/env python3
"""Донастраивает Android-проект, созданный командой `flutter create`, под InterLight.

Запускается из корня проекта (после `flutter create`). Скрипт ПРАВИТ сгенерированные файлы,
а не заменяет их целиком, поэтому работает и при смене шаблона Flutter.
Что делает:
  1. build.gradle.kts: minSdk 26, включает desugaring и добавляет его зависимость;
  2. AndroidManifest.xml: разрешения, Health Connect, приёмники уведомлений;
  3. MainActivity.kt: FlutterFragmentActivity (нужна для Health Connect);
  4. gradle.properties: несовпадение версий JVM у плагинов считается предупреждением, а не ошибкой.
Повторный запуск безопасен: уже добавленное второй раз не добавляется.
"""
import pathlib
import re
import sys
import xml.dom.minidom

PACKAGE = "com.germanva.interlight"
DESUGAR = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'


def fail(msg):
    print("ОШИБКА: " + msg)
    sys.exit(1)


# ───────────────────────── 1. build.gradle.kts ─────────────────────────
gradle_path = pathlib.Path("android/app/build.gradle.kts")
if not gradle_path.exists():
    fail("не найден android/app/build.gradle.kts, сначала выполните flutter create")
g = gradle_path.read_text(encoding="utf-8")
if "com.android.application" not in g:
    fail("android/app/build.gradle.kts не похож на настройки Gradle. Удалите папку android в репозитории: "
         "её пересоздаст flutter create")

# minSdk 26 нужен для Health Connect
if re.search(r"minSdk\s*=", g):
    g = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 26", g)
else:
    g = re.sub(r"(defaultConfig\s*\{)", r"\1\n        minSdk = 26", g, count=1)

# включаем desugaring
if "isCoreLibraryDesugaringEnabled" in g:
    g = re.sub(r"isCoreLibraryDesugaringEnabled\s*=\s*false", "isCoreLibraryDesugaringEnabled = true", g)
elif re.search(r"compileOptions\s*\{", g):
    g = re.sub(r"(compileOptions\s*\{)", r"\1\n        isCoreLibraryDesugaringEnabled = true", g, count=1)
else:
    g = re.sub(r"(android\s*\{)", r"\1\n    compileOptions {\n        isCoreLibraryDesugaringEnabled = true\n    }", g, count=1)

# добавляем зависимость (именно её не хватало: «coreLibraryDesugaring configuration contains no dependencies»)
if "coreLibraryDesugaring(" not in g:
    g = g.rstrip() + "\n\ndependencies {\n    " + DESUGAR + "\n}\n"

if "isCoreLibraryDesugaringEnabled = true" not in g:
    fail("не удалось включить desugaring в build.gradle.kts")
if DESUGAR not in g:
    fail("не удалось добавить зависимость desugaring в build.gradle.kts")
if not re.search(r"minSdk\s*=\s*26", g):
    fail("не удалось выставить minSdk = 26")
gradle_path.write_text(g, encoding="utf-8")
print("OK build.gradle.kts")

# ───────────────────────── 2. AndroidManifest.xml ─────────────────────────
manifest_path = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not manifest_path.exists():
    fail("не найден AndroidManifest.xml")
x = manifest_path.read_text(encoding="utf-8")

permissions = [
    "android.permission.CAMERA",
    "android.permission.POST_NOTIFICATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED",
    "android.permission.ACTIVITY_RECOGNITION",
    "android.permission.health.READ_STEPS",
]
perm_xml = ""
for p in permissions:
    if f'android:name="{p}"' not in x:
        perm_xml += f'    <uses-permission android:name="{p}"/>\n'
if perm_xml:
    x = re.sub(r"(<manifest[^>]*>\s*\n)", lambda m: m.group(1) + perm_xml, x, count=1)

# Health Connect в <queries>
queries_inner = (
    '        <package android:name="com.google.android.apps.healthdata"/>\n'
    "        <intent>\n"
    '            <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>\n'
    "        </intent>\n"
)
if "com.google.android.apps.healthdata" not in x:
    if "<queries>" in x:
        x = x.replace("<queries>", "<queries>\n" + queries_inner.rstrip("\n"), 1)
    else:
        x = x.replace("<application", "<queries>\n" + queries_inner + "    </queries>\n\n    <application", 1)

# экран объяснения разрешений для Health Connect (внутри MainActivity)
MARK = "interlight:health-rationale"
_activity = re.search(r"<activity\b.*?</activity>", x, re.S)
_has_rationale = bool(_activity and "ACTION_SHOW_PERMISSIONS_RATIONALE" in _activity.group(0))
if MARK not in x and not _has_rationale:
    x = x.replace(
        "</activity>",
        "    <intent-filter>\n"
        f"                <!-- {MARK} -->\n"
        '                <action android:name="androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE"/>\n'
        "            </intent-filter>\n"
        "        </activity>",
        1,
    )

extra = ""
if "ScheduledNotificationReceiver" not in x:
    extra += (
        '        <receiver android:exported="false"\n'
        '            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />\n'
        '        <receiver android:exported="false"\n'
        '            android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">\n'
        "            <intent-filter>\n"
        '                <action android:name="android.intent.action.BOOT_COMPLETED"/>\n'
        '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>\n'
        '                <action android:name="android.intent.action.QUICKBOOT_POWERON"/>\n'
        '                <action android:name="com.htc.intent.action.QUICKBOOT_POWERON"/>\n'
        "            </intent-filter>\n"
        "        </receiver>\n"
    )
if "ViewPermissionUsageActivity" not in x:
    extra += (
        "        <activity-alias\n"
        '            android:name="ViewPermissionUsageActivity"\n'
        '            android:exported="true"\n'
        '            android:targetActivity=".MainActivity"\n'
        '            android:permission="android.permission.START_VIEW_PERMISSION_USAGE">\n'
        "            <intent-filter>\n"
        '                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>\n'
        '                <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>\n'
        "            </intent-filter>\n"
        "        </activity-alias>\n"
    )
if extra:
    if "    </application>" in x:
        x = x.replace("    </application>", extra + "    </application>", 1)
    else:
        x = x.replace("</application>", extra + "</application>", 1)

try:
    xml.dom.minidom.parseString(x.encode("utf-8"))
except Exception as e:  # noqa: BLE001
    fail("AndroidManifest.xml после правки не читается как XML: " + str(e))
manifest_path.write_text(x, encoding="utf-8")
print("OK AndroidManifest.xml")

# ───────────────────────── 3. MainActivity.kt ─────────────────────────
kotlin_dir = pathlib.Path("android/app/src/main/kotlin") / pathlib.Path(*PACKAGE.split("."))
kotlin_dir.mkdir(parents=True, exist_ok=True)
# MainActivity: FlutterFragmentActivity для Health Connect и канал, отдающий часовой пояс телефона
# (он заменяет сторонний плагин flutter_timezone, который не собирается с новым Flutter).
(kotlin_dir / "MainActivity.kt").write_text(
    f"""package {PACKAGE}

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterFragmentActivity() {{
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {{
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "interlight/timezone")
            .setMethodCallHandler {{ call, result ->
                if (call.method == "getLocalTimezone") {{
                    result.success(TimeZone.getDefault().id)
                }} else {{
                    result.notImplemented()
                }}
            }}
    }}
}}
""",
    encoding="utf-8",
)
print("OK MainActivity.kt")

# ───────────────────────── 4. gradle.properties ─────────────────────────
# Плагины вроде flutter_timezone собраны с Java 11 и Kotlin 1.8; Gradle считает это ошибкой
# («Inconsistent JVM Target Compatibility»). Переводим проверку в предупреждение.
props_path = pathlib.Path("android/gradle.properties")
props = props_path.read_text(encoding="utf-8") if props_path.exists() else ""
JVM_LINE = "kotlin.jvm.target.validation.mode=warning"
if JVM_LINE not in props:
    props = props.rstrip("\n") + ("\n" if props.strip() else "") + JVM_LINE + "\n"
    props_path.write_text(props, encoding="utf-8")
print("OK gradle.properties")

print("\n===== итоговый build.gradle.kts =====")
print(g)
