#ifndef NEBULA_REGISTRY_H
#define NEBULA_REGISTRY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define NR_MAX_PEERS 256
#define NR_MAX_EVENTS 2048
#define NR_MAX_ADDRS 8
#define NR_MAX_GROUPS 16
#define NR_MAX_NETWORKS 8
#define NR_MAX_ALIASES 8
#define NR_MAX_UPSTREAMS 8
#define NR_MAX_EXTRA_CERTS 16
#define NR_MAX_ACTION_BODY 4096
#define NR_DNS_TTL 60
#define NR_PERIODIC_FLUSH_SEC 300.0

enum {
	NR_OK = 0,
	NR_ERR_ONLINE = -1,
	NR_ERR_NOTFOUND = -2,
	NR_ERR_IO = -3,
	NR_ERR_PARSE = -4,
};

typedef struct {
	char fingerprint[128];
	char name[128];
	char vpn_addrs[NR_MAX_ADDRS][64];
	int n_vpn_addrs;
	char groups[NR_MAX_GROUPS][64];
	int n_groups;
	char issuer[128];
	char not_before[64];
	char not_after[64];
	char underlay[128];
	bool has_underlay;
	bool relayed;
} nr_obs;

typedef struct {
	char network[64];
	char fingerprint[128];
	char name[128];
	char vpn_addrs[NR_MAX_ADDRS][64];
	int n_vpn_addrs;
	char groups[NR_MAX_GROUPS][64];
	int n_groups;
	char issuer[128];
	char not_before[64];
	char not_after[64];
	double first_seen;
	double last_seen;
	char last_underlay[128];
	bool has_underlay;
	bool relayed;
	bool online;
	double archived_at;
	bool is_archived;
	char archived_by[192];
} nr_peer;

typedef struct {
	char address[64];
	char name[128];
} nr_addr_share;

typedef struct {
	const nr_peer *peer;
	char superseded_by[128];
	char duplicates[16][128];
	int n_duplicates;
	nr_addr_share shares[16];
	int n_shares;
} nr_annotated;

typedef struct {
	double ts;
	char network[64];
	char fingerprint[128];
	char kind[32];
	char detail[256];
	bool has_detail;
} nr_event;

typedef struct {
	char state_path[512];
	double offline_after;
	double last_saved;
	nr_peer *peers;
	int n_peers;
	int cap_peers;
	nr_event *events;
	int n_events;
	int cap_events;
} nr_registry;

typedef struct {
	char domain[256];
	char address[64];
	char site[256];
	char aliases[NR_MAX_ALIASES][256];
	int n_aliases;
} nr_zone;

typedef struct {
	char host[256];
	char cert_file[512];
	char key_file[512];
} nr_cert_pair;

typedef struct {
	bool enabled;
	char cert_file[512];
	char key_file[512];
	int port;
	nr_cert_pair extras[NR_MAX_EXTRA_CERTS];
	int n_extras;
} nr_tls_config;

typedef struct {
	char name[64];
	char address[64];
	int console_port;
	int dns_port;
	char domain[256];
	char site[256];
	char aliases[NR_MAX_ALIASES][256];
	int n_aliases;
	char admin_groups[NR_MAX_GROUPS][64];
	int n_admin_groups;
} nr_net_config;

typedef struct {
	char state_dir[512];
	char console_user[64];
	double poll_interval;
	double offline_after_polls;
	int event_retention_days;
	char ssh_bin[512];
	char upstreams[NR_MAX_UPSTREAMS][64];
	int n_upstreams;
	nr_tls_config tls;
	nr_net_config nets[NR_MAX_NETWORKS];
	int n_nets;
} nr_app_config;

typedef struct {
	char *data;
	size_t len;
	size_t cap;
} nr_buf;

/* Buffer helpers */
void nr_buf_init(nr_buf *b, size_t initial_cap);
void nr_buf_free(nr_buf *b);
void nr_buf_append_n(nr_buf *b, const char *s, size_t n);
void nr_buf_append(nr_buf *b, const char *s);
void nr_buf_appendf(nr_buf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
void nr_buf_append_html(nr_buf *b, const char *s);

/* Core parsing and registry logic (registry.c) */
int nr_parse_config(const char *json_str, nr_app_config *out);
int nr_parse_hostmap(const char *json_str, nr_obs *out, int max_out);
int nr_parse_self(const char *json_str, nr_obs *out);
bool nr_dns_label(const char *name, char *out, size_t out_sz);
bool nr_cidr_to_ip(const char *cidr, char *out, size_t out_sz);
bool nr_ip_in_cidr(const char *ip_str, const char *cidr_str);

int nr_registry_init(nr_registry *r, const char *state_path, double offline_after);
void nr_registry_free(nr_registry *r);
int nr_registry_record(nr_registry *r, const char *network, const nr_obs *obs, int n_obs, double now);
int nr_registry_sweep(nr_registry *r, const char *network, double now);
int nr_registry_prune(nr_registry *r, double now, int retention_days);
int nr_registry_archive(nr_registry *r, const char *network, const char *fp, const char *by, double now);
int nr_registry_restore(nr_registry *r, const char *network, const char *fp, const char *by, double now);

const nr_peer *nr_find_caller(const nr_registry *r, const char *network, const char *src_ip);
int nr_visible_peers(const nr_registry *r, const char *network, const nr_peer *caller, const nr_peer **out, int max_out);
void nr_annotate(const nr_peer *const *peers, int n_peers, nr_annotated *out);
bool nr_can_manage(const nr_peer *caller, const char admin_groups[][64], int n_admin_groups);
bool nr_same_origin(const char *origin, const char *host);

void nr_render_peers_json(const char *network, const nr_peer *caller, const nr_annotated *peers, int n_peers, nr_buf *out);
void nr_render_status_json(const nr_peer *caller, const nr_annotated *peers, int n_peers, double now, bool manage, nr_buf *out);
void nr_render_html(const char *network, const nr_peer *caller, const nr_annotated *peers, int n_peers, double now, bool manage, nr_buf *out);

/* DNS (dns.c) */
bool nr_dns_is_local(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone);
size_t nr_dns_answer(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone, const nr_registry *r, const char *network, uint32_t serial, uint8_t *out, size_t out_cap);
size_t nr_dns_forward(const uint8_t *pkt, size_t pkt_len, const char upstreams[][64], int n_upstreams, bool tcp, uint8_t *out, size_t out_cap);
size_t nr_dns_respond(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone, const nr_registry *r, const char *network, uint32_t serial, const char upstreams[][64], int n_upstreams, bool tcp, uint8_t *out, size_t out_cap);

/* Server / TLS / Keygen (server.c) */
typedef struct nr_tls_server nr_tls_server;
nr_tls_server *nr_tls_server_new(const nr_tls_config *cfg);
void nr_tls_server_free(nr_tls_server *s);
int nr_keygen_ecdsa(const char *path);
int nr_self_signed(const char *cert_path, const char *key_path, const char *hostname);
int nr_run_server(const nr_app_config *cfg);
int nr_handle_http_request(const char *raw_req, size_t raw_len, const char *src_ip, const char *network, nr_registry *reg, const char admin_groups[][64], int n_admin_groups, double now, nr_buf *resp_out);
int nr_tls_accept_and_serve_once(nr_tls_server *tls, int client_fd, const char *src_ip, const char *network, nr_registry *reg, const char admin_groups[][64], int n_admin_groups, double now);

#endif
