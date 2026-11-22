#include "ps5.h"

#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/log.h>
#include <chiaki/opusdecoder.h>
#include <chiaki/opusencoder.h>
#include <chiaki/orientation.h>
#include <chiaki/session.h>
#include <chiaki/time.h>

#include <arpa/inet.h>
#include <errno.h>
#include <stdio.h>
#include <netinet/in.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

struct PSSession {
	ChiakiSession session;
	ChiakiLog log;
	ChiakiOpusDecoder opus;
	ChiakiOpusEncoder mic;
	bool mic_connected;
	PSConfig cfg;
	char *host;
	uint32_t audio_channels, audio_rate;

	// controller bookkeeping
	bool touch_was_active[2];
	int8_t touch_id[2];
	uint8_t touch_next_id;
	ChiakiOrientationTracker orient;
	ChiakiAccelNewZero accel_zero, real_accel;
	bool orient_reset;
};

static bool lib_init(void)
{
	static bool ready = false;
	if(!ready)
		ready = chiaki_lib_init() == CHIAKI_ERR_SUCCESS;
	return ready;
}

// ---------------------------------------------------------------- discovery

PSHostState ps_probe(const char *host, int timeout_ms)
{
	int fd = socket(AF_INET, SOCK_DGRAM, 0);
	if(fd < 0)
		return PS_HOST_UNKNOWN;
	struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
	setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_port = htons(9302);
	if(inet_pton(AF_INET, host, &addr.sin_addr) != 1)
	{
		close(fd);
		return PS_HOST_UNKNOWN;
	}
	const char *msg = "SRCH * HTTP/1.1\ndevice-discovery-protocol-version:00030010\n";
	if(sendto(fd, msg, strlen(msg), 0, (struct sockaddr *)&addr, sizeof(addr)) < 0)
	{
		int err = errno;
		fprintf(stderr, "console: probe send failed: %s\n", strerror(err));
		close(fd);
		return err == EHOSTUNREACH ? PS_HOST_BLOCKED : PS_HOST_UNKNOWN;
	}
	char buf[512];
	ssize_t n = recv(fd, buf, sizeof(buf) - 1, 0);
	int recv_err = errno;
	close(fd);
	if(n <= 0)
	{
		fprintf(stderr, "console: probe got no reply: %s\n", strerror(recv_err));
		return PS_HOST_UNKNOWN;
	}
	buf[n] = 0;
	if(strstr(buf, " 200 "))
		return PS_HOST_READY;
	if(strstr(buf, " 620 "))
		return PS_HOST_STANDBY;
	return PS_HOST_UNKNOWN;
}

static void quiet_log(ChiakiLogLevel level, const char *msg, void *user) { (void)level; (void)msg; (void)user; }

bool ps_wakeup(const char *host, const uint8_t *regist_key)
{
	if(!lib_init())
		return false;
	// The wake credential is the regist key's ASCII hex text read as a number (as chiaki-ng does).
	char hex[17] = {0};
	for(int i = 0; i < 16 && regist_key[i]; i++)
		hex[i] = (char)regist_key[i];
	if(strlen(hex) > 8)
		hex[8] = 0;
	uint64_t credential = strtoull(hex, NULL, 16);
	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_ERROR, quiet_log, NULL);
	return chiaki_discovery_wakeup(&log, NULL, host, credential, true) == CHIAKI_ERR_SUCCESS;
}

// ---------------------------------------------------------------- callbacks

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	PSSession *s = user;
	(void)level;
	if(s->cfg.event_cb)
	{
		PSEvent e = { .type = PS_EVENT_LOG, .message = msg };
		s->cfg.event_cb(&e, s->cfg.user);
	}
}

static bool video_cb(uint8_t *buf, size_t size, int32_t frames_lost, bool recovered, void *user)
{
	PSSession *s = user;
	(void)recovered;
	return s->cfg.video_cb ? s->cfg.video_cb(buf, size, frames_lost, s->cfg.user) : true;
}

static void audio_settings_cb(uint32_t channels, uint32_t rate, void *user)
{
	PSSession *s = user;
	s->audio_channels = channels;
	s->audio_rate = rate;
}

static void audio_frame_cb(int16_t *buf, size_t frames, void *user)
{
	PSSession *s = user;
	if(s->cfg.audio_cb && s->audio_channels)
		s->cfg.audio_cb(buf, frames, s->audio_channels, s->audio_rate, s->cfg.user);
}

static void haptics_frame_cb(uint8_t *buf, size_t size, void *user)
{
	PSSession *s = user;
	if(s->cfg.haptics_cb && size >= 4)
		s->cfg.haptics_cb((const int16_t *)buf, size / 4, s->cfg.user);
}

static uint8_t intensity_level(ChiakiDualSenseEffectIntensity i)
{
	switch(i)
	{
		case Off: return 0;
		case Weak: return 1;
		case Medium: return 2;
		case Strong: return 3;
	}
	return 3;
}

