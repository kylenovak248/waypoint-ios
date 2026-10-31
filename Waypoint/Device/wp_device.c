// Waypoint for iPhone - device layer over idevice. See wp_device.h.

#include "wp_device.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include "idevice.h"

struct wp_pairing {
    struct PairableHostHandle *host;
    int listener;
    // Writing to wake[1] wakes a pending accept. Closing a listening socket
    // from another thread does not unblock accept() on Apple platforms.
    int wake[2];
};

struct wp_session {
    struct AdapterHandle *adapter;
    struct RsdHandshakeHandle *handshake;
    struct RemoteServerHandle *remote_server;
    struct LocationSimulationHandle *location;
};

// --- helpers ---------------------------------------------------------------

static char *wp_strdup(const char *text) {
    if (text == NULL) text = "";
    size_t length = strlen(text) + 1;
    char *copy = malloc(length);
    if (copy) memcpy(copy, text, length);
    return copy;
}

static int wp_fail(char **error, int code, const char *message) {
    if (error) *error = wp_strdup(message);
    return code;
}

/// Consumes an idevice error and turns it into "<context>: <detail>".
static int wp_fail_ffi(char **error, int code, const char *context, struct IdeviceFfiError *ffi_error) {
    if (error) {
        const char *detail = (ffi_error && ffi_error->message) ? ffi_error->message : "unknown error";
        size_t length = strlen(context) + strlen(detail) + 3;
        char *message = malloc(length);
        if (message) snprintf(message, length, "%s: %s", context, detail);
        *error = message;
    }
    if (ffi_error) idevice_error_free(ffi_error);
    return code;
}

void wp_string_free(char *string) { free(string); }

void wp_data_free(uint8_t *data, size_t length) {
    (void)length;
    free(data);
}

void wp_init_logging(const char *log_path) {
    if (log_path == NULL) return;
    char *path = wp_strdup(log_path);
    if (path == NULL) return;
    idevice_init_logger(Disabled, Info, path);
    free(path);
}

// --- pairing ---------------------------------------------------------------

int wp_pairing_start(const char *hostname,
                     wp_pairing **out_pairing,
                     char **out_service_id,
                     uint8_t **out_txt_plist, size_t *out_txt_length,
                     uint16_t *out_port,
                     char **error) {
    if (!hostname || !out_pairing || !out_service_id || !out_txt_plist || !out_txt_length || !out_port) {
        return wp_fail(error, 1, "Invalid arguments");
    }
    *out_pairing = NULL;
    *out_service_id = NULL;
    *out_txt_plist = NULL;
    *out_txt_length = 0;
    *out_port = 0;

    struct PairableHostHandle *host = NULL;
    char *service_id = NULL;
    uint8_t *txt = NULL;
    uintptr_t txt_length = 0;
    uint8_t alt_irk[16] = {0};
    // Present ourselves as a Mac so iOS lists us under "Pair with ...".
    struct IdeviceFfiError *ffi_error = pairable_host_prepare(hostname, "Mac17,7", false, &host, &service_id,
                                                              &txt, &txt_length, alt_irk);
    if (ffi_error) return wp_fail_ffi(error, 2, "Could not prepare pairing", ffi_error);
    if (!host || !service_id || !txt) {
        pairable_host_free(host);
        idevice_string_free(service_id);
        idevice_data_free(txt, txt_length);
        return wp_fail(error, 2, "Pairing host returned no Bonjour information");
    }

    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) {
        pairable_host_free(host);
        idevice_string_free(service_id);
        idevice_data_free(txt, txt_length);
        return wp_fail(error, 3, "Could not open a network socket");
    }
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = 0;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    socklen_t address_length = sizeof(address);
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(listener, 1) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &address_length) != 0) {
        close(listener);
        pairable_host_free(host);
        idevice_string_free(service_id);
        idevice_data_free(txt, txt_length);
        return wp_fail(error, 3, "Could not start the pairing listener");
    }

    wp_pairing *pairing = calloc(1, sizeof(wp_pairing));
    uint8_t *txt_copy = malloc(txt_length ? txt_length : 1);
    char *service_copy = wp_strdup(service_id);
    int wake[2] = {-1, -1};
    if (!pairing || !txt_copy || !service_copy || pipe(wake) != 0) {
        free(pairing);
        free(txt_copy);
        free(service_copy);
        if (wake[0] >= 0) close(wake[0]);
        if (wake[1] >= 0) close(wake[1]);
        close(listener);
        pairable_host_free(host);
        idevice_string_free(service_id);
        idevice_data_free(txt, txt_length);
        return wp_fail(error, 4, "Out of memory");
    }
    memcpy(txt_copy, txt, txt_length);
    idevice_string_free(service_id);
    idevice_data_free(txt, txt_length);

    fcntl(wake[1], F_SETFL, fcntl(wake[1], F_GETFL) | O_NONBLOCK);
    pairing->host = host;
    pairing->listener = listener;
    pairing->wake[0] = wake[0];
    pairing->wake[1] = wake[1];
    *out_pairing = pairing;
    *out_service_id = service_copy;
    *out_txt_plist = txt_copy;
    *out_txt_length = (size_t)txt_length;
    *out_port = ntohs(address.sin_port);
    return 0;
}

