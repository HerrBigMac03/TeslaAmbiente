#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <Update.h>
#include <esp_now.h>
#include <esp_wifi.h>
#include <esp_task_wdt.h>
#include <esp_idf_version.h>
#include <Preferences.h>
#include <Adafruit_NeoPixel.h>

// =======================================================
// EINSTELLUNGEN SLAVE
// =======================================================

// HIER PRO TUER ANPASSEN:
// 'F' = vorne rechts
// 'G' = vorne links
// 'R' = hinten links
// 'L' = hinten rechts
//
// Vorne rechts:
#define DEVICE_SIDE 'F'

#define LED_PIN 21
#define NUM_LEDS 130

// Fuer WS2812 / WS2812B / normale 3-polige RGB-LEDs
#define LED_TYPE NEO_GRB + NEO_KHZ800

// Muss identisch mit Master sein
#define ESPNOW_CHANNEL 6

// OTA wird nur per Master-Befehl geoeffnet und nach 10 Minuten geschlossen.
#define OTA_AP_PASS "12345678"
#define OTA_DEFAULT_MINUTES 10
#define OTA_MAX_MINUTES 30
#define LED_ACK_PACKET_TYPE 0xA8
#define POWER_FADE_MS 1200
#define POWER_FADE_FRAME_MS 16
#define COLOR_FADE_MS 450

uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};
Adafruit_NeoPixel strip(NUM_LEDS, LED_PIN, LED_TYPE);
Preferences prefs;
WebServer server(80);

// =======================================================
// DATENPAKET — MUSS EXAKT WIE BEIM MASTER SEIN
// =======================================================

typedef struct __attribute__((packed)) {
  uint8_t magic;       // 0xA7
  uint8_t version;     // 2

  char target;         // 'L', 'R', 'F', 'G', 'D', 'A'

  uint8_t power;       // 0 = aus, 1 = an
  uint8_t mode;        // 0 = normal, 1 = Totwinkel
  uint8_t effect;      // Effekt-ID

  uint8_t r1;
  uint8_t g1;
  uint8_t b1;

  uint8_t r2;
  uint8_t g2;
  uint8_t b2;

  uint8_t r3;
  uint8_t g3;
  uint8_t b3;

  uint8_t brightness;  // 0-255
  uint8_t speed;       // 1-255
  uint8_t intensity;   // 0-255
  uint8_t progress;    // 0-100
  uint16_t ledStart;    // erste aktive LED, 0-basiert
  uint16_t ledEnd;      // letzte aktive LED, 0-basiert

  uint32_t sequence;
} LedCommand;

typedef struct __attribute__((packed)) {
  uint8_t packetType;  // 0xA8
  uint8_t magic;       // 0xA7
  uint8_t version;     // 1
  char device;         // dieser Slave
  char target;         // empfangener Command-Target
  uint32_t sequence;
  uint8_t accepted;
} LedAckPacket;

typedef struct __attribute__((packed)) {
  uint8_t magic;       // 0xC6
  uint8_t version;     // 1
  uint8_t command;     // 3 = Door OTA AP starten
  uint8_t minutes;     // Laufzeit
  uint32_t nonce;
} SystemCommand;

LedCommand currentCmd;
LedCommand lastSavedCmd;

uint32_t lastPacketMs = 0;
uint32_t lastSequence = 0;
uint32_t lastEffectMs = 0;
uint32_t lastStatusMs = 0;
uint32_t lastSaveRequestMs = 0;
uint32_t otaApUntilMs = 0;
uint32_t powerFadeStartMs = 0;
uint32_t lastPowerFadeFrameMs = 0;
uint32_t colorFadeStartMs = 0;

uint16_t effectStep = 0;
int scannerPos = 0;
int scannerDir = 1;
uint8_t powerFadeMode = 0; // 0=aus, 1=einblenden, 2=ausblenden
bool colorFadeActive = false;

bool pendingSave = false;
bool hasLoadedState = false;

uint16_t activeLedStart() {
  if (currentCmd.ledStart >= NUM_LEDS) return 0;
  if (currentCmd.ledStart > currentCmd.ledEnd) return 0;
  return currentCmd.ledStart;
}

uint16_t activeLedEnd() {
  if (currentCmd.ledEnd >= NUM_LEDS) return NUM_LEDS - 1;
  if (currentCmd.ledStart > currentCmd.ledEnd) return NUM_LEDS - 1;
  return currentCmd.ledEnd;
}

bool ledInActiveRange(int index) {
  return index >= activeLedStart() && index <= activeLedEnd();
}