static void event_cb(ChiakiEvent *event, void *user)
{
	PSSession *s = user;
	if(!s->cfg.event_cb)
		return;
	PSEvent e;
	memset(&e, 0, sizeof(e));
	switch(event->type)
	{
		case CHIAKI_EVENT_CONNECTED:
			e.type = PS_EVENT_CONNECTED;
			e.message = "connected";
			break;
		case CHIAKI_EVENT_QUIT:
			e.type = PS_EVENT_QUIT;
			e.message = event->quit.reason_str ? event->quit.reason_str : chiaki_quit_reason_string(event->quit.reason);
			break;
		case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
			e.type = PS_EVENT_LOGIN_PIN;
			e.intensity = event->login_pin_request.pin_incorrect ? 1 : 0;
			break;
		case CHIAKI_EVENT_RUMBLE:
			e.type = PS_EVENT_RUMBLE;
			e.left = event->rumble.left;
			e.right = event->rumble.right;
			break;
		case CHIAKI_EVENT_TRIGGER_EFFECTS:
			e.type = PS_EVENT_TRIGGER_EFFECTS;
			e.trigger_type_left = event->trigger_effects.type_left;
			e.trigger_type_right = event->trigger_effects.type_right;
			memcpy(e.trigger_left, event->trigger_effects.left, 10);
			memcpy(e.trigger_right, event->trigger_effects.right, 10);
			break;
		case CHIAKI_EVENT_LED_COLOR:
			e.type = PS_EVENT_LED;
			memcpy(e.rgb, event->led_state, 3);
			break;
		case CHIAKI_EVENT_PLAYER_INDEX:
			e.type = PS_EVENT_PLAYER_INDEX;
			e.player_index = event->player_index;
			break;
		case CHIAKI_EVENT_HAPTIC_INTENSITY:
			e.type = PS_EVENT_HAPTIC_INTENSITY;
			e.intensity = intensity_level(event->intensity);
			break;
		case CHIAKI_EVENT_TRIGGER_INTENSITY:
			e.type = PS_EVENT_TRIGGER_INTENSITY;
			e.intensity = intensity_level(event->intensity);
			break;
		case CHIAKI_EVENT_MOTION_RESET:
			s->orient_reset = true;
			e.type = PS_EVENT_MOTION_RESET;
			break;
		case CHIAKI_EVENT_KEYBOARD_OPEN:
			e.type = PS_EVENT_KEYBOARD_OPEN;
			e.message = "";
			break;
		case CHIAKI_EVENT_KEYBOARD_TEXT_CHANGE:
			e.type = PS_EVENT_KEYBOARD_OPEN;
			e.message = event->keyboard.text_str ? event->keyboard.text_str : "";
			break;
		case CHIAKI_EVENT_KEYBOARD_REMOTE_CLOSE:
			e.type = PS_EVENT_KEYBOARD_CLOSE;
			break;
		default:
			return;
	}
	s->cfg.event_cb(&e, s->cfg.user);
}

// ---------------------------------------------------------------- session

PSSession *ps_session_start(const PSConfig *config)
{
	if(!lib_init())
		return NULL;

	PSSession *s = calloc(1, sizeof(PSSession));
	if(!s)
		return NULL;
	s->cfg = *config;
	s->host = strdup(config->host);
	s->touch_id[0] = s->touch_id[1] = -1;
	chiaki_orientation_tracker_init(&s->orient);
	chiaki_accel_new_zero_set_inactive(&s->accel_zero, false);
	chiaki_accel_new_zero_set_inactive(&s->real_accel, true);

	uint32_t mask = CHIAKI_LOG_ERROR | CHIAKI_LOG_WARNING | CHIAKI_LOG_INFO;
	if(!config->verbose)
		mask &= ~(uint32_t)CHIAKI_LOG_INFO;
	chiaki_log_init(&s->log, mask, log_cb, s);

	ChiakiConnectInfo info;
	memset(&info, 0, sizeof(info));
	info.ps5 = true;
	info.host = s->host;
	memcpy(info.regist_key, config->regist_key, sizeof(info.regist_key));
	memcpy(info.morning, config->morning, sizeof(info.morning));
	info.video_profile.width = config->width;
	info.video_profile.height = config->height;
	info.video_profile.max_fps = config->fps;
	info.video_profile.bitrate = config->bitrate_kbps;
	info.video_profile.codec = config->hdr ? CHIAKI_CODEC_H265_HDR : CHIAKI_CODEC_H265;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = true;
	info.enable_dualsense = config->dualsense;
	info.enable_idr_on_fec_failure = true;
	info.packet_loss_max = 0.05;

	chiaki_opus_decoder_init(&s->opus, &s->log);
	chiaki_opus_encoder_init(&s->mic, &s->log);
	if(chiaki_session_init(&s->session, &info, &s->log) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_opus_encoder_fini(&s->mic);
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host);
		free(s);
		return NULL;
	}

	chiaki_opus_decoder_set_cb(&s->opus, audio_settings_cb, audio_frame_cb, s);
	ChiakiAudioSink sink;
	chiaki_opus_decoder_get_sink(&s->opus, &sink);
	chiaki_session_set_audio_sink(&s->session, &sink);

	ChiakiAudioHeader mic_header;
	chiaki_audio_header_set(&mic_header, 2, 16, 48000, 480);
	chiaki_opus_encoder_header(&mic_header, &s->mic, &s->session);

	if(config->dualsense)
	{
		ChiakiAudioSink haptics;
		memset(&haptics, 0, sizeof(haptics));
		haptics.user = s;
		haptics.frame_cb = haptics_frame_cb;
		chiaki_session_set_haptics_sink(&s->session, &haptics);
	}
	chiaki_session_set_video_sample_cb(&s->session, video_cb, s);
	chiaki_session_set_event_cb(&s->session, event_cb, s);

	if(chiaki_session_start(&s->session) != CHIAKI_ERR_SUCCESS)
	{
		chiaki_session_fini(&s->session);
		chiaki_opus_encoder_fini(&s->mic);
		chiaki_opus_decoder_fini(&s->opus);
		free(s->host);
		free(s);
		return NULL;
	}
	return s;
}

