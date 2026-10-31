// Host-side checks for the Waypoint device layer. Builds against the real
// idevice static library (Linux or macOS) and exercises every code path that
// does not need an iPhone: pairing host setup, cancel, malformed peers,
// pairing-file validation, connection failures and argument checks.
#include <arpa/inet.h>
#include <assert.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#include "../Waypoint/Device/wp_device.h"

static int failures = 0;
#define CHECK(cond, msg)                                   \
    do {                                                   \
        if (cond) {                                        \
            printf("  ok   %s\n", msg);                    \
        } else {                                           \
            printf("  FAIL %s\n", msg);                    \
            failures++;                                    \
        }                                                  \
    } while (0)

static void *cancel_later(void *arg) {
    usleep(300 * 1000);
    wp_pairing_cancel((wp_pairing *)arg);
    return NULL;
}

struct bad_peer { uint16_t port; };
static void *bad_peer_main(void *arg) {
    struct bad_peer *peer = arg;
    usleep(200 * 1000);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_port = htons(peer->port);
    inet_pton(AF_INET, "127.0.0.1", &address.sin_addr);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0) {
        const char junk[] = "GET / HTTP/1.1\r\n\r\nthis is not a remote pairing peer";
        write(fd, junk, sizeof(junk));
        usleep(200 * 1000);
    }
    close(fd);
    return NULL;
}

int main(void) {
    char *error = NULL;
    setvbuf(stdout, NULL, _IONBF, 0);
    alarm(120); // never let a hang stall the build
    wp_pairing *idle = NULL;
    char *idle_id = NULL;
    uint8_t *idle_txt = NULL;
    size_t idle_len = 0;
    uint16_t idle_port = 0;

    printf("cancel before accept\n");
    int idle_status = wp_pairing_start("Waypoint-idle", &idle, &idle_id, &idle_txt, &idle_len, &idle_port, &error);
    CHECK(idle_status == 0, "second pairing host starts");
    wp_pairing_cancel(idle);
    idle_status = wp_pairing_accept(idle, "/tmp/wp_should_not_exist.plist", NULL, NULL, NULL, NULL, &error);
    CHECK(idle_status != 0, "accept returns at once after an earlier cancel");
    if (error) { wp_string_free(error); error = NULL; }
    wp_pairing_free(idle);
    wp_string_free(idle_id);
    wp_data_free(idle_txt, idle_len);

    printf("pairing host\n");
    wp_pairing *pairing = NULL;
    char *service_id = NULL;
    uint8_t *txt = NULL;
    size_t txt_length = 0;
    uint16_t port = 0;
    int status = wp_pairing_start("Waypoint-test", &pairing, &service_id, &txt, &txt_length, &port, &error);
    CHECK(status == 0, "wp_pairing_start succeeds");
    if (status != 0) { printf("    %s\n", error); return 1; }
    CHECK(service_id && strlen(service_id) > 0, "service id returned");
    CHECK(txt_length > 8 && (memcmp(txt, "bplist00", 8) == 0 || memcmp(txt, "<?xml", 5) == 0), "TXT record is a plist");
    CHECK(port != 0, "listener has a port");
    printf("    service=%s port=%u txt=%zu bytes\n", service_id, port, txt_length);

    // A peer that is not an iPhone must fail cleanly, not crash or hang.
    struct bad_peer peer = {port};
    pthread_t thread;
    pthread_create(&thread, NULL, bad_peer_main, &peer);
    int is_local = -1;
    char *name = NULL;
    status = wp_pairing_accept(pairing, "/tmp/wp_should_not_exist.plist", NULL, NULL, &is_local, &name, &error);
    pthread_join(thread, NULL);
    CHECK(status != 0, "junk peer is rejected");
    if (error) { printf("    error: %s\n", error); wp_string_free(error); error = NULL; }
    CHECK(access("/tmp/wp_should_not_exist.plist", F_OK) != 0, "no pairing file written on failure");

    // Cancel unblocks a waiting accept.
    pthread_create(&thread, NULL, cancel_later, pairing);
    status = wp_pairing_accept(pairing, "/tmp/wp_should_not_exist.plist", NULL, NULL, &is_local, &name, &error);
    pthread_join(thread, NULL);
    CHECK(status != 0, "cancel unblocks accept");
    if (error) { printf("    error: %s\n", error); wp_string_free(error); error = NULL; }
    wp_pairing_free(pairing);
    wp_string_free(service_id);
    wp_data_free(txt, txt_length);

    printf("pairing files\n");
    FILE *file = fopen("/tmp/wp_bad_pairing.plist", "w");
    fputs("not a plist", file);
    fclose(file);
    status = wp_pairing_file_check("/tmp/wp_bad_pairing.plist", &error);
    CHECK(status != 0, "garbage pairing file rejected");
    if (error) { printf("    error: %s\n", error); wp_string_free(error); error = NULL; }
    status = wp_pairing_file_check("/tmp/does/not/exist.plist", &error);
    CHECK(status != 0, "missing pairing file rejected");
    if (error) { wp_string_free(error); error = NULL; }

    printf("session\n");
    wp_session *session = NULL;
    status = wp_session_connect("not-an-ip", 49152, "Waypoint", "/tmp/wp_bad_pairing.plist", &session, &error);
    CHECK(status != 0 && session == NULL, "invalid IP rejected");
    if (error) { printf("    error: %s\n", error); wp_string_free(error); error = NULL; }
    status = wp_session_connect("127.0.0.1", 1, "Waypoint", "/tmp/wp_bad_pairing.plist", &session, &error);
    CHECK(status != 0 && session == NULL, "bad pairing file stops connect");
    if (error) { printf("    error: %s\n", error); wp_string_free(error); error = NULL; }
    status = wp_session_set_location(NULL, 1, 2, &error);
    CHECK(status != 0, "null session rejected");
    if (error) { wp_string_free(error); error = NULL; }
    wp_session_free(NULL);
    CHECK(1, "freeing NULL is safe");

    printf("%s (%d failures)\n", failures ? "FAILED" : "PASSED", failures);
    return failures ? 1 : 0;
}