void setPixel(int index, uint32_t color) {
  if (index < 0 || index >= NUM_LEDS) return;
  if (!ledInActiveRange(index)) return;
  strip.setPixelColor(index, color);
}

void showStrip() {
  uint16_t start = activeLedStart();
  uint16_t end = activeLedEnd();
  for (int i = 0; i < NUM_LEDS; i++) {
    if (i < start || i > end) strip.setPixelColor(i, 0);
  }
  strip.show();
}
bool otaApActive = false;

uint8_t fadeOutR = 0;
uint8_t fadeOutG = 0;
uint8_t fadeOutB = 0;
uint8_t fadeOutBrightness = 0;
uint8_t colorFadeStartR = 0;
uint8_t colorFadeStartG = 0;
uint8_t colorFadeStartB = 0;

// =======================================================
// WATCHDOG
// =======================================================

void setupWatchdog() {
#if ESP_IDF_VERSION_MAJOR >= 5
  esp_task_wdt_config_t wdt_config = {
    .timeout_ms = 5000,
    .idle_core_mask = (1 << portNUM_PROCESSORS) - 1,
    .trigger_panic = true
  };
  esp_task_wdt_init(&wdt_config);
  esp_task_wdt_add(NULL);
#else
  esp_task_wdt_init(5, true);
  esp_task_wdt_add(NULL);
#endif

  Serial.println("Watchdog aktiv");
}

// =======================================================
// HILFSFUNKTIONEN
// =======================================================

uint32_t makeColor(uint8_t r, uint8_t g, uint8_t b) {
  return strip.Color(r, g, b);
}

uint32_t color1() {
  return makeColor(currentCmd.r1, currentCmd.g1, currentCmd.b1);
}

uint32_t color2() {
  return makeColor(currentCmd.r2, currentCmd.g2, currentCmd.b2);
}

uint32_t color3() {
  return makeColor(currentCmd.r3, currentCmd.g3, currentCmd.b3);
}

uint8_t scaledByte(uint8_t value, uint8_t scale) {
  return ((uint16_t)value * scale) / 255;
}

uint32_t dimRGB(uint8_t r, uint8_t g, uint8_t b, uint8_t scale) {
  return makeColor(
    scaledByte(r, scale),
    scaledByte(g, scale),
    scaledByte(b, scale)
  );
}

uint32_t dimColor1(uint8_t scale) {
  return dimRGB(currentCmd.r1, currentCmd.g1, currentCmd.b1, scale);
}

bool isStaticColorCommand(const LedCommand &cmd) {
  return cmd.power != 0 && cmd.mode == 0 && cmd.effect == 1;
}

bool isBlindSpotDoorOrange(const LedCommand &cmd) {
  return isStaticColorCommand(cmd) &&
         cmd.r1 == 255 &&
         cmd.g1 == 120 &&
         cmd.b1 == 0;
}

uint8_t colorFadeAmount() {
  if (!colorFadeActive) return 255;

  uint32_t elapsed = millis() - colorFadeStartMs;
  if (elapsed >= COLOR_FADE_MS) {
    colorFadeActive = false;
    return 255;
  }

  return (uint32_t)elapsed * 255 / COLOR_FADE_MS;
}

uint8_t easeFadeByte(uint8_t amount) {
  uint32_t t = amount;
  return (t * t * (765 - (2 * t))) / 65025;
}

void clearStrip() {
  strip.clear();
  showStrip();
}

void setAll(uint32_t c) {
  for (int i = 0; i < NUM_LEDS; i++) {
    setPixel(i, c);
  }
  showStrip();
}

uint16_t effectInterval() {
  uint8_t spd = currentCmd.speed;
  if (spd < 1) spd = 1;

  return map(spd, 1, 255, 160, 5);
}

bool effectTick() {
  uint32_t now = millis();
  uint16_t interval = effectInterval();

  if (now - lastEffectMs >= interval) {
    lastEffectMs = now;
    effectStep++;
    return true;
  }

  return false;
}

uint32_t wheel(byte pos) {
  pos = 255 - pos;

  if (pos < 85) {
    return makeColor(255 - pos * 3, 0, pos * 3);
  }

  if (pos < 170) {
    pos -= 85;
    return makeColor(0, pos * 3, 255 - pos * 3);
  }

  pos -= 170;
  return makeColor(pos * 3, 255 - pos * 3, 0);
}

String otaSsid() {
  return "Tesla-Door-" + String(DEVICE_SIDE) + "-OTA";
}

// =======================================================
// SPEICHERLOGIK
// =======================================================

