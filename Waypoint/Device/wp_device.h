// Waypoint for iPhone - device layer
// A small C API over idevice (https://github.com/jkcoxson/idevice) so the
// Swift app only deals with a handful of simple calls.
//
// Every function that can fail returns 0 on success, or a non-zero code and
// writes a newly allocated message to *error (free it with wp_string_free).
// None of these functions are thread-safe: call them from one serial queue.

#ifndef WP_DEVICE_H
#define WP_DEVICE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct wp_pairing wp_pairing;
typedef struct wp_session wp_session;

/// Called (on a background thread) with the 6-digit code to type on the iPhone.
typedef void (*wp_pin_callback)(const char *pin, void *context);

void wp_string_free(char *string);
void wp_data_free(uint8_t *data, size_t length);

/// Sends idevice logs to a file (call once at launch, optional).
void wp_init_logging(const char *log_path);

// ---------------------------------------------------------------------------
// On-device pairing (iOS 27+): Waypoint advertises itself as a computer the
// iPhone can pair with from Settings › Privacy & Security › Developer Mode.
// ---------------------------------------------------------------------------

/// Prepares a pairing host and a listening socket.
/// Outputs the Bonjour service name, the TXT record as a binary plist and the
/// TCP port to advertise as `_remotepairing-pairable-host._tcp`.
int wp_pairing_start(const char *hostname,
                     wp_pairing **out_pairing,
                     char **out_service_id,
                     uint8_t **out_txt_plist, size_t *out_txt_length,
                     uint16_t *out_port,
                     char **error);

/// Blocks until the iPhone connects and pairing finishes (or wp_pairing_cancel
/// is called). On success the pairing file is written to `pairing_file_path`.
/// `out_is_local` is set to 1 when the device that paired is this iPhone.
int wp_pairing_accept(wp_pairing *pairing,
                      const char *pairing_file_path,
                      wp_pin_callback pin_callback, void *pin_context,
                      int *out_is_local,
                      char **out_device_name,
                      char **error);

/// Unblocks a pending wp_pairing_accept from another thread.
void wp_pairing_cancel(wp_pairing *pairing);
void wp_pairing_free(wp_pairing *pairing);

// ---------------------------------------------------------------------------
// Session: a tunnel to the iPhone's developer services through the loopback
// VPN (LocalDevVPN, device address 10.7.0.1 by default).
// ---------------------------------------------------------------------------

/// Checks that a pairing file can be read. Returns 0 if valid.
int wp_pairing_file_check(const char *pairing_file_path, char **error);

/// Opens the tunnel. The pairing file may be refreshed by the device, so it is
/// written back to the same path afterwards.
int wp_session_connect(const char *device_ip, uint16_t port,
                       const char *hostname,
                       const char *pairing_file_path,
                       wp_session **out_session,
                       char **error);

/// Reads a lockdown value as text (for example "ProductVersion", "DeviceName").
int wp_session_get_string(wp_session *session, const char *key, char **out_value, char **error);

/// Sets *out_mounted to 1 when developer support (DDI) is already mounted.
int wp_session_ddi_mounted(wp_session *session, int *out_mounted, char **error);

/// Mounts the developer disk image from `ddi_directory`.
/// use_cryptex = 1 for iOS 26.4 and newer (files: BuildManifest.plist,
/// Image.dmg, Image.dmg.trustcache, Image.dmg.cryptex_info, Image.dmg.root_hash),
/// 0 for older versions (BuildManifest.plist, Image.dmg, Image.dmg.trustcache).
int wp_session_mount_ddi(wp_session *session, const char *ddi_directory, int use_cryptex, char **error);

/// Simulates a location. The DVT channel is opened on first use and kept open,
/// because iOS stops simulating once it closes.
int wp_session_set_location(wp_session *session, double latitude, double longitude, char **error);

/// Restores the real location and closes the DVT channel.
int wp_session_clear_location(wp_session *session, char **error);

/// Closes everything. Simulation stops when the session is freed.
void wp_session_free(wp_session *session);

#ifdef __cplusplus
}
#endif

#endif
