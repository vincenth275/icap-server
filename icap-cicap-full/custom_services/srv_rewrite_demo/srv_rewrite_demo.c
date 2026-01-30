/*
 * srv_rewrite_demo - minimal c-icap service to demonstrate header + body rewrite.
 *
 * Behavior:
 *  - Always adds a response header: X-ICAP-Rewritten: 1
 *  - If Content-Type starts with text/, replace ASCII token ORIGINAL with REWRITTEN
 *    in the payload stream (same length replacement).
 *
 * Deterministic, intentionally tiny.
 */
#include <stdlib.h>
#include <string.h>

#include <c_icap/c-icap.h>
#include <c_icap/service.h>
#include <c_icap/header.h>
#include <c_icap/body.h>
#include <c_icap/simple_api.h>

struct rewrite_req_data {
    int is_text;
};

static int  rewrite_init_service(ci_service_xdata_t *srv_xdata, struct ci_server_conf *server_conf);
static void rewrite_close_service(void);
static void *rewrite_init_request_data(ci_request_t *req);
static void rewrite_release_request_data(void *data);
static int  rewrite_check_preview_handler(char *preview_data, int preview_data_len, ci_request_t *req);
static int  rewrite_end_of_data_handler(ci_request_t *req);
static int  rewrite_io(char *wbuf, int *wlen, char *rbuf, int *rlen, int iseof, ci_request_t *req);

CI_DECLARE_MOD_DATA ci_service_module_t service = {
    "rewrite_demo",
    "Rewrite demo service (header + body token rewrite)",
    ICAP_RESPMOD | ICAP_REQMOD,
    rewrite_init_service,
    NULL,
    rewrite_close_service,
    rewrite_init_request_data,
    rewrite_release_request_data,
    rewrite_check_preview_handler,
    rewrite_end_of_data_handler,
    rewrite_io,
    NULL,
    NULL
};

static int starts_with_ci(const char *s, const char *p) {
    if (!s || !p) return 0;
    return strncasecmp(s, p, strlen(p)) == 0;
}

static void add_demo_header(ci_request_t *req) {
    ci_headers_list_t *hdrs = ci_http_response_headers(req);
    if (!hdrs) return;
    ci_headers_add(hdrs, "X-ICAP-Rewritten: 1");
}

static int is_textual(ci_request_t *req) {
    const char *ct = ci_http_response_get_header(req, "Content-Type");
    if (!ct) return 0;
    return starts_with_ci(ct, "text/");
}

static void replace_token_inplace(char *buf, int len) {
    const char *from = "ORIGINAL";
    const char *to   = "REWRITTEN";
    const int from_len = (int)strlen(from);
    const int to_len   = (int)strlen(to);
    if (from_len != to_len) return; // keep it simple: same length required

    for (int i = 0; i <= len - from_len; i++) {
        if (memcmp(buf + i, from, (size_t)from_len) == 0) {
            memcpy(buf + i, to, (size_t)to_len);
            i += from_len - 1;
        }
    }
}

/* Called when service is loaded */
static int rewrite_init_service(ci_service_xdata_t *srv_xdata, struct ci_server_conf *server_conf) {
    (void)server_conf;
    /* Ask clients to send preview data; 1024 is a sensible demo value */
    ci_service_set_preview(srv_xdata, 1024);
    /* Allow 204 responses (no modification) */
    ci_service_enable_204(srv_xdata);
    /* Request preview for all content-types */
    ci_service_set_transfer_preview(srv_xdata, "*");
    return CI_OK;
}

/* Called when service shuts down */
static void rewrite_close_service(void) {
    /* nothing */
}

/* Per-request init: allocate ctx, decide if text, add header once */
static void *rewrite_init_request_data(ci_request_t *req) {
    struct rewrite_req_data *d = (struct rewrite_req_data*)calloc(1, sizeof(*d));
    if (!d) return NULL;

    d->is_text = is_textual(req);
    add_demo_header(req);
    return d;
}

static void rewrite_release_request_data(void *data) {
    free(data);
}

static int rewrite_check_preview_handler(char *preview_data, int preview_data_len, ci_request_t *req) {
    (void)preview_data; (void)preview_data_len; (void)req;
    return CI_MOD_CONTINUE;
}

static int rewrite_end_of_data_handler(ci_request_t *req) {
    (void)req;
    return CI_OK;
}

/* Streaming I/O:
 *  - rbuf/rlen: bytes from origin (encapsulated HTTP)
 *  - wbuf/wlen: bytes to client
 *
 * We only do in-place rewrite of rbuf for text/*.
 */
static int rewrite_io(char *wbuf, int *wlen, char *rbuf, int *rlen, int iseof, ci_request_t *req) {
    (void)wbuf; (void)wlen; (void)iseof;
    struct rewrite_req_data *d = (struct rewrite_req_data*)ci_service_data(req);
    if (!d || !d->is_text) return CI_MOD_CONTINUE;

    if (rbuf && rlen && *rlen > 0) {
        replace_token_inplace(rbuf, *rlen);
    }
    return CI_MOD_CONTINUE;
}