bool commandContentChanged(const LedCommand &a, const LedCommand &b) {
  if (a.power != b.power) return true;
  if (a.mode != b.mode) return true;
  if (a.effect != b.effect) return true;

  if (a.r1 != b.r1 || a.g1 != b.g1 || a.b1 != b.b1) return true;
  if (a.r2 != b.r2 || a.g2 != b.g2 || a.b2 != b.b2) return true;
  if (a.r3 != b.r3 || a.g3 != b.g3 || a.b3 != b.b3) return true;

  if (a.brightness != b.brightness) return true;
  if (a.speed != b.speed) return true;
  if (a.intensity != b.intensity) return true;
  if (a.progress != b.progress) return true;
  if (a.ledStart != b.ledStart) return true;
  if (a.ledEnd != b.ledEnd) return true;

  return false;
}

void saveLastCommandNow() {
  prefs.begin("ledstate", false);
  prefs.putBytes("cmd", &currentCmd, sizeof(currentCmd));
  prefs.end();

  lastSavedCmd = currentCmd;
  pendingSave = false;

  Serial.println("LED-Zustand gespeichert");
}

bool loadLastCommand() {
  prefs.begin("ledstate", true);

  size_t len = prefs.getBytesLength("cmd");

  if (len != sizeof(currentCmd)) {
    prefs.end();
    Serial.println("Kein gespeicherter LED-Zustand vorhanden");
    return false;
  }

  prefs.getBytes("cmd", &currentCmd, sizeof(currentCmd));
  prefs.end();

  if (currentCmd.magic != 0xA7 || currentCmd.version != 2) {
    Serial.println("Gespeicherter Zustand ungueltig");
    return false;
  }

  lastSavedCmd = currentCmd;
  Serial.println("Gespeicherter LED-Zustand geladen");
  return true;
}

void setDefaultOffState() {
  currentCmd.magic = 0xA7;
  currentCmd.version = 2;
  currentCmd.target = DEVICE_SIDE;

  currentCmd.power = 0;
  currentCmd.mode = 0;
  currentCmd.effect = 0;

  currentCmd.r1 = 0;
  currentCmd.g1 = 0;
  currentCmd.b1 = 0;

  currentCmd.r2 = 0;
  currentCmd.g2 = 0;
  currentCmd.b2 = 0;

  currentCmd.r3 = 0;
  currentCmd.g3 = 0;
  currentCmd.b3 = 0;

  currentCmd.brightness = 0;
  currentCmd.speed = 120;
  currentCmd.intensity = 120;
  currentCmd.progress = 0;
  currentCmd.ledStart = 0;
  currentCmd.ledEnd = NUM_LEDS - 1;
  currentCmd.sequence = 0;

  lastSavedCmd = currentCmd;

  Serial.println("Kein Speicherzustand: LEDs bleiben aus");
}

// =======================================================
// EFFEKTE
// =======================================================

void effectOff() {
  clearStrip();
}

void effectStatic() {
  if (!colorFadeActive) {
    setAll(color1());
    return;
  }

  uint8_t amount = colorFadeAmount();
  uint8_t r = colorFadeStartR + (((int16_t)currentCmd.r1 - colorFadeStartR) * amount) / 255;
  uint8_t g = colorFadeStartG + (((int16_t)currentCmd.g1 - colorFadeStartG) * amount) / 255;
  uint8_t b = colorFadeStartB + (((int16_t)currentCmd.b1 - colorFadeStartB) * amount) / 255;

  setAll(makeColor(r, g, b));
}

void effectBreathing() {
  if (!effectTick()) return;

  float phase = (sin(effectStep * 0.06) + 1.0) / 2.0;
  uint8_t scale = 8 + phase * 247;

  setAll(dimColor1(scale));
}

void effectBlink() {
  if (!effectTick()) return;

  bool on = (effectStep % 2) == 0;

  if (on) {
    setAll(color1());
  } else {
    clearStrip();
  }
}

void effectRainbow() {
  if (!effectTick()) return;

  for (int i = 0; i < NUM_LEDS; i++) {
    setPixel(i, wheel((i * 256 / NUM_LEDS + effectStep) & 255));
  }

  showStrip();
}

void effectColorWipe() {
  if (!effectTick()) return;

  int pos = effectStep % (NUM_LEDS + 15);

  strip.clear();

  for (int i = 0; i < pos && i < NUM_LEDS; i++) {
    setPixel(i, color1());
  }

  showStrip();
}

