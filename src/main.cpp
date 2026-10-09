#include <M5Unified.h>
#include "USB.h"
#include "USBCDC.h"
#include "USBHIDKeyboard.h"
#include <string.h>

// ============================================================================
//  M5StickC S3  ·  USB HID keyboard remote for DeepSeek Harness
//
//  front button  single click -> Enter        (send / allow)
//                double click -> Esc          (reject / cancel)
//  side  button  hold         -> Ctrl+Alt+R   (start DSH voice recording)
//                release      -> Ctrl+Alt+R   (stop and transcribe)
//                this is GPIO 12, and a hardware long press puts the chip in
//                ROM download mode
//
//  Screen
//    idle      the name set in Mincho (brush serif), wide letter spacing, a
//              soft drop shadow and a 1 px overprint that reads as bold
//    approval  two pills, 确认 / 拒绝, in bold 16 px
//    on press  the chosen pill fills with its colour, or a ring ripples out
// ============================================================================

static USBHIDKeyboard Keyboard;

// The core only creates a global USBCDC when ARDUINO_USB_MODE == 0, but HID
// needs mode 1 (USB-OTG). Constructing our own instance registers the CDC
// interface with TinyUSB, so the board keeps a COM port for the bridge.
static USBCDC UsbSerial(0);

static const int W  = 240, H = 135;     // landscape
static const int CX = W / 2;

// ------------------------------------------------------------- palette ------
static const uint16_t C_BG    = 0x0000;   // true black
static const uint16_t C_SOFT  = 0xB5B6;   // #B4B8BC
static const uint16_t C_TEXT  = 0xEF5D;   // #EDEFF2  warm off-white
static const uint16_t C_INK   = 0x1082;   // #101418  label on a filled pill
static const uint16_t C_LINE  = 0x2947;   // #2B2F34  hairline
static const uint16_t C_GLOW  = 0x18E4;   // #1A1D22  drop shadow
static const uint16_t C_GREEN = 0x3693;   // #34D399  emerald
static const uint16_t C_RED   = 0xFB8E;   // #F87171  soft red
static const uint16_t C_BLUE  = 0x651F;   // #60A5FA  sky

#define TITLE_TEXT "程序猿白瑞"

// typography
static const int TITLE_PX    = 32;        // Mincho cap size
static const int TITLE_TRACK = 6;         // extra letter spacing
static const int TITLE_Y     = 32;

enum { ACT_CONFIRM, ACT_REJECT, ACT_VOICE };
enum { VIEW_IDLE, VIEW_APPROVAL };

// ------------------------------------------------------------------ state ---
static int      view        = VIEW_IDLE;
static bool     mounted     = false;

static int      clickCount  = 0;
static uint32_t lastClickMs = 0;

// The M5StickC S3's right-side button is plain GPIO 12. M5Unified's button map
// for this board does not include it (the board reads its buttons through the
// PMIC), so it is sampled directly here.
static const int PIN_SIDE      = 12;
static int       sideIdleLevel = HIGH;
static bool      sideDown      = false;
static bool      sideRecording = false;   // 已按住超过阈值,正在录音
static uint32_t  sideDownMs    = 0;

// 按住多久才算"开始录音":太短容易误触,太长会漏掉开头
static const uint32_t SIDE_HOLD_MS = 250;

static int      flashCard   = -1;
static uint32_t flashUntil  = 0;
static uint32_t pressMs     = 0;
static uint16_t pressColor  = C_GREEN;

static char     rxLine[24];
static int      rxLen       = 0;
static bool     pubFlash    = false;

static void fullRepaint();

// ------------------------------------------------------------------- pills --
struct Pill { const char* text; int x, y, w, h; uint16_t accent; int id; };
static const Pill PILLS[2] = {
  { "确认",  30, 46, 84, 38, C_GREEN, ACT_CONFIRM },
  { "拒绝", 126, 46, 84, 38, C_RED,   ACT_REJECT  },
};
static const int PILL_R = 13;
static const int DOT_Y  = 100;

// ------------------------------------------------------------------- utils --
static uint16_t lerp565(uint16_t a, uint16_t b, float t) {
  int ar = (a >> 11) & 0x1F, ag = (a >> 5) & 0x3F, ab = a & 0x1F;
  int br = (b >> 11) & 0x1F, bg = (b >> 5) & 0x3F, bb = b & 0x1F;
  int r = ar + (int)((br - ar) * t);
  int g = ag + (int)((bg - ag) * t);
  int l = ab + (int)((bb - ab) * t);
  return (uint16_t)((r << 11) | (g << 5) | l);
}

// Length of the UTF-8 sequence starting at p.
static int utf8Len(const char* p) {
  unsigned char c = (unsigned char)*p;
  if (c < 0x80) return 1;
  if ((c & 0xE0) == 0xC0) return 2;
  if ((c & 0xF0) == 0xE0) return 3;
  if ((c & 0xF8) == 0xF0) return 4;
  return 1;
}

