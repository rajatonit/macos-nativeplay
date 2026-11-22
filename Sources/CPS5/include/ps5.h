// Thin C wrapper around libchiaki so Swift never touches its large internal structs.
#ifndef PS5_SHIM_H
#define PS5_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct PSSession PSSession;

typedef enum {
	PS_EVENT_CONNECTED = 0,
	PS_EVENT_QUIT,
	PS_EVENT_LOG,
	PS_EVENT_RUMBLE,           // left, right
	PS_EVENT_TRIGGER_EFFECTS,  // trigger_type_*, trigger_*
	PS_EVENT_LED,              // rgb
	PS_EVENT_PLAYER_INDEX,     // player_index
	PS_EVENT_HAPTIC_INTENSITY, // intensity: 0 off .. 3 strong
	PS_EVENT_TRIGGER_INTENSITY,
	PS_EVENT_MOTION_RESET,
	PS_EVENT_KEYBOARD_OPEN,    // message = current text
	PS_EVENT_KEYBOARD_CLOSE,
	PS_EVENT_LOGIN_PIN,        // intensity = 1 if the previous PIN was wrong
} PSEventType;

typedef struct {
	PSEventType type;
	const char *message;
	uint8_t left, right;
	uint8_t trigger_type_left, trigger_type_right;
	uint8_t trigger_left[10], trigger_right[10];
	uint8_t rgb[3];
	uint8_t player_index;
	uint8_t intensity;
} PSEvent;

// buf is one Annex-B access unit (or just the VPS/SPS/PPS header). Return false if it could not be decoded.
typedef bool (*PSVideoCallback)(const uint8_t *buf, size_t size, int32_t frames_lost, void *user);
// Interleaved signed 16-bit PCM; frames = samples per channel.
typedef void (*PSAudioCallback)(const int16_t *pcm, size_t frames, uint32_t channels, uint32_t rate, void *user);
// DualSense haptics: interleaved stereo int16 at 3 kHz (left/right actuator waveforms).
typedef void (*PSHapticsCallback)(const int16_t *pcm, size_t frames, void *user);
typedef void (*PSEventCallback)(const PSEvent *event, void *user);

typedef struct {
	const char *host;
	const uint8_t *regist_key; // 16 bytes
	const uint8_t *morning;    // 16 bytes
	uint32_t width, height, fps, bitrate_kbps;
	bool hdr;
	bool dualsense; // ask for haptics/adaptive-trigger data instead of plain rumble
	bool verbose;
	PSVideoCallback video_cb;
	PSAudioCallback audio_cb;
	PSHapticsCallback haptics_cb;
	PSEventCallback event_cb;
	void *user;
} PSConfig;

typedef struct {
	uint32_t buttons; // PS_BTN_* bitmask
	uint8_t l2, r2;
	int16_t left_x, left_y, right_x, right_y;
	bool touch_active[2];
	uint16_t touch_x[2], touch_y[2]; // 0..1919, 0..1079
	bool has_motion;
	float gyro_x, gyro_y, gyro_z;    // rad/s
	float accel_x, accel_y, accel_z; // g
} PSController;

enum {
	PS_BTN_CROSS = 1 << 0, PS_BTN_CIRCLE = 1 << 1, PS_BTN_SQUARE = 1 << 2, PS_BTN_TRIANGLE = 1 << 3,
	PS_BTN_LEFT = 1 << 4, PS_BTN_RIGHT = 1 << 5, PS_BTN_UP = 1 << 6, PS_BTN_DOWN = 1 << 7,
	PS_BTN_L1 = 1 << 8, PS_BTN_R1 = 1 << 9, PS_BTN_L3 = 1 << 10, PS_BTN_R3 = 1 << 11,
	PS_BTN_OPTIONS = 1 << 12, PS_BTN_SHARE = 1 << 13, PS_BTN_TOUCHPAD = 1 << 14, PS_BTN_PS = 1 << 15,
};

// PS_HOST_BLOCKED: macOS refused to send (Local Network permission is off for this app).
typedef enum { PS_HOST_UNKNOWN = 0, PS_HOST_READY = 1, PS_HOST_STANDBY = 2, PS_HOST_BLOCKED = 3 } PSHostState;

// Asks the console on the LAN whether it is awake. Blocks for up to timeout_ms.
PSHostState ps_probe(const char *host, int timeout_ms);
// Sends the wake-from-rest packet. regist_key is the 16-byte key from pairing.
bool ps_wakeup(const char *host, const uint8_t *regist_key);

PSSession *ps_session_start(const PSConfig *config);
void ps_session_set_controller(PSSession *s, const PSController *c);
void ps_session_request_keyframe(PSSession *s);
// Puts the console into rest mode (the stream ends shortly after).
void ps_session_goto_bed(PSSession *s);
// Microphone: 480 stereo 16-bit frames at 48 kHz per call. Unmuting connects the mic on first use.
void ps_session_set_mic_muted(PSSession *s, bool muted);
void ps_session_mic_frame(PSSession *s, const int16_t *pcm_480_stereo);
// On-screen keyboard: send the text, then accept (or reject to cancel).
void ps_session_keyboard_text(PSSession *s, const char *text, bool accept);
// Answers PS_EVENT_LOGIN_PIN with the PS5 profile's login passcode (digits).
void ps_session_set_login_pin(PSSession *s, const char *pin);
// Stops the stream and frees the session. Blocks until libchiaki's threads have exited.
void ps_session_stop(PSSession *s);

#endif