void effectScanner() {
  if (!effectTick()) return;

  strip.clear();

  for (int i = 0; i < NUM_LEDS; i++) {
    int distance = abs(i - scannerPos);

    if (distance == 0) {
      setPixel(i, color1());
    } else if (distance < 8) {
      uint8_t fade = 255 - distance * 30;
      setPixel(i, dimColor1(fade));
    }
  }

  showStrip();

  scannerPos += scannerDir;

  if (scannerPos >= NUM_LEDS - 1) {
    scannerPos = NUM_LEDS - 1;
    scannerDir = -1;
  }

  if (scannerPos <= 0) {
    scannerPos = 0;
    scannerDir = 1;
  }
}

void effectTheaterChase() {
  if (!effectTick()) return;

  strip.clear();

  for (int i = 0; i < NUM_LEDS; i++) {
    if ((i + effectStep) % 3 == 0) {
      setPixel(i, color1());
    }
  }

  showStrip();
}

void effectRunningLights() {
  if (!effectTick()) return;

  for (int i = 0; i < NUM_LEDS; i++) {
    float level = (sin((i + effectStep) * 0.25) + 1.0) / 2.0;
    uint8_t scale = level * 255;
    setPixel(i, dimColor1(scale));
  }

  showStrip();
}

void effectSparkle() {
  if (!effectTick()) return;

  for (int i = 0; i < NUM_LEDS; i++) {
    uint32_t old = strip.getPixelColor(i);

    uint8_t r = (uint8_t)(old >> 16);
    uint8_t g = (uint8_t)(old >> 8);
    uint8_t b = (uint8_t)(old);

    r = r * 180 / 255;
    g = g * 180 / 255;
    b = b * 180 / 255;

    setPixel(i, makeColor(r, g, b));
  }

  int sparkles = map(currentCmd.intensity, 0, 255, 1, 12);

  for (int s = 0; s < sparkles; s++) {
    int pos = random(NUM_LEDS);
    setPixel(pos, color1());
  }

  showStrip();
}

void effectFire() {
  if (!effectTick()) return;

  for (int i = 0; i < NUM_LEDS; i++) {
    uint8_t heat = random(80, 255);
    uint8_t flicker = random(0, 80);

    uint8_t r = 255;
    uint8_t g = constrain(heat - flicker, 20, 160);
    uint8_t b = random(0, 20);

    setPixel(i, makeColor(r, g, b));
  }

  showStrip();
}

void effectPolice() {
  if (!effectTick()) return;

  bool phase = ((effectStep / 5) % 2) == 0;

  uint32_t red = makeColor(255, 0, 0);
  uint32_t blue = makeColor(0, 0, 255);

  for (int i = 0; i < NUM_LEDS; i++) {
    if (i < NUM_LEDS / 2) {
      setPixel(i, phase ? red : blue);
    } else {
      setPixel(i, phase ? blue : red);
    }
  }

  showStrip();
}

void effectProgressBar() {
  int lit = map(constrain(currentCmd.progress, 0, 100), 0, 100, 0, NUM_LEDS);

  strip.clear();

  for (int i = 0; i < lit; i++) {
    setPixel(i, color1());
  }

  showStrip();
}

void effectSoftFade() {
  if (!effectTick()) return;

  float phase = (sin(effectStep * 0.035) + 1.0) / 2.0;
  uint8_t scale = phase * 255;

  setAll(dimColor1(scale));
}

void effectStrobe() {
  if (!effectTick()) return;

  bool on = (effectStep % 2) == 0;

  if (on) {
    setAll(color1());
  } else {
    clearStrip();
  }
}

void effectMeteorRain() {
  if (!effectTick()) return;

  for (int i = 0; i < NUM_LEDS; i++) {
    uint32_t old = strip.getPixelColor(i);

    uint8_t r = (uint8_t)(old >> 16);
    uint8_t g = (uint8_t)(old >> 8);
    uint8_t b = (uint8_t)(old);

    r = r * 170 / 255;
    g = g * 170 / 255;
    b = b * 170 / 255;

    setPixel(i, makeColor(r, g, b));
  }

  int meteorSize = map(currentCmd.intensity, 0, 255, 4, 18);
  int pos = effectStep % (NUM_LEDS + meteorSize);

  for (int j = 0; j < meteorSize; j++) {
    int p = pos - j;

    if (p >= 0 && p < NUM_LEDS) {
      uint8_t fade = 255 - (j * 255 / meteorSize);
      setPixel(p, dimColor1(fade));
    }
  }

  showStrip();
}

void effectTwoColorFade() {
  if (!effectTick()) return;

  float phase = (sin(effectStep * 0.04) + 1.0) / 2.0;

  uint8_t r = currentCmd.r1 * (1.0 - phase) + currentCmd.r2 * phase;
  uint8_t g = currentCmd.g1 * (1.0 - phase) + currentCmd.g2 * phase;
  uint8_t b = currentCmd.b1 * (1.0 - phase) + currentCmd.b2 * phase;

  setAll(makeColor(r, g, b));
}