void ps_session_set_controller(PSSession *s, const PSController *c)
{
	ChiakiControllerState st;
	chiaki_controller_state_set_idle(&st);
	st.buttons = c->buttons;
	st.l2_state = c->l2;
	st.r2_state = c->r2;
	st.left_x = c->left_x;
	st.left_y = c->left_y;
	st.right_x = c->right_x;
	st.right_y = c->right_y;

	// Touchpad: every new finger-down gets a fresh 7-bit id, as on a real DualSense.
	for(int i = 0; i < 2; i++)
	{
		if(c->touch_active[i] && !s->touch_was_active[i])
			s->touch_id[i] = (int8_t)(s->touch_next_id++ & 0x7f);
		if(!c->touch_active[i])
			s->touch_id[i] = -1;
		s->touch_was_active[i] = c->touch_active[i];
		st.touches[i].id = s->touch_id[i];
		st.touches[i].x = c->touch_x[i];
		st.touches[i].y = c->touch_y[i];
	}
	st.touch_id_next = s->touch_next_id & 0x7f;

	if(c->has_motion)
	{
		chiaki_accel_new_zero_set_active(&s->real_accel, c->accel_x, c->accel_y, c->accel_z, true);
		if(s->orient_reset)
		{
			chiaki_accel_new_zero_set_active(&s->accel_zero, c->accel_x, c->accel_y, c->accel_z, false);
			chiaki_orientation_tracker_init(&s->orient);
			s->orient_reset = false;
		}
		chiaki_orientation_tracker_update(&s->orient, c->gyro_x, c->gyro_y, c->gyro_z,
			c->accel_x, c->accel_y, c->accel_z, &s->accel_zero, true,
			(uint32_t)chiaki_time_now_monotonic_us());
		chiaki_orientation_tracker_apply_to_controller_state(&s->orient, &st);
	}
	chiaki_session_set_controller_state(&s->session, &st);
}

void ps_session_request_keyframe(PSSession *s)
{
	chiaki_session_request_idr(&s->session);
}

void ps_session_goto_bed(PSSession *s)
{
	chiaki_session_goto_bed(&s->session);
}

void ps_session_set_mic_muted(PSSession *s, bool muted)
{
	if(!muted && !s->mic_connected)
	{
		chiaki_session_connect_microphone(&s->session);
		s->mic_connected = true;
	}
	if(s->mic_connected)
		chiaki_session_toggle_microphone(&s->session, muted);
}

void ps_session_mic_frame(PSSession *s, const int16_t *pcm)
{
	if(s->mic_connected)
		chiaki_opus_encoder_frame((int16_t *)pcm, &s->mic);
}

void ps_session_keyboard_text(PSSession *s, const char *text, bool accept)
{
	if(accept)
	{
		chiaki_session_keyboard_set_text(&s->session, text);
		chiaki_session_keyboard_accept(&s->session);
	}
	else
		chiaki_session_keyboard_reject(&s->session);
}

void ps_session_set_login_pin(PSSession *s, const char *pin)
{
	chiaki_session_set_login_pin(&s->session, (const uint8_t *)pin, strlen(pin));
}

void ps_session_stop(PSSession *s)
{
	if(!s)
		return;
	chiaki_session_stop(&s->session);
	chiaki_session_join(&s->session);
	chiaki_session_fini(&s->session);
	chiaki_opus_encoder_fini(&s->mic);
	chiaki_opus_decoder_fini(&s->opus);
	free(s->host);
	free(s);
}