// Draw a string one glyph at a time so the tracking can be widened. CJK cells
// are square, so the advance is the font size.
static void drawTracked(const char* s, int cx, int y, int px, int track, uint16_t col) {
  int n = 0;
  for (const char* p = s; *p; p += utf8Len(p)) n++;
  int total = n * px + (n - 1) * track;
  int x = cx - total / 2;

  M5.Display.setTextDatum(top_left);
  M5.Display.setFont(&fonts::lgfxJapanMincho_32);
  M5.Display.setTextColor(col);
  for (const char* p = s; *p; ) {
    int len = utf8Len(p);
    char buf[5] = {0, 0, 0, 0, 0};
    memcpy(buf, p, len);
    M5.Display.drawString(buf, x, y);
    x += px + track;
    p += len;
  }
}

// ---------------------------------------------------------------- key send ---
static void sendEnter() { Keyboard.press(KEY_RETURN); delay(18); Keyboard.release(KEY_RETURN); }
static void sendEsc()   { Keyboard.press(KEY_ESC);    delay(18); Keyboard.release(KEY_ESC); }

// One click asks DSH to start or stop its own voice input (Ctrl+Alt+R).
//
// The modifiers MUST go through pressRaw: USBHIDKeyboard::press() turns a
// modifier into k = 0, and pressRaw(0) hits its "not a modifier and not a key"
// branch and returns without sending a report at all. Ordinary keys such as
// Enter are unaffected, which is why only chords used to fail.
static void sendVoice() {
  Keyboard.pressRaw(0xE0);   // left Ctrl  (HID usage 0xE0)
  delay(12);
  Keyboard.pressRaw(0xE2);   // left Alt   (HID usage 0xE2)
  delay(12);
  Keyboard.press('r');       // normal key path - this one does send
  delay(28);
  Keyboard.releaseAll();
}

static void doAction(int a) {
  switch (a) {
    case ACT_CONFIRM: sendEnter(); break;
    case ACT_REJECT:  sendEsc();   break;
    case ACT_VOICE:   sendVoice(); break;
  }
  flashCard  = a;
  flashUntil = millis() + 550;
  pressMs    = millis();
  pressColor = (a == ACT_CONFIRM) ? C_GREEN
             : (a == ACT_REJECT)  ? C_RED
             : C_BLUE;
  if (a == ACT_VOICE) pressColor = C_RED;

  if (view == VIEW_APPROVAL) fullRepaint();
}

// ------------------------------------------------------------ serial bridge --
static void pollSerial() {
  while (UsbSerial.available()) {
    char c = (char)UsbSerial.read();
    if (c == '\n' || c == '\r') {
      rxLine[rxLen] = 0;
      if (rxLen > 0) {
        if (!strcasecmp(rxLine, "ASK")) {
          if (view != VIEW_APPROVAL) { view = VIEW_APPROVAL; fullRepaint(); }
        } else if (!strcasecmp(rxLine, "IDLE")) {
          if (view != VIEW_IDLE) { view = VIEW_IDLE; fullRepaint(); }
        }
      }
      rxLen = 0;
    } else if (rxLen < (int)sizeof(rxLine) - 1) {
      rxLine[rxLen++] = c;
    }
  }
}

// ----------------------------------------------------------------- drawing --
static void drawPill(const Pill& p, bool active) {
  if (active) {
    M5.Display.fillSmoothRoundRect(p.x, p.y, p.w, p.h, PILL_R, p.accent);
  } else {
    M5.Display.fillSmoothRoundRect(p.x, p.y, p.w, p.h, PILL_R, C_LINE);
    M5.Display.fillSmoothRoundRect(p.x + 1, p.y + 1, p.w - 2, p.h - 2, PILL_R - 1, C_BG);
  }
  M5.Display.setTextDatum(middle_center);
  M5.Display.setFont(&fonts::efontCN_16_b);
  M5.Display.setTextColor(active ? C_INK : C_TEXT);
  M5.Display.drawString(p.text, p.x + p.w / 2, p.y + p.h / 2 + 1);
}

static void drawApproval() {
  M5.Display.fillScreen(C_BG);
  uint32_t now = millis();
  for (int i = 0; i < 2; i++) {
    drawPill(PILLS[i], now < flashUntil && flashCard == PILLS[i].id);
  }
}

static void drawIdle() {
  M5.Display.fillScreen(C_BG);
  // drop shadow, then the glyphs, then a 1 px overprint that reads as bold
  drawTracked(TITLE_TEXT, CX + 2, TITLE_Y + 2, TITLE_PX, TITLE_TRACK, C_GLOW);
  drawTracked(TITLE_TEXT, CX,     TITLE_Y,     TITLE_PX, TITLE_TRACK, C_TEXT);
  drawTracked(TITLE_TEXT, CX + 1, TITLE_Y,     TITLE_PX, TITLE_TRACK, C_TEXT);
}