void effectThreeColorFade() {
  if (!effectTick()) return;

  uint16_t phase = effectStep % 768;
  uint8_t r, g, b;

  if (phase < 256) {
    float t = phase / 255.0;
    r = currentCmd.r1 * (1.0 - t) + currentCmd.r2 * t;
    g = currentCmd.g1 * (1.0 - t) + currentCmd.g2 * t;
    b = currentCmd.b1 * (1.0 - t) + currentCmd.b2 * t;
  } else if (phase < 512) {
    float t = (phase - 256) / 255.0;
    r = currentCmd.r2 * (1.0 - t) + currentCmd.r3 * t;
    g = currentCmd.g2 * (1.0 - t) + currentCmd.g3 * t;
    b = currentCmd.b2 * (1.0 - t) + currentCmd.b3 * t;
  } else {
    float t = (phase - 512) / 255.0;
    r = currentCmd.r3 * (1.0 - t) + currentCmd.r1 * t;
    g = currentCmd.g3 * (1.0 - t) + currentCmd.g1 * t;
    b = currentCmd.b3 * (1.0 - t) + currentCmd.b1 * t;
  }

  setAll(makeColor(r, g, b));
}

void effectBlindSpot() {
  if (!effectTick()) return;

  bool flash = (effectStep % 2) == 0;

  if (flash) {
    setAll(color1());
  } else {
    setAll(color2());
  }
}

// =======================================================
// EFFEKTSTEUERUNG
// =======================================================

void runEffect() {
  if (powerFadeMode == 2) {
    runPowerFadeOut();
    return;
  }

  if (currentCmd.power == 0 || currentCmd.effect == 0) {
    effectOff();
    return;
  }

  strip.setBrightness(scaledByte(currentCmd.brightness, powerFadeScale()));

  // Totwinkel-Modus hat Prioritaet
  if (currentCmd.mode == 1 || currentCmd.effect == 20) {
    effectBlindSpot();
    return;
  }

  switch (currentCmd.effect) {
    case 1:
      effectStatic();
      break;
    case 2:
      effectBreathing();
      break;
    case 3:
      effectBlink();
      break;
    case 4:
      effectRainbow();
      break;
    case 5:
      effectColorWipe();
      break;
    case 6:
      effectScanner();
      break;
    case 7:
      effectTheaterChase();
      break;
    case 8:
      effectRunningLights();
      break;
    case 9:
      effectSparkle();
      break;
    case 10:
      effectFire();
      break;
    case 11:
      effectPolice();
      break;
    case 12:
      effectProgressBar();
      break;
    case 13:
      effectSoftFade();
      break;
    case 14:
      effectStrobe();
      break;
    case 15:
      effectMeteorRain();
      break;
    case 16:
      effectTwoColorFade();
      break;
    case 17:
      effectThreeColorFade();
      break;
    case 18:
      effectRainbow();
      break;
    case 19:
      effectRainbow();
      break;
    case 20:
      effectBlindSpot();
      break;
    default:
      effectStatic();
      break;
  }
}

// =======================================================
// ESP-NOW EMPFANG
// =======================================================

void resetEffectState() {
  lastEffectMs = 0;
  effectStep = 0;
  scannerPos = 0;
  scannerDir = 1;
}

uint8_t powerFadeScale() {
  if (powerFadeMode == 0) return 255;

  uint32_t elapsed = millis() - powerFadeStartMs;
  if (elapsed >= POWER_FADE_MS) {
    if (powerFadeMode == 2) {
      powerFadeMode = 0;
      return 0;
    }

    powerFadeMode = 0;
    return 255;
  }

  uint8_t progress = easeFadeByte((uint32_t)elapsed * 255 / POWER_FADE_MS);
  return powerFadeMode == 1 ? progress : 255 - progress;
}

void startPowerFade(const LedCommand &oldCmd, const LedCommand &newCmd) {
  if (oldCmd.power == 0 && newCmd.power != 0) {
    powerFadeMode = 1;
    powerFadeStartMs = millis();
    lastPowerFadeFrameMs = 0;
    return;
  }

  if (oldCmd.power != 0 && newCmd.power == 0) {
    powerFadeMode = 2;
    powerFadeStartMs = millis();
    lastPowerFadeFrameMs = 0;
    fadeOutR = oldCmd.r1;
    fadeOutG = oldCmd.g1;
    fadeOutB = oldCmd.b1;
    fadeOutBrightness = oldCmd.brightness;
    return;
  }
}