int wp_pairing_accept(wp_pairing *pairing,
                      const char *pairing_file_path,
                      wp_pin_callback pin_callback, void *pin_context,
                      int *out_is_local,
                      char **out_device_name,
                      char **error) {
    if (!pairing || !pairing_file_path) return wp_fail(error, 1, "Invalid arguments");
    if (out_is_local) *out_is_local = 0;
    if (out_device_name) *out_device_name = NULL;

    // Wait for either the iPhone to connect or wp_pairing_cancel.
    for (;;) {
        struct pollfd fds[2] = {{pairing->listener, POLLIN, 0}, {pairing->wake[0], POLLIN, 0}};
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return wp_fail(error, 5, "The iPhone could not connect");
        }
        if (fds[1].revents) return wp_fail(error, 5, "Pairing was cancelled");
        if (fds[0].revents & POLLIN) break;
        if (fds[0].revents & (POLLERR | POLLHUP | POLLNVAL)) return wp_fail(error, 5, "Pairing was cancelled");
    }
    int connection = accept(pairing->listener, NULL, NULL);
    if (connection < 0) {
        return wp_fail(error, 5, "The iPhone could not connect");
    }

    struct sockaddr_in peer, local;
    socklen_t peer_length = sizeof(peer), local_length = sizeof(local);
    int is_local = 0;
    if (getpeername(connection, (struct sockaddr *)&peer, &peer_length) == 0 &&
        getsockname(connection, (struct sockaddr *)&local, &local_length) == 0 &&
        peer.sin_family == AF_INET && local.sin_family == AF_INET) {
        is_local = peer.sin_addr.s_addr == local.sin_addr.s_addr;
    }

    struct RpPairingPeerDeviceC *peer_device = NULL;
    struct RpPairingFileHandle *pairing_file = NULL;
    struct IdeviceFfiError *ffi_error = pairable_host_accept_fd(pairing->host, connection, (PairableHostPinCb)pin_callback,
                                                                pin_context, &peer_device, &pairing_file);
    close(connection);
    if (ffi_error) {
        rppairing_peer_device_free(peer_device);
        rp_pairing_file_free(pairing_file);
        return wp_fail_ffi(error, 6, "Pairing failed", ffi_error);
    }
    if (!pairing_file) {
        rppairing_peer_device_free(peer_device);
        return wp_fail(error, 6, "Pairing finished without a pairing file");
    }

    ffi_error = rp_pairing_file_write(pairing_file, pairing_file_path);
    rp_pairing_file_free(pairing_file);
    if (ffi_error) {
        rppairing_peer_device_free(peer_device);
        return wp_fail_ffi(error, 7, "Could not save the pairing file", ffi_error);
    }

    if (out_is_local) *out_is_local = is_local;
    if (out_device_name) *out_device_name = wp_strdup(peer_device && peer_device->name ? peer_device->name : "iPhone");
    rppairing_peer_device_free(peer_device);
    return 0;
}