static void fullRepaint() {
  if (view == VIEW_APPROVAL) drawApproval();
  else                       drawIdle();
}

// The lower half belongs to one small animation: a soft halo dot at rest, an
// expanding ring right after a key was sent.
static void drawPulse() {
  uint32_t now = millis();
  M5.Display.fillRect(CX - 22, DOT_Y - 22, 44, 44, C_BG);

  uint32_t age = now - pressMs;
  if (age < 520) {
    float t = age / 520.0f;
    float r = 5.0f + 15.0f * t;
    uint16_t col = lerp565(pressColor, C_BG, t * t);
    int r1 = (int)r;
    int r0 = r1 - 2;
    if (r0 < 1) r0 = 1;
    M5.Display.fillArc(CX, DOT_Y, r0, r1, 0, 360, col);
  } else if (sideRecording) {
    // 按住录音中:红色光环常亮,轻微呼吸
    int phase = (int)((now / 30) % 60);
    int p     = (phase < 30 ? phase : 60 - phase);
    int halo  = 7 + p / 10;
    M5.Display.fillSmoothCircle(CX, DOT_Y, halo, lerp565(C_RED, C_BG, 0.75f));
    M5.Display.fillSmoothCircle(CX, DOT_Y, 4, C_RED);
  } else if (view == VIEW_IDLE) {
    int phase = (int)((now / 45) % 72);
    int p     = (phase < 36 ? phase : 72 - phase);
    int core  = 2 + p / 18;
    int halo  = 6 + p / 9;
    uint16_t c = mounted ? C_GREEN : C_RED;
    M5.Display.fillSmoothCircle(CX, DOT_Y, halo, lerp565(c, C_BG, 0.82f));
    M5.Display.fillSmoothCircle(CX, DOT_Y, core, c);
  }
}

// ------------------------------------------------------------------- setup ---
void setup() {
  Keyboard.begin();
  UsbSerial.begin(115200);
  USB.productName("DeepSeek Remote");
  USB.manufacturerName("M5Stack");
  USB.begin();

  auto cfg = M5.config();
  cfg.internal_imu = false;
  cfg.internal_spk = false;
  cfg.internal_mic = false;
  M5.begin(cfg);

  M5.Display.setRotation(1);
  M5.Display.setBrightness(150);
  M5.Display.fillScreen(C_BG);

  // right-side button on GPIO 12: wait out a held key, then latch the idle level
  pinMode(PIN_SIDE, INPUT_PULLUP);
  for (int i = 0; i < 20 && digitalRead(PIN_SIDE) == LOW; i++) delay(50);
  sideIdleLevel = digitalRead(PIN_SIDE);

  delay(150);
  mounted = (bool)USB;
  fullRepaint();
  drawPulse();
}

// -------------------------------------------------------------------- loop ---
void loop() {
  M5.update();
  uint32_t now = millis();

  pollSerial();

  // ---- 右侧按键(GPIO12):按住说话 ----
  //   按住达到 SIDE_HOLD_MS  -> 发 Ctrl+Alt+R,DSH 开始录音
  //   松开                   -> 再发一次,停止录音并转写
  //   轻点(不到阈值)         -> 什么都不做,避免误触
  // 下载模式仍由这个键的硬件长按提供,固件不再自己开下载模式。
  {
    bool pressed = (digitalRead(PIN_SIDE) != sideIdleLevel);
    if (pressed && !sideDown) {
      sideDown      = true;
      sideDownMs    = now;
      sideRecording = false;
    } else if (pressed && sideDown && !sideRecording && now - sideDownMs >= SIDE_HOLD_MS) {
      sideRecording = true;
      doAction(ACT_VOICE);                       // 开始录音
    } else if (!pressed && sideDown) {
      sideDown = false;
      if (sideRecording) {
        sideRecording = false;
        doAction(ACT_VOICE);                     // 结束录音并转写
      }
    }
  }

  // The front button only reports single and double clicks; voice moved to the
  // side button, so nothing here watches for a hold.
  if (M5.BtnA.wasClicked()) { clickCount++; lastClickMs = now; }

  if (clickCount == 1 && now - lastClickMs > 280) {
    clickCount = 0;
    doAction(ACT_CONFIRM);
  } else if (clickCount >= 2) {
    clickCount = 0;
    doAction(ACT_REJECT);
  }

  mounted = (bool)USB;

  bool flash = now < flashUntil;
  if (flash != pubFlash) {
    pubFlash = flash;
    if (view == VIEW_APPROVAL) drawApproval();
  }

  drawPulse();
  delay(16);
}