void startColorFadeIfNeeded(const LedCommand &oldCmd, const LedCommand &newCmd) {
  colorFadeActive = false;

  if (!isStaticColorCommand(oldCmd)) return;
  if (!isStaticColorCommand(newCmd)) return;
  if (oldCmd.r1 == newCmd.r1 && oldCmd.g1 == newCmd.g1 && oldCmd.b1 == newCmd.b1) return;

  // Warn-Orange soll sofort kommen. Nur der Rueckweg zur Grundfarbe blendet weich.
  if (isBlindSpotDoorOrange(newCmd)) return;

  colorFadeStartR = oldCmd.r1;
  colorFadeStartG = oldCmd.g1;
  colorFadeStartB = oldCmd.b1;
  colorFadeStartMs = millis();
  colorFadeActive = true;
}

void runPowerFadeOut() {
  uint32_t now = millis();
  if (lastPowerFadeFrameMs != 0 && now - lastPowerFadeFrameMs < POWER_FADE_FRAME_MS) {
    return;
  }
  lastPowerFadeFrameMs = now;

  uint8_t scale = powerFadeScale();

  if (scale == 0) {
    strip.setBrightness(0);
    clearStrip();
    return;
  }

  strip.setBrightness(fadeOutBrightness);
  setAll(dimRGB(fadeOutR, fadeOutG, fadeOutB, scale));
}

String otaPage() {
  String page;
  page += "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>";
  page += "<title>Door OTA</title></head><body style='font-family:system-ui;margin:24px;background:#101214;color:#f4f4f4'>";
  page += "<h1>Door Slave ";
  page += DEVICE_SIDE;
  page += " Firmware Update</h1>";
  page += "<p>Firmware .bin auswaehlen und hochladen.</p>";
  page += "<form method='POST' action='/update' enctype='multipart/form-data'>";
  page += "<input type='file' name='update'><button type='submit'>Tuer flashen</button></form>";
  page += "<p><a href='/'>Status</a></p></body></html>";
  return page;
}

String statusPage() {
  String page;
  page += "<!doctype html><html><head><meta name='viewport' content='width=device-width,initial-scale=1'>";
  page += "<meta http-equiv='refresh' content='3'>";
  page += "<title>Door OTA</title></head><body style='font-family:system-ui;margin:24px;background:#101214;color:#f4f4f4'>";
  page += "<h1>Door Slave ";
  page += DEVICE_SIDE;
  page += " OTA</h1>";
  page += "<p>Seite: ";
  page += DEVICE_SIDE;
  page += "</p>";
  page += "<p>Effekt: " + String(currentCmd.effect) + " | Mode: " + String(currentCmd.mode) + "</p>";
  page += "<p>Letztes LED-Paket: " + String(lastPacketMs == 0 ? -1 : (int)((millis() - lastPacketMs) / 1000)) + " s</p>";
  page += "<p>Hotspot: " + otaSsid() + " | Passwort: " + String(OTA_AP_PASS) + "</p>";
  page += "<p>Der Hotspot schaltet sich automatisch wieder aus.</p>";
  page += "<p><a href='/update'>OTA Update</a></p></body></html>";
  return page;
}

void setupWebOta() {
  server.on("/", HTTP_GET, []() {
    server.send(200, "text/html", statusPage());
  });

  server.on("/update", HTTP_GET, []() {
    server.send(200, "text/html", otaPage());
  });

  server.on(
    "/update",
    HTTP_POST,
    []() {
      server.sendHeader("Connection", "close");
      server.send(200, "text/plain", Update.hasError() ? "Update failed" : "Update ok, rebooting");
      delay(500);
      ESP.restart();
    },
    []() {
      HTTPUpload &upload = server.upload();

      if (upload.status == UPLOAD_FILE_START) {
        Serial.print("Door OTA start: ");
        Serial.println(upload.filename);
        if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
          Update.printError(Serial);
        }
      } else if (upload.status == UPLOAD_FILE_WRITE) {
        esp_task_wdt_reset();
        if (Update.write(upload.buf, upload.currentSize) != upload.currentSize) {
          Update.printError(Serial);
        }
      } else if (upload.status == UPLOAD_FILE_END) {
        if (Update.end(true)) {
          Serial.print("Door OTA success: ");
          Serial.print(upload.totalSize);
          Serial.println(" bytes");
        } else {
          Update.printError(Serial);
        }
      }
    }
  );

  Serial.println("Door Web OTA vorbereitet. AP startet nur per Master-Befehl.");
}