void wp_pairing_cancel(wp_pairing *pairing) {
    if (pairing && pairing->wake[1] >= 0) {
        char byte = 1;
        ssize_t written = write(pairing->wake[1], &byte, 1);
        (void)written;
    }
}

void wp_pairing_free(wp_pairing *pairing) {
    if (!pairing) return;
    if (pairing->listener >= 0) close(pairing->listener);
    if (pairing->wake[0] >= 0) close(pairing->wake[0]);
    if (pairing->wake[1] >= 0) close(pairing->wake[1]);
    pairable_host_free(pairing->host);
    free(pairing);
}

// --- session ---------------------------------------------------------------

int wp_pairing_file_check(const char *pairing_file_path, char **error) {
    if (!pairing_file_path) return wp_fail(error, 1, "Invalid arguments");
    struct RpPairingFileHandle *file = NULL;
    struct IdeviceFfiError *ffi_error = rp_pairing_file_read(pairing_file_path, &file);
    if (ffi_error) return wp_fail_ffi(error, 8, "This is not a valid pairing file", ffi_error);
    rp_pairing_file_free(file);
    return 0;
}

int wp_session_connect(const char *device_ip, uint16_t port,
                       const char *hostname,
                       const char *pairing_file_path,
                       wp_session **out_session,
                       char **error) {
    if (!device_ip || !hostname || !pairing_file_path || !out_session) return wp_fail(error, 1, "Invalid arguments");
    *out_session = NULL;

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    if (inet_pton(AF_INET, device_ip, &address.sin_addr) != 1) {
        return wp_fail(error, 9, "The device address is not a valid IPv4 address");
    }

    struct RpPairingFileHandle *pairing_file = NULL;
    struct IdeviceFfiError *ffi_error = rp_pairing_file_read(pairing_file_path, &pairing_file);
    if (ffi_error) return wp_fail_ffi(error, 8, "Could not read the pairing file", ffi_error);

    wp_session *session = calloc(1, sizeof(wp_session));
    if (!session) {
        rp_pairing_file_free(pairing_file);
        return wp_fail(error, 4, "Out of memory");
    }

    ffi_error = tunnel_create_rppairing((const idevice_sockaddr *)&address, (idevice_socklen_t)sizeof(address), hostname,
                                        pairing_file, NULL, NULL, &session->adapter, &session->handshake);
    if (ffi_error) {
        rp_pairing_file_free(pairing_file);
        wp_session_free(session);
        return wp_fail_ffi(error, 10, "Could not connect to the iPhone", ffi_error);
    }
    if (!session->adapter || !session->handshake) {
        rp_pairing_file_free(pairing_file);
        wp_session_free(session);
        return wp_fail(error, 10, "The tunnel opened without valid handles");
    }

    // The device may have refreshed the pairing; keep the file current.
    struct IdeviceFfiError *write_error = rp_pairing_file_write(pairing_file, pairing_file_path);
    if (write_error) idevice_error_free(write_error);
    rp_pairing_file_free(pairing_file);

    *out_session = session;
    return 0;
}

int wp_session_get_string(wp_session *session, const char *key, char **out_value, char **error) {
    if (!session || !key || !out_value) return wp_fail(error, 1, "Invalid arguments");
    *out_value = NULL;

    struct LockdowndClientHandle *lockdown = NULL;
    struct IdeviceFfiError *ffi_error = lockdownd_connect_rsd(session->adapter, session->handshake, &lockdown);
    if (ffi_error) return wp_fail_ffi(error, 11, "Could not open lockdown", ffi_error);

    plist_t value = NULL;
    ffi_error = lockdownd_get_value(lockdown, key, NULL, &value);
    lockdownd_client_free(lockdown);
    if (ffi_error) return wp_fail_ffi(error, 11, "Could not read device information", ffi_error);

    char *text = NULL;
    if (value && plist_get_node_type(value) == PLIST_STRING) {
        plist_get_string_val(value, &text);
    }
    *out_value = wp_strdup(text ? text : "");
    if (text) plist_mem_free(text);
    if (value) plist_free(value);
    return 0;
}

