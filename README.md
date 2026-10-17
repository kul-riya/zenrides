# ZenRides

Flutter ride HUD for a motorcycle pack. The map shows you and the riders around you. Pack holds the riding group code and the END button.

## Run it

Copy `.env.example` to `.env` and fill in `MAPS_API_KEY` (optional—only needed for web route planning).

```bash
flutter pub get
flutter build web --release --no-web-resources-cdn --dart-define-from-file=.env
python3 -m http.server 43123 --bind 0.0.0.0 --directory build/web
```

Then open http://127.0.0.1:43123.

On a phone:

```bash
flutter run --dart-define-from-file=.env
```

Or on Chrome for desktop:

```bash
flutter run -d chrome --dart-define-from-file=.env
```

## What is on screen

- Ride HUD: the live map, broadcasts, today's plan, fuel pumps, and SOS.
- Recenter sits at the bottom right of the map and zooms to 200% on the green YOU marker.
- Pack: the riding group code, END, each rider's distance, and Remove. Speed is not shown there.
- Removing a rider clears their dot, name, and SOS pin.