void startOtaAp(uint8_t minutes) {
  if (minutes < 1) minutes = OTA_DEFAULT_MINUTES;
  if (minutes > OTA_MAX_MINUTES) minutes = OTA_MAX_MINUTES;

  String ssid = otaSsid();
  WiFi.mode(WIFI_AP_STA);
  WiFi.softAP(ssid.c_str(), OTA_AP_PASS, ESPNOW_CHANNEL);
  esp_wifi_set_ps(WIFI_PS_NONE);

  if (!otaApActive) {
    server.begin();
  }

  otaApActive = true;
  otaApUntilMs = millis() + (uint32_t)minutes * 60000UL;

  Serial.print("Door OTA AP aktiv fuer ");
  Serial.print(minutes);
  Serial.println(" Minuten");
  Serial.print("SSID: ");
  Serial.println(ssid);
  Serial.print("IP: ");
  Serial.println(WiFi.softAPIP());
}

void stopOtaAp() {
  if (!otaApActive) return;

  server.stop();
  WiFi.softAPdisconnect(true);
  WiFi.mode(WIFI_STA);
  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_ps(WIFI_PS_NONE);

  otaApActive = false;
  otaApUntilMs = 0;

  Serial.println("Door OTA AP deaktiviert");
}

bool handleSystemCommand(const uint8_t *incomingData, int len) {
  if (len != sizeof(SystemCommand)) return false;

  SystemCommand cmd;
  memcpy(&cmd, incomingData, sizeof(cmd));

  if (cmd.magic != 0xC6) return false;
  if (cmd.version != 1) return false;

  if (cmd.command == 3) {
    startOtaAp(cmd.minutes);
    return true;
  }

  return true;
}

void sendLedAck(const LedCommand &cmd) {
  LedAckPacket ack = {};
  ack.packetType = LED_ACK_PACKET_TYPE;
  ack.magic = 0xA7;
  ack.version = 1;
  ack.device = DEVICE_SIDE;
  ack.target = cmd.target;
  ack.sequence = cmd.sequence;
  ack.accepted = 1;

  esp_now_send(broadcastAddress, (uint8_t*)&ack, sizeof(ack));
}

void applyCommand(const LedCommand &cmd) {
  if (cmd.magic != 0xA7) return;
  if (cmd.version != 2) return;

  if (cmd.target != DEVICE_SIDE && cmd.target != 'A') return;

  if (cmd.sequence == lastSequence) {
    sendLedAck(cmd);
    return;
  }

  lastSequence = cmd.sequence;

  LedCommand normalizedCmd = cmd;
  if (normalizedCmd.ledStart >= NUM_LEDS) normalizedCmd.ledStart = 0;
  if (normalizedCmd.ledEnd >= NUM_LEDS) normalizedCmd.ledEnd = NUM_LEDS - 1;
  if (normalizedCmd.ledStart > normalizedCmd.ledEnd) {
    normalizedCmd.ledStart = 0;
    normalizedCmd.ledEnd = NUM_LEDS - 1;
  }

  bool changed = commandContentChanged(currentCmd, normalizedCmd);
  LedCommand oldCmd = currentCmd;

  currentCmd = normalizedCmd;
  lastPacketMs = millis();
  sendLedAck(normalizedCmd);

  if (changed) {
    pendingSave = true;
    lastSaveRequestMs = millis();
    startPowerFade(oldCmd, normalizedCmd);
    startColorFadeIfNeeded(oldCmd, normalizedCmd);

    if (oldCmd.power == normalizedCmd.power || (oldCmd.power == 0 && normalizedCmd.power != 0)) {
      resetEffectState();
    }
  }

  Serial.println();
  Serial.println("ESP-NOW Paket empfangen");
  Serial.print("Seite: ");
  Serial.println(DEVICE_SIDE);
  Serial.print("Target: ");
  Serial.println(currentCmd.target);
  Serial.print("Power: ");
  Serial.println(currentCmd.power);
  Serial.print("Mode: ");
  Serial.println(currentCmd.mode);
  Serial.print("Effect: ");
  Serial.println(currentCmd.effect);
  Serial.print("Farbe 1 RGB: ");
  Serial.print(currentCmd.r1);
  Serial.print(", ");
  Serial.print(currentCmd.g1);
  Serial.print(", ");
  Serial.println(currentCmd.b1);
  Serial.print("Farbe 2 RGB: ");
  Serial.print(currentCmd.r2);
  Serial.print(", ");
  Serial.print(currentCmd.g2);
  Serial.print(", ");
  Serial.println(currentCmd.b2);
  Serial.print("Farbe 3 RGB: ");
  Serial.print(currentCmd.r3);
  Serial.print(", ");
  Serial.print(currentCmd.g3);
  Serial.print(", ");
  Serial.println(currentCmd.b3);
  Serial.print("Brightness: ");
  Serial.println(currentCmd.brightness);
  Serial.print("Speed: ");
  Serial.println(currentCmd.speed);
  Serial.print("Intensity: ");
  Serial.println(currentCmd.intensity);
  Serial.print("Progress: ");
  Serial.println(currentCmd.progress);
  Serial.print("LED Bereich: ");
  Serial.print(currentCmd.ledStart);
  Serial.print(" bis ");
  Serial.println(currentCmd.ledEnd);
  Serial.print("Sequence: ");
  Serial.println(currentCmd.sequence);
}