int wp_session_ddi_mounted(wp_session *session, int *out_mounted, char **error) {
    if (!session || !out_mounted) return wp_fail(error, 1, "Invalid arguments");
    *out_mounted = 0;

    // iOS 26.4+ installs developer support as a cryptex.
    struct InstalledCryptexC *installed = NULL;
    struct IdeviceFfiError *cryptex_error = cryptexd_installed_ddi(session->adapter, session->handshake, &installed);
    if (!cryptex_error && installed) {
        cryptexd_free_installed_cryptex(installed);
        *out_mounted = 1;
        return 0;
    }
    int cryptex_answered = cryptex_error == NULL;
    if (cryptex_error) idevice_error_free(cryptex_error);

    struct ImageMounterHandle *mounter = NULL;
    struct IdeviceFfiError *ffi_error = image_mounter_connect_rsd(session->adapter, session->handshake, &mounter);
    if (ffi_error) {
        if (cryptex_answered) {
            idevice_error_free(ffi_error);
            return 0;
        }
        return wp_fail_ffi(error, 12, "Could not check developer support", ffi_error);
    }

    plist_t *devices = NULL;
    size_t count = 0;
    ffi_error = image_mounter_copy_devices(mounter, &devices, &count);
    image_mounter_free(mounter);
    if (ffi_error) {
        if (cryptex_answered) {
            idevice_error_free(ffi_error);
            return 0;
        }
        return wp_fail_ffi(error, 12, "Could not list mounted images", ffi_error);
    }
    if (devices) {
        idevice_plist_array_free(devices, count);
        idevice_outer_slice_free(devices, count);
    }
    *out_mounted = count > 0;
    return 0;
}

static int wp_read_file(const char *directory, const char *name, uint8_t **out_data, size_t *out_length, char **error) {
    char path[4096];
    snprintf(path, sizeof(path), "%s/%s", directory, name);
    FILE *file = fopen(path, "rb");
    if (!file) {
        char message[256];
        snprintf(message, sizeof(message), "Missing developer support file %s", name);
        return wp_fail(error, 13, message);
    }
    fseek(file, 0, SEEK_END);
    long length = ftell(file);
    fseek(file, 0, SEEK_SET);
    if (length <= 0) {
        fclose(file);
        return wp_fail(error, 13, "A developer support file is empty");
    }
    uint8_t *data = malloc((size_t)length);
    if (!data || fread(data, 1, (size_t)length, file) != (size_t)length) {
        free(data);
        fclose(file);
        return wp_fail(error, 13, "Could not read a developer support file");
    }
    fclose(file);
    *out_data = data;
    *out_length = (size_t)length;
    return 0;
}

