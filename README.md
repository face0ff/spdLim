# SpeedLimit 🚗

Спидометр с отображением текущего и следующего ограничения скорости на дороге.

## Функции
- 🔢 Большой спидометр (км/ч)
- 🟢🟡🔴 Цветная рамка (зелёная / жёлтая / красная)
- 🛑 Текущее ограничение скорости (OSM / Overpass)
- ➡️ Следующее ограничение впереди (~300 м)
- 📳 Вибрация при превышении
- 📵 Экран не гаснет во время езды

---

## Как получить APK (без установки Flutter)

### Вариант 1: GitHub Actions (автоматически)

1. Зарегистрируйся на [github.com](https://github.com) если нет аккаунта
2. Создай новый репозиторий (New repository → любое имя → Create)
3. Загрузи все файлы этого проекта в репозиторий:
   - Нажми **"uploading an existing file"** → перетащи все файлы
   - Или используй Git:
     ```bash
     git init
     git add .
     git commit -m "Initial commit"
     git remote add origin https://github.com/ВАШ_НИК/ВАШ_РЕПО.git
     git push -u origin main
     ```
4. Перейди во вкладку **Actions** в репозитории
5. Подожди 3–5 минут пока сборка завершится (зелёная галочка)
6. Нажми на сборку → **Artifacts** → скачай `speedlimit-release-apk.zip`
7. Разархивируй → установи `app-release.apk` на Android

> ⚠️ На телефоне нужно разрешить установку из неизвестных источников:
> Настройки → Безопасность → Установка неизвестных приложений → разрешить для браузера/файлового менеджера

---

### Вариант 2: Собери сам (если есть Flutter)

```bash
flutter pub get
flutter build apk --release
# APK будет в: build/app/outputs/flutter-apk/app-release.apk
```

---

## Технологии
- **Flutter 3.24+**
- **geolocator** — GPS и скорость
- **Overpass API** (OpenStreetMap) — ограничения скорости, бесплатно
- **wakelock_plus** — экран не гаснет
- **vibration** — вибрация при превышении

## Данные о лимитах
Данные берутся с [OpenStreetMap](https://openstreetmap.org) через [Overpass API](https://overpass-api.de).
Точность зависит от наполнения карты в вашем регионе.