#if ESP_IDF_VERSION_MAJOR >= 5
void onDataRecv(const esp_now_recv_info_t *info, const uint8_t *incomingData, int len) {
#else
void onDataRecv(const uint8_t *mac, const uint8_t *incomingData, int len) {
#endif
  if (handleSystemCommand(incomingData, len)) {
    return;
  }

  if (len != sizeof(LedCommand)) {
    Serial.print("Falsche Paketgroesse: ");
    Serial.println(len);
    return;
  }

  LedCommand incomingCmd;
  memcpy(&incomingCmd, incomingData, sizeof(incomingCmd));
  applyCommand(incomingCmd);
}

// =======================================================
// SETUP
// =======================================================

void setup() {
  Serial.begin(115200);
  delay(300);

  Serial.println();
  Serial.println("======================================");
  Serial.println("Tesla Ambiente Front Right Slave V2");
  Serial.print("DEVICE_SIDE: ");
  Serial.println(DEVICE_SIDE);
  Serial.println("======================================");

  setupWatchdog();

  strip.begin();
  strip.setBrightness(0);
  strip.clear();
  strip.show();

  hasLoadedState = loadLastCommand();

  if (!hasLoadedState) {
    setDefaultOffState();
  }

  strip.setBrightness(currentCmd.brightness);

  WiFi.mode(WIFI_STA);
  WiFi.disconnect();

  esp_wifi_set_channel(ESPNOW_CHANNEL, WIFI_SECOND_CHAN_NONE);
  esp_wifi_set_ps(WIFI_PS_NONE);
  setupWebOta();

  Serial.print("Slave MAC: ");
  Serial.println(WiFi.macAddress());
  Serial.print("ESP-NOW Kanal: ");
  Serial.println(ESPNOW_CHANNEL);

  if (esp_now_init() != ESP_OK) {
    Serial.println("ESP-NOW Init Fehler. Neustart...");
    delay(1000);
    ESP.restart();
  }

  esp_now_peer_info_t peerInfo = {};
  memcpy(peerInfo.peer_addr, broadcastAddress, 6);
  peerInfo.channel = ESPNOW_CHANNEL;
  peerInfo.encrypt = false;

  if (!esp_now_is_peer_exist(broadcastAddress)) {
    if (esp_now_add_peer(&peerInfo) != ESP_OK) {
      Serial.println("ESP-NOW Broadcast Peer Fehler. Neustart...");
      delay(1000);
      ESP.restart();
    }
  }

  esp_now_register_recv_cb(onDataRecv);

  Serial.println("ESP-NOW bereit");

  resetEffectState();

  // Direkt gespeicherten Zustand anzeigen, ohne Startfarbe
  runEffect();
}

// =======================================================
// LOOP
// =======================================================

void loop() {
  esp_task_wdt_reset();

  if (otaApActive) {
    server.handleClient();

    if (millis() > otaApUntilMs) {
      stopOtaAp();
    }
  }

  runEffect();

  // Speichern nicht direkt im Empfangs-Callback, sondern sauber im Loop
  if (pendingSave && millis() - lastSaveRequestMs > 250) {
    saveLastCommandNow();
  }

  if (millis() - lastStatusMs > 5000) {
    lastStatusMs = millis();

    Serial.print("Slave lebt | Seite ");
    Serial.print(DEVICE_SIDE);
    Serial.print(" | Effekt ");
    Serial.print(currentCmd.effect);
    Serial.print(" | Mode ");
    Serial.print(currentCmd.mode);
    Serial.print(" | OTA AP ");
    Serial.print(otaApActive ? "an" : "aus");
    Serial.print(" | Letztes Paket: ");

    if (lastPacketMs == 0) {
      Serial.println("noch nie");
    } else {
      Serial.print((millis() - lastPacketMs) / 1000);
      Serial.println(" s her");
    }
  }
}