int wp_session_mount_ddi(wp_session *session, const char *ddi_directory, int use_cryptex, char **error) {
    if (!session || !ddi_directory) return wp_fail(error, 1, "Invalid arguments");
    struct IdeviceFfiError *ffi_error = NULL;

    if (use_cryptex) {
        struct Cryptex1AssetsHandle *assets = NULL;
        ffi_error = cryptex1_assets_load(ddi_directory, &assets);
        if (ffi_error) return wp_fail_ffi(error, 14, "Could not load developer support files", ffi_error);
        ffi_error = cryptexd_install_ddi(session->adapter, session->handshake, assets, NULL);
        cryptex1_assets_free(assets);
        if (ffi_error) return wp_fail_ffi(error, 15, "Could not install developer support", ffi_error);
        return 0;
    }

    // Personalized image (iOS 17 - 26.3) needs the chip ID for Apple's ticket.
    struct LockdowndClientHandle *lockdown = NULL;
    ffi_error = lockdownd_connect_rsd(session->adapter, session->handshake, &lockdown);
    if (ffi_error) return wp_fail_ffi(error, 11, "Could not open lockdown", ffi_error);
    plist_t chip_plist = NULL;
    ffi_error = lockdownd_get_value(lockdown, "UniqueChipID", NULL, &chip_plist);
    lockdownd_client_free(lockdown);
    if (ffi_error) return wp_fail_ffi(error, 11, "Could not read the chip ID", ffi_error);
    uint64_t chip_id = 0;
    if (chip_plist) {
        plist_get_uint_val(chip_plist, &chip_id);
        plist_free(chip_plist);
    }
    if (chip_id == 0) return wp_fail(error, 11, "The iPhone did not report its chip ID");

    uint8_t *image = NULL, *trust_cache = NULL, *manifest = NULL;
    size_t image_length = 0, trust_cache_length = 0, manifest_length = 0;
    int status = wp_read_file(ddi_directory, "Image.dmg", &image, &image_length, error);
    if (status == 0) status = wp_read_file(ddi_directory, "Image.dmg.trustcache", &trust_cache, &trust_cache_length, error);
    if (status == 0) status = wp_read_file(ddi_directory, "BuildManifest.plist", &manifest, &manifest_length, error);
    if (status != 0) {
        free(image);
        free(trust_cache);
        free(manifest);
        return status;
    }

    struct ImageMounterHandle *mounter = NULL;
    ffi_error = image_mounter_connect_rsd(session->adapter, session->handshake, &mounter);
    if (!ffi_error) {
        ffi_error = image_mounter_mount_personalized_rsd(mounter, session->adapter, session->handshake, image, image_length,
                                                         trust_cache, trust_cache_length, manifest, manifest_length, NULL,
                                                         chip_id);
        image_mounter_free(mounter);
    }
    free(image);
    free(trust_cache);
    free(manifest);
    if (ffi_error) return wp_fail_ffi(error, 15, "Could not mount developer support", ffi_error);
    return 0;
}

static void wp_close_location(wp_session *session) {
    // The location client borrows the remote server, so free it first.
    if (session->location) {
        location_simulation_free(session->location);
        session->location = NULL;
    }
    if (session->remote_server) {
        remote_server_free(session->remote_server);
        session->remote_server = NULL;
    }
}

static int wp_open_location(wp_session *session, char **error) {
    if (session->location) return 0;
    struct IdeviceFfiError *ffi_error = remote_server_connect_rsd(session->adapter, session->handshake, &session->remote_server);
    if (ffi_error) {
        wp_close_location(session);
        return wp_fail_ffi(error, 16, "Could not open developer services (is developer support mounted?)", ffi_error);
    }
    ffi_error = location_simulation_new(session->remote_server, &session->location);
    if (ffi_error) {
        wp_close_location(session);
        return wp_fail_ffi(error, 17, "Could not start location simulation", ffi_error);
    }
    return 0;
}

int wp_session_set_location(wp_session *session, double latitude, double longitude, char **error) {
    if (!session) return wp_fail(error, 1, "Invalid arguments");
    if (latitude < -90.0 || latitude > 90.0 || longitude < -180.0 || longitude > 180.0) {
        return wp_fail(error, 18, "Coordinates are out of range");
    }
    int status = wp_open_location(session, error);
    if (status != 0) return status;
    struct IdeviceFfiError *ffi_error = location_simulation_set(session->location, latitude, longitude);
    if (ffi_error) {
        wp_close_location(session);
        return wp_fail_ffi(error, 19, "The iPhone refused the location", ffi_error);
    }
    return 0;
}

int wp_session_clear_location(wp_session *session, char **error) {
    if (!session) return wp_fail(error, 1, "Invalid arguments");
    int status = wp_open_location(session, error);
    if (status != 0) return status;
    struct IdeviceFfiError *ffi_error = location_simulation_clear(session->location);
    wp_close_location(session);
    if (ffi_error) return wp_fail_ffi(error, 20, "Could not restore the real location", ffi_error);
    return 0;
}

void wp_session_free(wp_session *session) {
    if (!session) return;
    wp_close_location(session);
    if (session->handshake) rsd_handshake_free(session->handshake);
    if (session->adapter) adapter_free(session->adapter);
    free(session);
}
