#!/usr/bin/env python3
"""Донастраивает Android-проект под InterLight."""
import pathlib
import re
import sys
import xml.dom.minidom

PACKAGE = "com.germanva.interlight"
DESUGAR = 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")'

def fail(msg):
    print("ОШИБКА: " + msg)
    sys.exit(1)

# ───────────────────────── 0. gradle.properties (ГЛОБАЛЬНАЯ НАСТРОЙКА) ─────────────────────────
# Это решает проблему Inconsistent JVM Target для ВСЕХ плагинов
props_path = pathlib.Path("android/gradle.properties")
if props_path.exists():
    props = props_path.read_text(encoding="utf-8")
else:
    props = ""

# Добавляем или обновляем настройки JVM
jvm_settings = [
    "org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=512m",
    "kotlin.jvm.target.validation.mode = IGNORE", # Игнорируем проверку версий (безопасно для Flutter)
]

for setting in jvm_settings:
    key = setting.split("=")[0].strip()
    if key not in props:
        props += "\n" + setting
    else:
        # Если ключ уже есть, обновляем значение
        props = re.sub(re.escape(key) + r".*", setting, props)

props_path.write_text(props.strip() + "\n", encoding="utf-8")
print("✅ Настроен android/gradle.properties (Global JVM Fix)")


# ───────────────────────── 1. build.gradle.kts ─────────────────────────
gradle_path = pathlib.Path("android/app/build.gradle.kts")
if not gradle_path.exists():
    fail("не найден android/app/build.gradle.kts")
    
g = gradle_path.read_text(encoding="utf-8")

# Настраиваем Java 11 локально для приложения
g = re.sub(r'JavaVersion\.VERSION_1_8', 'JavaVersion.VERSION_11', g)
g = re.sub(r'jvmTarget\s*=\s*"[^"]*"', 'jvmTarget = "11"', g)

# minSdk 26
if re.search(r"minSdk\s*=", g):
    g = re.sub(r"minSdk\s*=\s*[^\n]+", "minSdk = 26", g)
else:
    g = re.sub(r"(defaultConfig\s*\{)", r"\1\n        minSdk = 26", g, count=1)

# Desugaring
if "isCoreLibraryDesugaringEnabled" in g:
    g = re.sub(r"isCoreLibraryDesugaringEnabled\s*=\s*false", "isCoreLibraryDesugaringEnabled = true", g)
elif re.search(r"compileOptions\s*\{", g):
    g = re.sub(r"(compileOptions\s*\{)", r"\1\n        isCoreLibraryDesugaringEnabled = true", g, count=1)
else:
    g = re.sub(r"(android\s*\{)", r"\1\n    compileOptions {\n        isCoreLibraryDesugaringEnabled = true\n    }", g, count=1)

# Зависимость desugar
if "coreLibraryDesugaring(" not in g:
    if re.search(r'^dependencies\s*\{', g, re.MULTILINE):
        g = re.sub(r'(dependencies\s*\{)', r'\1\n    ' + DESUGAR, g, count=1)
    else:
        g = g.rstrip() + "\n\ndependencies {\n    " + DESUGAR + "\n}\n"

# Проверки
if "isCoreLibraryDesugaringEnabled = true" not in g: fail("не удалось включить desugaring")
if DESUGAR not in g: fail("не удалось добавить зависимость desugaring")
if not re.search(r"minSdk\s*=\s*26", g): fail("не удалось выставить minSdk = 26")

gradle_path.write_text(g, encoding="utf-8")
print("OK build.gradle.kts")

# ───────────────────────── 2. AndroidManifest.xml ─────────────────────────
manifest_path = pathlib.Path("android/app/src/main/AndroidManifest.xml")
if not manifest_path.exists(): fail("не найден AndroidManifest.xml")
x = manifest_path.read_text(encoding="utf-8")

permissions = [
    "android.permission.CAMERA", "android.permission.POST_NOTIFICATIONS",
    "android.permission.RECEIVE_BOOT_COMPLETED", "android.permission.ACTIVITY_RECOGNITION",
    "android.permission.health.READ_STEPS",
]
perm_xml = ""
for p in permissions:
    if f'android:name="{p}"' not in x:
        perm_xml += f'    <uses-permission android:name="{p}"/>\n'
if perm_xml:
    x = re.sub(r"(<manifest[^>]*>\s*\n)", lambda m: m.group(1) + perm_xml, x, count=1)

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
        "        </activity>", 1)

extra = ""
if "ScheduledNotificationReceiver" not in x:
    extra += (
        '        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationReceiver" />\n'
        '        <receiver android:exported="false" android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver">\n'
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
        "        <activity-alias android:name=\"ViewPermissionUsageActivity\" android:exported=\"true\" android:targetActivity=\".MainActivity\" android:permission=\"android.permission.START_VIEW_PERMISSION_USAGE\">\n"
        "            <intent-filter>\n"
        '                <action android:name="android.intent.action.VIEW_PERMISSION_USAGE"/>\n'
        '                <category android:name="android.intent.category.HEALTH_PERMISSIONS"/>\n'
        "            </intent-filter>\n"
        "        </activity-alias>\n"
    )
if extra:
    x = x.replace("    </application>", extra + "    </application>", 1) if "    </application>" in x else x.replace("</application>", extra + "</application>", 1)

try:
    xml.dom.minidom.parseString(x.encode("utf-8"))
except Exception as e:
    fail("AndroidManifest.xml error: " + str(e))
manifest_path.write_text(x, encoding="utf-8")
print("OK AndroidManifest.xml")

# ───────────────────────── 3. MainActivity.kt ─────────────────────────
kotlin_dir = pathlib.Path("android/app/src/main/kotlin") / pathlib.Path(*PACKAGE.split("."))
kotlin_dir.mkdir(parents=True, exist_ok=True)
(kotlin_dir / "MainActivity.kt").write_text(
    f"package {PACKAGE}\n\nimport io.flutter.embedding.android.FlutterFragmentActivity\n\nclass MainActivity : FlutterFragmentActivity()\n",
    encoding="utf-8",
)
print("OK MainActivity.kt")
print("\n===== DONE =====")