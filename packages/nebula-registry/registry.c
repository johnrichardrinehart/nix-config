#define _POSIX_C_SOURCE 200809L

#include "registry.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <cjson/cJSON.h>

#include "page_html.h"

/* ---- Dynamic string buffer ---- */

void nr_buf_init(nr_buf *b, size_t initial_cap) {
	b->len = 0;
	b->cap = initial_cap < 64 ? 64 : initial_cap;
	b->data = malloc(b->cap);
	if (b->data)
		b->data[0] = '\0';
}

void nr_buf_free(nr_buf *b) {
	free(b->data);
	b->data = NULL;
	b->len = 0;
	b->cap = 0;
}

static void nr_buf_reserve(nr_buf *b, size_t extra) {
	if (!b->data)
		return;
	if (b->len + extra + 1 <= b->cap)
		return;
	size_t ncap = b->cap * 2;
	while (ncap < b->len + extra + 1)
		ncap *= 2;
	char *nd = realloc(b->data, ncap);
	if (!nd)
		return;
	b->data = nd;
	b->cap = ncap;
}

void nr_buf_append_n(nr_buf *b, const char *s, size_t n) {
	if (!b->data || !s || n == 0)
		return;
	nr_buf_reserve(b, n);
	if (b->len + n + 1 > b->cap)
		return;
	memcpy(b->data + b->len, s, n);
	b->len += n;
	b->data[b->len] = '\0';
}

void nr_buf_append(nr_buf *b, const char *s) {
	if (s)
		nr_buf_append_n(b, s, strlen(s));
}

void nr_buf_appendf(nr_buf *b, const char *fmt, ...) {
	va_list ap, ap2;
	va_start(ap, fmt);
	va_copy(ap2, ap);
	int n = vsnprintf(NULL, 0, fmt, ap);
	va_end(ap);
	if (n > 0) {
		nr_buf_reserve(b, (size_t)n);
		if (b->data && b->len + (size_t)n + 1 <= b->cap) {
			vsnprintf(b->data + b->len, b->cap - b->len, fmt, ap2);
			b->len += (size_t)n;
		}
	}
	va_end(ap2);
}

void nr_buf_append_html(nr_buf *b, const char *s) {
	if (!s)
		return;
	for (const char *p = s; *p; p++) {
		switch (*p) {
		case '&': nr_buf_append(b, "&amp;"); break;
		case '<': nr_buf_append(b, "&lt;"); break;
		case '>': nr_buf_append(b, "&gt;"); break;
		case '"': nr_buf_append(b, "&quot;"); break;
		case '\'': nr_buf_append(b, "&#x27;"); break;
		default: nr_buf_append_n(b, p, 1); break;
		}
	}
}

static void copy_str(char *dst, size_t dst_sz, const char *src) {
	if (!dst || dst_sz == 0)
		return;
	if (!src) {
		dst[0] = '\0';
		return;
	}
	size_t n = strlen(src);
	if (n >= dst_sz)
		n = dst_sz - 1;
	memcpy(dst, src, n);
	dst[n] = '\0';
}

static const char *json_str(const cJSON *obj, const char *key) {
	const cJSON *item = cJSON_GetObjectItemCaseSensitive(obj, key);
	return (item && cJSON_IsString(item) && item->valuestring) ? item->valuestring : NULL;
}

/* ---- Config & Console JSON Parsing ---- */

int nr_parse_config(const char *json_str_in, nr_app_config *out) {
	memset(out, 0, sizeof(*out));
	out->poll_interval = 10.0;
	out->offline_after_polls = 3.0;
	out->event_retention_days = 365;
	copy_str(out->console_user, sizeof(out->console_user), "registry");
	copy_str(out->ssh_bin, sizeof(out->ssh_bin), "ssh");

	cJSON *root = cJSON_Parse(json_str_in);
	if (!root || !cJSON_IsObject(root)) {
		cJSON_Delete(root);
		return NR_ERR_PARSE;
	}

	const char *s;
	if ((s = json_str(root, "stateDir")))
		copy_str(out->state_dir, sizeof(out->state_dir), s);
	if ((s = json_str(root, "consoleUser")))
		copy_str(out->console_user, sizeof(out->console_user), s);
	if ((s = json_str(root, "ssh")))
		copy_str(out->ssh_bin, sizeof(out->ssh_bin), s);

	const cJSON *v;
	if ((v = cJSON_GetObjectItemCaseSensitive(root, "pollInterval")) && cJSON_IsNumber(v))
		out->poll_interval = v->valuedouble;
	if ((v = cJSON_GetObjectItemCaseSensitive(root, "offlineAfterPolls")) && cJSON_IsNumber(v))
		out->offline_after_polls = v->valuedouble;
	if ((v = cJSON_GetObjectItemCaseSensitive(root, "eventRetentionDays")) && cJSON_IsNumber(v))
		out->event_retention_days = v->valueint;

	const cJSON *ups = cJSON_GetObjectItemCaseSensitive(root, "upstreamResolvers");
	if (cJSON_IsArray(ups)) {
		const cJSON *item;
		cJSON_ArrayForEach(item, ups) {
			if (cJSON_IsString(item) && out->n_upstreams < NR_MAX_UPSTREAMS)
				copy_str(out->upstreams[out->n_upstreams++], 64, item->valuestring);
		}
	}

	const cJSON *tls = cJSON_GetObjectItemCaseSensitive(root, "tls");
	if (cJSON_IsObject(tls)) {
		out->tls.enabled = true;
		out->tls.port = 443;
		if ((s = json_str(tls, "certFile")))
			copy_str(out->tls.cert_file, sizeof(out->tls.cert_file), s);
		if ((s = json_str(tls, "keyFile")))
			copy_str(out->tls.key_file, sizeof(out->tls.key_file), s);
		if ((v = cJSON_GetObjectItemCaseSensitive(tls, "port")) && cJSON_IsNumber(v))
			out->tls.port = v->valueint;
		const cJSON *extras = cJSON_GetObjectItemCaseSensitive(tls, "extraCertificates");
		if (cJSON_IsObject(extras)) {
			const cJSON *entry;
			cJSON_ArrayForEach(entry, extras) {
				if (cJSON_IsObject(entry) && entry->string && out->tls.n_extras < NR_MAX_EXTRA_CERTS) {
					nr_cert_pair *cp = &out->tls.extras[out->tls.n_extras++];
					copy_str(cp->host, sizeof(cp->host), entry->string);
					copy_str(cp->cert_file, sizeof(cp->cert_file), json_str(entry, "certFile"));
					copy_str(cp->key_file, sizeof(cp->key_file), json_str(entry, "keyFile"));
				}
			}
		}
	}

	const cJSON *nets = cJSON_GetObjectItemCaseSensitive(root, "networks");
	if (cJSON_IsObject(nets)) {
		const cJSON *net;
		cJSON_ArrayForEach(net, nets) {
			if (!cJSON_IsObject(net) || !net->string || out->n_nets >= NR_MAX_NETWORKS)
				continue;
			nr_net_config *nc = &out->nets[out->n_nets++];
			copy_str(nc->name, sizeof(nc->name), net->string);
			copy_str(nc->address, sizeof(nc->address), json_str(net, "address"));
			copy_str(nc->domain, sizeof(nc->domain), json_str(net, "domain"));
			copy_str(nc->site, sizeof(nc->site), json_str(net, "site"));
			nc->dns_port = 53;
			if ((v = cJSON_GetObjectItemCaseSensitive(net, "consolePort")) && cJSON_IsNumber(v))
				nc->console_port = v->valueint;
			if ((v = cJSON_GetObjectItemCaseSensitive(net, "dnsPort")) && cJSON_IsNumber(v))
				nc->dns_port = v->valueint;
			const cJSON *aliases = cJSON_GetObjectItemCaseSensitive(net, "aliases");
			if (cJSON_IsArray(aliases)) {
				const cJSON *a;
				cJSON_ArrayForEach(a, aliases) {
					if (cJSON_IsString(a) && nc->n_aliases < NR_MAX_ALIASES)
						copy_str(nc->aliases[nc->n_aliases++], 256, a->valuestring);
				}
			}
			const cJSON *admins = cJSON_GetObjectItemCaseSensitive(net, "adminGroups");
			if (cJSON_IsArray(admins)) {
				const cJSON *g;
				cJSON_ArrayForEach(g, admins) {
					if (cJSON_IsString(g) && nc->n_admin_groups < NR_MAX_GROUPS)
						copy_str(nc->admin_groups[nc->n_admin_groups++], 64, g->valuestring);
				}
			}
		}
	}

	cJSON_Delete(root);
	return NR_OK;
}

static bool obs_from_cert(const cJSON *cert, const char *remote, bool relayed, nr_obs *out) {
	memset(out, 0, sizeof(*out));
	const char *fp = json_str(cert, "fingerprint");
	if (!fp || !fp[0])
		return false;
	copy_str(out->fingerprint, sizeof(out->fingerprint), fp);

	const cJSON *details = cJSON_GetObjectItemCaseSensitive(cert, "details");
	if (cJSON_IsObject(details)) {
		copy_str(out->name, sizeof(out->name), json_str(details, "name"));
		copy_str(out->issuer, sizeof(out->issuer), json_str(details, "issuer"));
		copy_str(out->not_before, sizeof(out->not_before), json_str(details, "notBefore"));
		copy_str(out->not_after, sizeof(out->not_after), json_str(details, "notAfter"));

		const cJSON *nets = cJSON_GetObjectItemCaseSensitive(details, "networks");
		if (!cJSON_IsArray(nets) || cJSON_GetArraySize(nets) == 0)
			nets = cJSON_GetObjectItemCaseSensitive(details, "ips");
		if (cJSON_IsArray(nets)) {
			const cJSON *item;
			cJSON_ArrayForEach(item, nets) {
				if (cJSON_IsString(item) && out->n_vpn_addrs < NR_MAX_ADDRS)
					copy_str(out->vpn_addrs[out->n_vpn_addrs++], 64, item->valuestring);
			}
		}

		const cJSON *grps = cJSON_GetObjectItemCaseSensitive(details, "groups");
		if (cJSON_IsArray(grps)) {
			const cJSON *item;
			cJSON_ArrayForEach(item, grps) {
				if (cJSON_IsString(item) && out->n_groups < NR_MAX_GROUPS)
					copy_str(out->groups[out->n_groups++], 64, item->valuestring);
			}
		}
	}

	if (remote && remote[0] && strcmp(remote, "invalid AddrPort") != 0) {
		copy_str(out->underlay, sizeof(out->underlay), remote);
		out->has_underlay = true;
	}
	out->relayed = relayed;
	return true;
}

int nr_parse_hostmap(const char *json_str_in, nr_obs *out, int max_out) {
	cJSON *root = cJSON_Parse(json_str_in);
	if (!root)
		return NR_ERR_PARSE;
	int count = 0;
	if (cJSON_IsArray(root)) {
		const cJSON *entry;
		cJSON_ArrayForEach(entry, root) {
			if (!cJSON_IsObject(entry) || count >= max_out)
				continue;
			const cJSON *cert = cJSON_GetObjectItemCaseSensitive(entry, "cert");
			if (!cJSON_IsObject(cert))
				continue;
			const char *remote = json_str(entry, "currentRemote");
			const cJSON *relays = cJSON_GetObjectItemCaseSensitive(entry, "currentRelaysToMe");
			bool relayed = cJSON_IsArray(relays) && cJSON_GetArraySize(relays) > 0;
			if (obs_from_cert(cert, remote, relayed, &out[count]))
				count++;
		}
	}
	cJSON_Delete(root);
	return count;
}

int nr_parse_self(const char *json_str_in, nr_obs *out) {
	cJSON *root = cJSON_Parse(json_str_in);
	if (!root)
		return NR_ERR_PARSE;
	const cJSON *cert = root;
	if (cJSON_IsArray(root))
		cert = cJSON_GetArrayItem(root, 0);
	bool ok = cJSON_IsObject(cert) && obs_from_cert(cert, NULL, false, out);
	cJSON_Delete(root);
	return ok ? NR_OK : NR_ERR_PARSE;
}

/* ---- DNS Labels & IP/CIDR Helpers ---- */

bool nr_dns_label(const char *name, char *out, size_t out_sz) {
	if (!name || !out || out_sz < 2)
		return false;
	char tmp[256];
	size_t w = 0;
	bool last_dash = false;
	for (const char *p = name; *p && w + 1 < sizeof(tmp); p++) {
		unsigned char c = (unsigned char)tolower((unsigned char)*p);
		if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-') {
			tmp[w++] = (char)c;
			last_dash = (c == '-');
		} else if (!last_dash) {
			tmp[w++] = '-';
			last_dash = true;
		}
	}
	tmp[w] = '\0';
	size_t start = 0;
	while (start < w && tmp[start] == '-')
		start++;
	size_t end = w;
	while (end > start && tmp[end - 1] == '-')
		end--;
	size_t len = end - start;
	if (len > 63)
		len = 63;
	while (len > 0 && tmp[start + len - 1] == '-')
		len--;
	if (len == 0 || len + 1 > out_sz) {
		out[0] = '\0';
		return false;
	}
	memcpy(out, tmp + start, len);
	out[len] = '\0';
	return true;
}

bool nr_cidr_to_ip(const char *cidr, char *out, size_t out_sz) {
	if (!cidr || !out || out_sz == 0)
		return false;
	const char *slash = strchr(cidr, '/');
	size_t len = slash ? (size_t)(slash - cidr) : strlen(cidr);
	if (len == 0 || len >= out_sz)
		return false;
	memcpy(out, cidr, len);
	out[len] = '\0';
	return true;
}

static bool parse_ip_bytes(const char *s, int *family, uint8_t bytes[16], int *byte_len) {
	struct in_addr a4;
	if (inet_pton(AF_INET, s, &a4) == 1) {
		*family = AF_INET;
		memcpy(bytes, &a4, 4);
		*byte_len = 4;
		return true;
	}
	struct in6_addr a6;
	if (inet_pton(AF_INET6, s, &a6) == 1) {
		*family = AF_INET6;
		memcpy(bytes, &a6, 16);
		*byte_len = 16;
		return true;
	}
	return false;
}

bool nr_ip_in_cidr(const char *ip_str, const char *cidr_str) {
	char net_ip[64];
	const char *slash = strchr(cidr_str, '/');
	if (!nr_cidr_to_ip(cidr_str, net_ip, sizeof(net_ip)))
		return false;

	int f1 = 0, f2 = 0, l1 = 0, l2 = 0;
	uint8_t b1[16], b2[16];
	if (!parse_ip_bytes(ip_str, &f1, b1, &l1) || !parse_ip_bytes(net_ip, &f2, b2, &l2))
		return false;
	if (f1 != f2 || l1 != l2)
		return false;

	int prefix = slash ? atoi(slash + 1) : l1 * 8;
	if (prefix < 0 || prefix > l1 * 8)
		return false;
	int full = prefix / 8;
	int rem = prefix % 8;
	if (full > 0 && memcmp(b1, b2, (size_t)full) != 0)
		return false;
	if (rem > 0) {
		uint8_t mask = (uint8_t)(0xFFu << (8 - rem));
		if ((b1[full] & mask) != (b2[full] & mask))
			return false;
	}
	return true;
}

/* ---- Registry Persistence (Atomic JSON) ---- */

static int ensure_parent_dir(const char *path) {
	char dir[512];
	copy_str(dir, sizeof(dir), path);
	char *slash = strrchr(dir, '/');
	if (!slash || slash == dir)
		return 0;
	*slash = '\0';
	struct stat st;
	if (stat(dir, &st) == 0)
		return 0;
	return mkdir(dir, 0750);
}

static int registry_save(nr_registry *r, double now) {
	if (!r->state_path[0])
		return NR_OK;
	(void)ensure_parent_dir(r->state_path);

	cJSON *root = cJSON_CreateObject();
	cJSON *peers_arr = cJSON_CreateArray();
	for (int i = 0; i < r->n_peers; i++) {
		const nr_peer *p = &r->peers[i];
		cJSON *o = cJSON_CreateObject();
		cJSON_AddStringToObject(o, "network", p->network);
		cJSON_AddStringToObject(o, "fingerprint", p->fingerprint);
		cJSON_AddStringToObject(o, "name", p->name);
		cJSON *addrs = cJSON_CreateArray();
		for (int j = 0; j < p->n_vpn_addrs; j++)
			cJSON_AddItemToArray(addrs, cJSON_CreateString(p->vpn_addrs[j]));
		cJSON_AddItemToObject(o, "vpn_addrs", addrs);
		cJSON *grps = cJSON_CreateArray();
		for (int j = 0; j < p->n_groups; j++)
			cJSON_AddItemToArray(grps, cJSON_CreateString(p->groups[j]));
		cJSON_AddItemToObject(o, "groups", grps);
		cJSON_AddStringToObject(o, "issuer", p->issuer);
		if (p->not_before[0]) cJSON_AddStringToObject(o, "not_before", p->not_before);
		if (p->not_after[0]) cJSON_AddStringToObject(o, "not_after", p->not_after);
		cJSON_AddNumberToObject(o, "first_seen", p->first_seen);
		cJSON_AddNumberToObject(o, "last_seen", p->last_seen);
		if (p->has_underlay) cJSON_AddStringToObject(o, "last_underlay", p->last_underlay);
		cJSON_AddBoolToObject(o, "relayed", p->relayed);
		cJSON_AddBoolToObject(o, "online", p->online);
		if (p->is_archived) {
			cJSON_AddNumberToObject(o, "archived_at", p->archived_at);
			cJSON_AddStringToObject(o, "archived_by", p->archived_by);
		}
		cJSON_AddItemToArray(peers_arr, o);
	}
	cJSON_AddItemToObject(root, "peers", peers_arr);

	cJSON *ev_arr = cJSON_CreateArray();
	for (int i = 0; i < r->n_events; i++) {
		const nr_event *e = &r->events[i];
		cJSON *o = cJSON_CreateObject();
		cJSON_AddNumberToObject(o, "ts", e->ts);
		cJSON_AddStringToObject(o, "network", e->network);
		cJSON_AddStringToObject(o, "fingerprint", e->fingerprint);
		cJSON_AddStringToObject(o, "kind", e->kind);
		if (e->has_detail) cJSON_AddStringToObject(o, "detail", e->detail);
		cJSON_AddItemToArray(ev_arr, o);
	}
	cJSON_AddItemToObject(root, "events", ev_arr);

	char *printed = cJSON_Print(root);
	cJSON_Delete(root);
	if (!printed)
		return NR_ERR_IO;

	char tmp_path[528];
	snprintf(tmp_path, sizeof(tmp_path), "%s.tmp", r->state_path);
	int fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0640);
	if (fd < 0) {
		free(printed);
		return NR_ERR_IO;
	}
	size_t len = strlen(printed);
	ssize_t wr = write(fd, printed, len);
	ssize_t nl = write(fd, "\n", 1);
	int fs = fsync(fd);
	int cl = close(fd);
	free(printed);
	if (wr != (ssize_t)len || nl != 1 || fs != 0 || cl != 0) {
		unlink(tmp_path);
		return NR_ERR_IO;
	}
	if (rename(tmp_path, r->state_path) != 0) {
		unlink(tmp_path);
		return NR_ERR_IO;
	}
	r->last_saved = now;
	return NR_OK;
}

static nr_peer *alloc_peer(nr_registry *r) {
	if (r->n_peers >= NR_MAX_PEERS)
		return NULL;
	if (r->n_peers >= r->cap_peers) {
		int ncap = r->cap_peers == 0 ? 16 : r->cap_peers * 2;
		if (ncap > NR_MAX_PEERS)
			ncap = NR_MAX_PEERS;
		nr_peer *np = realloc(r->peers, (size_t)ncap * sizeof(nr_peer));
		if (!np)
			return NULL;
		r->peers = np;
		r->cap_peers = ncap;
	}
	nr_peer *p = &r->peers[r->n_peers++];
	memset(p, 0, sizeof(*p));
	return p;
}

static void append_event(nr_registry *r, double now, const char *network, const char *fp, const char *kind, const char *detail) {
	if (r->n_events >= NR_MAX_EVENTS) {
		memmove(&r->events[0], &r->events[1], sizeof(nr_event) * (NR_MAX_EVENTS - 1));
		r->n_events = NR_MAX_EVENTS - 1;
	} else if (r->n_events >= r->cap_events) {
		int ncap = r->cap_events == 0 ? 32 : r->cap_events * 2;
		if (ncap > NR_MAX_EVENTS)
			ncap = NR_MAX_EVENTS;
		nr_event *ne = realloc(r->events, (size_t)ncap * sizeof(nr_event));
		if (!ne)
			return;
		r->events = ne;
		r->cap_events = ncap;
	}
	nr_event *e = &r->events[r->n_events++];
	memset(e, 0, sizeof(*e));
	e->ts = now;
	copy_str(e->network, sizeof(e->network), network);
	copy_str(e->fingerprint, sizeof(e->fingerprint), fp);
	copy_str(e->kind, sizeof(e->kind), kind);
	if (detail && detail[0]) {
		copy_str(e->detail, sizeof(e->detail), detail);
		e->has_detail = true;
	}
}

void nr_registry_free(nr_registry *r) {
	if (!r)
		return;
	free(r->peers);
	free(r->events);
	memset(r, 0, sizeof(*r));
}

int nr_registry_init(nr_registry *r, const char *state_path, double offline_after) {
	memset(r, 0, sizeof(*r));
	r->offline_after = offline_after;
	if (state_path && state_path[0])
		copy_str(r->state_path, sizeof(r->state_path), state_path);
	if (!r->state_path[0])
		return NR_OK;

	FILE *f = fopen(r->state_path, "rb");
	if (!f)
		return (errno == ENOENT) ? NR_OK : NR_ERR_IO;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz <= 0 || sz > 4 * 1024 * 1024) {
		fclose(f);
		return NR_OK;
	}
	char *buf = malloc((size_t)sz + 1);
	if (!buf) {
		fclose(f);
		return NR_ERR_IO;
	}
	size_t rd = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	buf[rd] = '\0';

	cJSON *root = cJSON_Parse(buf);
	free(buf);
	if (!root || !cJSON_IsObject(root)) {
		cJSON_Delete(root);
		return NR_ERR_PARSE;
	}

	const cJSON *peers = cJSON_GetObjectItemCaseSensitive(root, "peers");
	if (cJSON_IsArray(peers)) {
		const cJSON *item;
		cJSON_ArrayForEach(item, peers) {
			if (!cJSON_IsObject(item) || r->n_peers >= NR_MAX_PEERS)
				continue;
			nr_peer *p = alloc_peer(r);
			if (!p)
				break;
			copy_str(p->network, sizeof(p->network), json_str(item, "network"));
			copy_str(p->fingerprint, sizeof(p->fingerprint), json_str(item, "fingerprint"));
			copy_str(p->name, sizeof(p->name), json_str(item, "name"));
			copy_str(p->issuer, sizeof(p->issuer), json_str(item, "issuer"));
			copy_str(p->not_before, sizeof(p->not_before), json_str(item, "not_before"));
			copy_str(p->not_after, sizeof(p->not_after), json_str(item, "not_after"));
			const char *u = json_str(item, "last_underlay");
			if (u && u[0]) {
				copy_str(p->last_underlay, sizeof(p->last_underlay), u);
				p->has_underlay = true;
			}
			const cJSON *v;
			if ((v = cJSON_GetObjectItemCaseSensitive(item, "first_seen")) && cJSON_IsNumber(v))
				p->first_seen = v->valuedouble;
			if ((v = cJSON_GetObjectItemCaseSensitive(item, "last_seen")) && cJSON_IsNumber(v))
				p->last_seen = v->valuedouble;
			if ((v = cJSON_GetObjectItemCaseSensitive(item, "relayed")) && cJSON_IsBool(v))
				p->relayed = cJSON_IsTrue(v);
			if ((v = cJSON_GetObjectItemCaseSensitive(item, "online")) && cJSON_IsBool(v))
				p->online = cJSON_IsTrue(v);
			if ((v = cJSON_GetObjectItemCaseSensitive(item, "archived_at")) && cJSON_IsNumber(v)) {
				p->is_archived = true;
				p->archived_at = v->valuedouble;
				copy_str(p->archived_by, sizeof(p->archived_by), json_str(item, "archived_by"));
			}
			const cJSON *addrs = cJSON_GetObjectItemCaseSensitive(item, "vpn_addrs");
			if (cJSON_IsArray(addrs)) {
				const cJSON *a;
				cJSON_ArrayForEach(a, addrs) {
					if (cJSON_IsString(a) && p->n_vpn_addrs < NR_MAX_ADDRS)
						copy_str(p->vpn_addrs[p->n_vpn_addrs++], 64, a->valuestring);
				}
			}
			const cJSON *grps = cJSON_GetObjectItemCaseSensitive(item, "groups");
			if (cJSON_IsArray(grps)) {
				const cJSON *g;
				cJSON_ArrayForEach(g, grps) {
					if (cJSON_IsString(g) && p->n_groups < NR_MAX_GROUPS)
						copy_str(p->groups[p->n_groups++], 64, g->valuestring);
				}
			}
		}
	}

	const cJSON *evs = cJSON_GetObjectItemCaseSensitive(root, "events");
	if (cJSON_IsArray(evs)) {
		const cJSON *item;
		cJSON_ArrayForEach(item, evs) {
			if (!cJSON_IsObject(item) || r->n_events >= NR_MAX_EVENTS)
				continue;
			const cJSON *v = cJSON_GetObjectItemCaseSensitive(item, "ts");
			double ts = (v && cJSON_IsNumber(v)) ? v->valuedouble : 0.0;
			append_event(r, ts, json_str(item, "network"), json_str(item, "fingerprint"),
			             json_str(item, "kind"), json_str(item, "detail"));
		}
	}

	cJSON_Delete(root);
	return NR_OK;
}

static nr_peer *find_peer_mut(nr_registry *r, const char *network, const char *fp) {
	for (int i = 0; i < r->n_peers; i++) {
		if (strcmp(r->peers[i].network, network) == 0 && strcmp(r->peers[i].fingerprint, fp) == 0)
			return &r->peers[i];
	}
	return NULL;
}

int nr_registry_record(nr_registry *r, const char *network, const nr_obs *obs, int n_obs, double now) {
	bool changed = false;
	for (int i = 0; i < n_obs; i++) {
		/* Deduplicate by fingerprint (last observation wins) */
		bool dup_later = false;
		for (int k = i + 1; k < n_obs; k++) {
			if (strcmp(obs[k].fingerprint, obs[i].fingerprint) == 0) {
				dup_later = true;
				break;
			}
		}
		if (dup_later)
			continue;

		const nr_obs *o = &obs[i];
		nr_peer *p = find_peer_mut(r, network, o->fingerprint);
		if (!p) {
			if (r->n_peers >= NR_MAX_PEERS)
				continue;
			/* Save prev_fp by value because alloc_peer may realloc r->peers */
			char prev_fp_buf[128] = "";
			double prev_last = -1.0;
			for (int j = 0; j < r->n_peers; j++) {
				if (strcmp(r->peers[j].network, network) == 0 &&
				    strcmp(r->peers[j].name, o->name) == 0 &&
				    strcmp(r->peers[j].fingerprint, o->fingerprint) != 0 &&
				    r->peers[j].last_seen > prev_last) {
					copy_str(prev_fp_buf, sizeof(prev_fp_buf), r->peers[j].fingerprint);
					prev_last = r->peers[j].last_seen;
				}
			}
			p = alloc_peer(r);
			if (!p)
				continue;
			copy_str(p->network, sizeof(p->network), network);
			copy_str(p->fingerprint, sizeof(p->fingerprint), o->fingerprint);
			copy_str(p->name, sizeof(p->name), o->name);
			p->n_vpn_addrs = o->n_vpn_addrs;
			for (int j = 0; j < o->n_vpn_addrs; j++)
				copy_str(p->vpn_addrs[j], 64, o->vpn_addrs[j]);
			p->n_groups = o->n_groups;
			for (int j = 0; j < o->n_groups; j++)
				copy_str(p->groups[j], 64, o->groups[j]);
			copy_str(p->issuer, sizeof(p->issuer), o->issuer);
			copy_str(p->not_before, sizeof(p->not_before), o->not_before);
			copy_str(p->not_after, sizeof(p->not_after), o->not_after);
			p->first_seen = now;
			p->last_seen = now;
			if (o->has_underlay) {
				copy_str(p->last_underlay, sizeof(p->last_underlay), o->underlay);
				p->has_underlay = true;
			}
			p->relayed = o->relayed;
			p->online = true;

			append_event(r, now, network, o->fingerprint, "first_seen", o->name);
			if (prev_fp_buf[0]) {
				char detail[256];
				snprintf(detail, sizeof(detail), "replaces %s", prev_fp_buf);
				append_event(r, now, network, o->fingerprint, "cert_changed", detail);
			}
			append_event(r, now, network, o->fingerprint, "online", o->has_underlay ? o->underlay : NULL);
			changed = true;
		} else {
			if (p->is_archived) {
				p->is_archived = false;
				p->archived_at = 0;
				p->archived_by[0] = '\0';
				append_event(r, now, network, o->fingerprint, "restored", "reconnected");
				changed = true;
			}
			if (o->has_underlay && p->has_underlay && strcmp(o->underlay, p->last_underlay) != 0) {
				char detail[256];
				snprintf(detail, sizeof(detail), "%.120s -> %.120s", p->last_underlay, o->underlay);
				append_event(r, now, network, o->fingerprint, "address_changed", detail);
				changed = true;
			}
			if (o->has_underlay) {
				if (!p->has_underlay || strcmp(p->last_underlay, o->underlay) != 0)
					changed = true;
				copy_str(p->last_underlay, sizeof(p->last_underlay), o->underlay);
				p->has_underlay = true;
			}
			if (p->relayed != o->relayed) {
				p->relayed = o->relayed;
				changed = true;
			}
			p->last_seen = now;
			if (!p->online) {
				p->online = true;
				append_event(r, now, network, o->fingerprint, "online", o->has_underlay ? o->underlay : NULL);
				changed = true;
			}
		}
	}

	if (changed || (n_obs > 0 && now - r->last_saved >= NR_PERIODIC_FLUSH_SEC))
		return registry_save(r, now);
	return NR_OK;
}

int nr_registry_sweep(nr_registry *r, const char *network, double now) {
	bool changed = false;
	for (int i = 0; i < r->n_peers; i++) {
		nr_peer *p = &r->peers[i];
		if (strcmp(p->network, network) == 0 && p->online && (now - p->last_seen) > r->offline_after) {
			p->online = false;
			append_event(r, now, network, p->fingerprint, "offline", NULL);
			changed = true;
		}
	}
	return changed ? registry_save(r, now) : NR_OK;
}

int nr_registry_prune(nr_registry *r, double now, int retention_days) {
	double cutoff = now - (double)retention_days * 86400.0;
	int w = 0;
	bool dropped = false;
	for (int i = 0; i < r->n_events; i++) {
		if (r->events[i].ts >= cutoff) {
			if (w != i)
				r->events[w] = r->events[i];
			w++;
		} else {
			dropped = true;
		}
	}
	r->n_events = w;
	return dropped ? registry_save(r, now) : NR_OK;
}

int nr_registry_archive(nr_registry *r, const char *network, const char *fp, const char *by, double now) {
	nr_peer *p = find_peer_mut(r, network, fp);
	if (!p)
		return NR_ERR_NOTFOUND;
	if (p->online)
		return NR_ERR_ONLINE;
	if (!p->is_archived) {
		p->is_archived = true;
		p->archived_at = now;
		copy_str(p->archived_by, sizeof(p->archived_by), by);
		append_event(r, now, network, fp, "archived", by);
		return registry_save(r, now);
	}
	return NR_OK;
}

int nr_registry_restore(nr_registry *r, const char *network, const char *fp, const char *by, double now) {
	nr_peer *p = find_peer_mut(r, network, fp);
	if (!p)
		return NR_ERR_NOTFOUND;
	if (p->is_archived) {
		p->is_archived = false;
		p->archived_at = 0;
		p->archived_by[0] = '\0';
		append_event(r, now, network, fp, "restored", by);
		return registry_save(r, now);
	}
	return NR_OK;
}

/* ---- Visibility, Caller Lookup, Annotations ---- */

const nr_peer *nr_find_caller(const nr_registry *r, const char *network, const char *src_ip) {
	const nr_peer *best = NULL;
	for (int i = 0; i < r->n_peers; i++) {
		const nr_peer *p = &r->peers[i];
		if (strcmp(p->network, network) != 0)
			continue;
		bool match = false;
		for (int j = 0; j < p->n_vpn_addrs; j++) {
			char ip[64];
			if (nr_cidr_to_ip(p->vpn_addrs[j], ip, sizeof(ip)) && strcmp(ip, src_ip) == 0) {
				match = true;
				break;
			}
		}
		if (!match)
			continue;
		if (!best || (p->online && !best->online) ||
		    (p->online == best->online && p->last_seen >= best->last_seen))
			best = p;
	}
	return best;
}

static int cmp_peer_name_last(const void *a, const void *b) {
	const nr_peer *pa = *(const nr_peer *const *)a;
	const nr_peer *pb = *(const nr_peer *const *)b;
	int c = strcmp(pa->name, pb->name);
	if (c != 0)
		return c;
	if (pa->last_seen < pb->last_seen)
		return -1;
	if (pa->last_seen > pb->last_seen)
		return 1;
	return strcmp(pa->fingerprint, pb->fingerprint);
}

int nr_visible_peers(const nr_registry *r, const char *network, const nr_peer *caller, const nr_peer **out, int max_out) {
	int count = 0;
	for (int i = 0; i < r->n_peers && count < max_out; i++) {
		const nr_peer *p = &r->peers[i];
		if (strcmp(p->network, network) != 0)
			continue;
		bool vis = false;
		for (int a = 0; a < p->n_vpn_addrs && !vis; a++) {
			char ip[64];
			if (!nr_cidr_to_ip(p->vpn_addrs[a], ip, sizeof(ip)))
				continue;
			for (int c = 0; c < caller->n_vpn_addrs; c++) {
				if (nr_ip_in_cidr(ip, caller->vpn_addrs[c])) {
					vis = true;
					break;
				}
			}
		}
		if (vis)
			out[count++] = p;
	}
	qsort(out, (size_t)count, sizeof(out[0]), cmp_peer_name_last);
	return count;
}

static int cmp_shares(const void *a, const void *b) {
	const nr_addr_share *sa = a;
	const nr_addr_share *sb = b;
	int c = strcmp(sa->address, sb->address);
	return c != 0 ? c : strcmp(sa->name, sb->name);
}

void nr_annotate(const nr_peer *const *peers, int n_peers, nr_annotated *out) {
	for (int i = 0; i < n_peers; i++) {
		const nr_peer *p = peers[i];
		nr_annotated *a = &out[i];
		memset(a, 0, sizeof(*a));
		a->peer = p;

		const nr_peer *newest = p;
		for (int j = 0; j < n_peers; j++) {
			const nr_peer *o = peers[j];
			if (strcmp(o->name, p->name) == 0) {
				if (o->first_seen > newest->first_seen)
					newest = o;
				if (p->online && o->online && strcmp(o->fingerprint, p->fingerprint) != 0 && a->n_duplicates < 16)
					copy_str(a->duplicates[a->n_duplicates++], 128, o->fingerprint);
			}
		}
		if (newest->first_seen > p->first_seen)
			copy_str(a->superseded_by, sizeof(a->superseded_by), newest->fingerprint);

		if (!p->is_archived) {
			for (int k = 0; k < p->n_vpn_addrs; k++) {
				char ip1[64];
				if (!nr_cidr_to_ip(p->vpn_addrs[k], ip1, sizeof(ip1)))
					continue;
				for (int j = 0; j < n_peers; j++) {
					const nr_peer *o = peers[j];
					if (o->is_archived || strcmp(o->name, p->name) == 0)
						continue;
					for (int m = 0; m < o->n_vpn_addrs; m++) {
						char ip2[64];
						if (nr_cidr_to_ip(o->vpn_addrs[m], ip2, sizeof(ip2)) && strcmp(ip1, ip2) == 0) {
							bool seen = false;
							for (int s = 0; s < a->n_shares; s++) {
								if (strcmp(a->shares[s].address, ip1) == 0 && strcmp(a->shares[s].name, o->name) == 0) {
									seen = true;
									break;
								}
							}
							if (!seen && a->n_shares < 16) {
								copy_str(a->shares[a->n_shares].address, 64, ip1);
								copy_str(a->shares[a->n_shares].name, 128, o->name);
								a->n_shares++;
							}
						}
					}
				}
			}
			if (a->n_shares > 1)
				qsort(a->shares, (size_t)a->n_shares, sizeof(a->shares[0]), cmp_shares);
		}
	}
}

bool nr_can_manage(const nr_peer *caller, const char admin_groups[][64], int n_admin_groups) {
	if (!caller || !caller->online || n_admin_groups <= 0)
		return false;
	for (int i = 0; i < caller->n_groups; i++) {
		for (int j = 0; j < n_admin_groups; j++) {
			if (strcmp(caller->groups[i], admin_groups[j]) == 0)
				return true;
		}
	}
	return false;
}

bool nr_same_origin(const char *origin, const char *host) {
	if (!origin || !host || !origin[0] || !host[0])
		return false;
	char expected[320];
	snprintf(expected, sizeof(expected), "https://%s", host);
	return strcasecmp(origin, expected) == 0;
}

/* ---- JSON & HTML Rendering ---- */

void nr_render_peers_json(const char *network, const nr_peer *caller, const nr_annotated *peers, int n_peers, nr_buf *out) {
	cJSON *root = cJSON_CreateObject();
	cJSON_AddStringToObject(root, "network", network);
	cJSON_AddStringToObject(root, "caller", caller->name);
	cJSON *arr = cJSON_CreateArray();
	for (int i = 0; i < n_peers; i++) {
		const nr_annotated *a = &peers[i];
		const nr_peer *p = a->peer;
		cJSON *o = cJSON_CreateObject();
		cJSON_AddStringToObject(o, "fingerprint", p->fingerprint);
		cJSON_AddStringToObject(o, "name", p->name);
		cJSON *addrs = cJSON_CreateArray();
		for (int j = 0; j < p->n_vpn_addrs; j++)
			cJSON_AddItemToArray(addrs, cJSON_CreateString(p->vpn_addrs[j]));
		cJSON_AddItemToObject(o, "vpn_addrs", addrs);
		cJSON *grps = cJSON_CreateArray();
		for (int j = 0; j < p->n_groups; j++)
			cJSON_AddItemToArray(grps, cJSON_CreateString(p->groups[j]));
		cJSON_AddItemToObject(o, "groups", grps);
		cJSON_AddStringToObject(o, "issuer", p->issuer);
		if (p->not_before[0]) cJSON_AddStringToObject(o, "not_before", p->not_before);
		else cJSON_AddNullToObject(o, "not_before");
		if (p->not_after[0]) cJSON_AddStringToObject(o, "not_after", p->not_after);
		else cJSON_AddNullToObject(o, "not_after");
		cJSON_AddNumberToObject(o, "first_seen", p->first_seen);
		cJSON_AddNumberToObject(o, "last_seen", p->last_seen);
		if (p->has_underlay) cJSON_AddStringToObject(o, "last_underlay", p->last_underlay);
		else cJSON_AddNullToObject(o, "last_underlay");
		cJSON_AddBoolToObject(o, "relayed", p->relayed);
		cJSON_AddBoolToObject(o, "online", p->online);
		if (p->is_archived) {
			cJSON_AddNumberToObject(o, "archived_at", p->archived_at);
			cJSON_AddStringToObject(o, "archived_by", p->archived_by);
		} else {
			cJSON_AddNullToObject(o, "archived_at");
			cJSON_AddNullToObject(o, "archived_by");
		}
		if (a->superseded_by[0]) cJSON_AddStringToObject(o, "superseded_by", a->superseded_by);
		else cJSON_AddNullToObject(o, "superseded_by");
		cJSON *dups = cJSON_CreateArray();
		for (int j = 0; j < a->n_duplicates; j++)
			cJSON_AddItemToArray(dups, cJSON_CreateString(a->duplicates[j]));
		cJSON_AddItemToObject(o, "duplicates", dups);
		cJSON *shs = cJSON_CreateArray();
		for (int j = 0; j < a->n_shares; j++) {
			cJSON *sh = cJSON_CreateObject();
			cJSON_AddStringToObject(sh, "address", a->shares[j].address);
			cJSON_AddStringToObject(sh, "name", a->shares[j].name);
			cJSON_AddItemToArray(shs, sh);
		}
		cJSON_AddItemToObject(o, "shares_address", shs);
		cJSON_AddItemToArray(arr, o);
	}
	cJSON_AddItemToObject(root, "peers", arr);
	char *s = cJSON_Print(root);
	cJSON_Delete(root);
	if (s) {
		nr_buf_append(out, s);
		nr_buf_append(out, "\n");
		free(s);
	}
}

static void format_utc(double ts, char *buf, size_t sz) {
	time_t t = (time_t)ts;
	struct tm tm;
	gmtime_r(&t, &tm);
	strftime(buf, sz, "%Y-%m-%d %H:%M:%S UTC", &tm);
}

static void format_date_utc(double ts, char *buf, size_t sz) {
	time_t t = (time_t)ts;
	struct tm tm;
	gmtime_r(&t, &tm);
	strftime(buf, sz, "%Y-%m-%d", &tm);
}

static void format_ago(double secs_f, char *buf, size_t sz) {
	long long s = (long long)secs_f;
	if (s < 0) s = 0;
	if (s < 5) { snprintf(buf, sz, "just now"); return; }
	if (s >= 86400) { snprintf(buf, sz, "%lld d ago", s / 86400); return; }
	if (s >= 3600) { snprintf(buf, sz, "%lld h ago", s / 3600); return; }
	if (s >= 60) { snprintf(buf, sz, "%lld m ago", s / 60); return; }
	snprintf(buf, sz, "%lld s ago", s);
}

static bool parse_iso8601_utc(const char *s, double *out_ts) {
	if (!s || !s[0])
		return false;
	int y, mo, d, h, mi, se;
	int tz_h = 0, tz_m = 0;
	char tz_sign = 0;
	if (sscanf(s, "%d-%d-%dT%d:%d:%d", &y, &mo, &d, &h, &mi, &se) != 6)
		return false;
	const char *tail = strchr(s, 'T');
	if (tail) {
		const char *p = tail + 1;
		while (*p && *p != 'Z' && *p != '+' && *p != '-') p++;
		if (*p == '+' || *p == '-') {
			tz_sign = *p;
			sscanf(p + 1, "%d:%d", &tz_h, &tz_m);
		}
	}
	/* Howard Hinnant days-from-civil algorithm (pure UTC, no TZ env mutation) */
	long long yr = y - (mo <= 2 ? 1 : 0);
	long long era = (yr >= 0 ? yr : yr - 399) / 400;
	long long yoe = yr - era * 400;
	long long doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
	long long doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
	long long days = era * 146097 + doe - 719468;
	long long ts = days * 86400LL + h * 3600LL + mi * 60LL + se;
	long long off = tz_h * 3600LL + tz_m * 60LL;
	if (tz_sign == '+') ts -= off;
	else if (tz_sign == '-') ts += off;
	*out_ts = (double)ts;
	return true;
}

static int cmp_annotated_display(const void *a, const void *b) {
	const nr_annotated *aa = *(const nr_annotated *const *)a;
	const nr_annotated *ab = *(const nr_annotated *const *)b;
	if (aa->peer->online != ab->peer->online)
		return aa->peer->online ? -1 : 1;
	return strcmp(aa->peer->name, ab->peer->name);
}

static void short_fp(const char *fp, char out[13]) {
	snprintf(out, 13, "%.12s", fp ? fp : "");
}

typedef struct {
	int online;
	int total;
	int relayed;
	int archived;
	char rendered[32];
	nr_buf rows;
} status_parts;

static void build_status_parts(const nr_peer *caller, const nr_annotated *peers, int n_peers, double now, bool manage, status_parts *st) {
	memset(st, 0, sizeof(*st));
	nr_buf_init(&st->rows, 4096);
	format_utc(now, st->rendered, sizeof(st->rendered));

	const nr_annotated *ordered[NR_MAX_PEERS];
	int n = n_peers > NR_MAX_PEERS ? NR_MAX_PEERS : n_peers;
	for (int i = 0; i < n; i++)
		ordered[i] = &peers[i];
	qsort(ordered, (size_t)n, sizeof(ordered[0]), cmp_annotated_display);

	for (int i = 0; i < n; i++) {
		const nr_annotated *a = ordered[i];
		const nr_peer *p = a->peer;
		const char *state = p->is_archived ? "archived" : (p->online ? "online" : "offline");
		if (p->is_archived) {
			st->archived++;
		} else {
			st->total++;
			if (p->online) {
				st->online++;
				if (p->relayed)
					st->relayed++;
			}
		}

		char sfp[13];
		short_fp(p->fingerprint, sfp);

		if (i > 0)
			nr_buf_append(&st->rows, "\n");
		nr_buf_appendf(&st->rows, "<tr class=\"%s\" data-key=\"", state);
		nr_buf_append_html(&st->rows, p->fingerprint);
		nr_buf_append(&st->rows, "\">");

		/* Col 0: Name */
		nr_buf_append(&st->rows, "<td data-sort=\"");
		nr_buf_append_html(&st->rows, p->name);
		nr_buf_append(&st->rows, "\" data-label=\"Name\" class=\"c-name \"><div class=\"who\"><span class=\"name\">");
		nr_buf_append_html(&st->rows, p->name);
		nr_buf_append(&st->rows, "</span>");
		if (strcmp(p->fingerprint, caller->fingerprint) == 0)
			nr_buf_append(&st->rows, "<span class=\"you\">you</span>");
		nr_buf_append(&st->rows, "</div><div class=\"meta\"><span class=\"fp\" title=\"");
		nr_buf_append_html(&st->rows, p->fingerprint);
		nr_buf_append(&st->rows, "\">");
		nr_buf_append_html(&st->rows, sfp);
		nr_buf_append(&st->rows, "</span>");
		for (int g = 0; g < p->n_groups; g++) {
			nr_buf_append(&st->rows, "<span class=\"tag\">");
			nr_buf_append_html(&st->rows, p->groups[g]);
			nr_buf_append(&st->rows, "</span>");
		}
		nr_buf_append(&st->rows, "</div>");
		if (a->n_duplicates > 0 || a->superseded_by[0] || a->n_shares > 0) {
			nr_buf_append(&st->rows, "<div class=\"flags\">");
			if (a->n_duplicates > 0) {
				nr_buf_append(&st->rows, "<span class=\"flag dup\" title=\"Another certificate named ");
				nr_buf_append_html(&st->rows, p->name);
				nr_buf_append(&st->rows, " is online at the same time\">duplicate · ");
				for (int d = 0; d < a->n_duplicates; d++) {
					char dfp[13];
					short_fp(a->duplicates[d], dfp);
					if (d > 0) nr_buf_append(&st->rows, ", ");
					nr_buf_append_html(&st->rows, dfp);
				}
				nr_buf_append(&st->rows, " online too</span>");
			}
			if (a->superseded_by[0]) {
				char supfp[13];
				short_fp(a->superseded_by, supfp);
				nr_buf_append(&st->rows, "<span class=\"flag old\" title=\"A newer certificate ");
				nr_buf_append_html(&st->rows, a->superseded_by);
				nr_buf_append(&st->rows, " carries this name\">superseded by ");
				nr_buf_append_html(&st->rows, supfp);
				nr_buf_append(&st->rows, "</span>");
			}
			for (int s = 0; s < a->n_shares; s++) {
				nr_buf_append(&st->rows, "<span class=\"flag addr\" title=\"Another unarchived certificate holds this overlay address\">shares ");
				nr_buf_append_html(&st->rows, a->shares[s].address);
				nr_buf_append(&st->rows, " with ");
				nr_buf_append_html(&st->rows, a->shares[s].name);
				nr_buf_append(&st->rows, "</span>");
			}
			nr_buf_append(&st->rows, "</div>");
		}
		nr_buf_append(&st->rows, "</td>");

		/* Col 1: Overlay IP */
		unsigned long ip_key = 0;
		char first_ip[64] = "";
		if (p->n_vpn_addrs > 0 && nr_cidr_to_ip(p->vpn_addrs[0], first_ip, sizeof(first_ip))) {
			struct in_addr a4;
			if (inet_pton(AF_INET, first_ip, &a4) == 1)
				ip_key = (unsigned long)ntohl(a4.s_addr);
		}
		nr_buf_appendf(&st->rows, "<td data-sort=\"%lu\" data-label=\"Overlay IP\" class=\"c-ip mono\">", ip_key);
		for (int k = 0; k < p->n_vpn_addrs; k++) {
			char ip[64];
			if (nr_cidr_to_ip(p->vpn_addrs[k], ip, sizeof(ip))) {
				if (k > 0) nr_buf_append(&st->rows, ", ");
				nr_buf_append_html(&st->rows, ip);
			}
		}
		nr_buf_append(&st->rows, "</td>");

		/* Col 2: Status */
		const char *state_sort = p->is_archived ? "-1" : (p->online ? "1" : "0");
		nr_buf_appendf(&st->rows, "<td data-sort=\"%s\" data-label=\"Status\" class=\"c-state \">", state_sort);
		if (p->is_archived) {
			char at_utc[32], at_date[16];
			format_utc(p->archived_at, at_utc, sizeof(at_utc));
			format_date_utc(p->archived_at, at_date, sizeof(at_date));
			const char *by = p->archived_by[0] ? p->archived_by : "unknown";
			char by_short[192];
			copy_str(by_short, sizeof(by_short), by);
			char *paren = strstr(by_short, " (");
			if (paren) *paren = '\0';
			nr_buf_appendf(&st->rows, "<span class=\"pill archived\" title=\"Archived %s by ", at_utc);
			nr_buf_append_html(&st->rows, by);
			nr_buf_appendf(&st->rows, "\">archived</span><span class=\"sub\">%s · ", at_date);
			nr_buf_append_html(&st->rows, by_short);
			nr_buf_append(&st->rows, "</span>");
		} else {
			nr_buf_appendf(&st->rows, "<span class=\"status\"><span class=\"pill %s\"><span class=\"dot\"></span>%s</span>", state, state);
			if (p->online && p->relayed)
				nr_buf_append(&st->rows, "<span class=\"pill relayed\" title=\"Traffic reaches this peer through a relay\">relayed</span>");
			nr_buf_append(&st->rows, "</span>");
		}
		nr_buf_append(&st->rows, "</td>");

		/* Col 3: Last seen */
		char ls_utc[32], ls_ago[32];
		format_utc(p->last_seen, ls_utc, sizeof(ls_utc));
		format_ago(now - p->last_seen, ls_ago, sizeof(ls_ago));
		nr_buf_appendf(&st->rows, "<td data-sort=\"%.0f\" data-label=\"Last seen\" class=\"c-last \"><span title=\"%s\">%s</span></td>",
		               p->last_seen, ls_utc, ls_ago);

		/* Col 4: First seen */
		char fs_utc[32], fs_date[16];
		format_utc(p->first_seen, fs_utc, sizeof(fs_utc));
		format_date_utc(p->first_seen, fs_date, sizeof(fs_date));
		nr_buf_appendf(&st->rows, "<td data-sort=\"%.0f\" data-label=\"First seen\" class=\"c-first \"><span title=\"%s\">%s</span></td>",
		               p->first_seen, fs_utc, fs_date);

		/* Col 5: Underlay */
		nr_buf_append(&st->rows, "<td data-sort=\"");
		if (p->has_underlay) nr_buf_append_html(&st->rows, p->last_underlay);
		nr_buf_append(&st->rows, "\" data-label=\"Underlay\" class=\"c-underlay mono\">");
		if (p->has_underlay) nr_buf_append_html(&st->rows, p->last_underlay);
		else nr_buf_append(&st->rows, "—");
		nr_buf_append(&st->rows, "</td>");

		/* Col 6: Cert expires */
		double exp_ts = 0;
		const char *exp_cls = "";
		char exp_date[16];
		if (parse_iso8601_utc(p->not_after, &exp_ts)) {
			long long days = (long long)((exp_ts - now) / 86400.0);
			if (exp_ts < now && (double)(days * 86400LL) > (exp_ts - now))
				days--;
			if (days < 7) exp_cls = "bad";
			else if (days < 30) exp_cls = "warn";
			format_date_utc(exp_ts, exp_date, sizeof(exp_date));
			nr_buf_appendf(&st->rows, "<td data-sort=\"%.0f\" data-label=\"Cert expires\" class=\"c-cert %s\">%s <small>%lld d</small></td>",
			               exp_ts, exp_cls, exp_date, days);
		} else {
			nr_buf_append(&st->rows, "<td data-sort=\"0\" data-label=\"Cert expires\" class=\"c-cert \">");
			if (p->not_after[0]) nr_buf_append_html(&st->rows, p->not_after);
			else nr_buf_append(&st->rows, "—");
			nr_buf_append(&st->rows, "</td>");
		}

		/* Col 7: Actions (if manage) */
		if (manage) {
			const char *action = p->is_archived ? "restore" : (p->online ? NULL : "archive");
			const char *label = p->is_archived ? "Restore" : "Archive";
			nr_buf_append(&st->rows, "<td class=\"c-actions\">");
			if (action) {
				nr_buf_appendf(&st->rows, "<button type=\"button\" class=\"action %s\" data-action=\"%s\" data-fingerprint=\"", action, action);
				nr_buf_append_html(&st->rows, p->fingerprint);
				nr_buf_append(&st->rows, "\" data-name=\"");
				nr_buf_append_html(&st->rows, p->name);
				nr_buf_appendf(&st->rows, "\">%s</button>", label);
			}
			nr_buf_append(&st->rows, "</td>");
		}

		nr_buf_append(&st->rows, "</tr>");
	}
}

void nr_render_status_json(const nr_peer *caller, const nr_annotated *peers, int n_peers, double now, bool manage, nr_buf *out) {
	status_parts st;
	build_status_parts(caller, peers, n_peers, now, manage, &st);
	cJSON *root = cJSON_CreateObject();
	cJSON_AddNumberToObject(root, "online", st.online);
	cJSON_AddNumberToObject(root, "total", st.total);
	cJSON_AddNumberToObject(root, "relayed", st.relayed);
	cJSON_AddNumberToObject(root, "archived", st.archived);
	cJSON_AddStringToObject(root, "rendered", st.rendered);
	cJSON_AddStringToObject(root, "rows", st.rows.data ? st.rows.data : "");
	char *s = cJSON_PrintUnformatted(root);
	cJSON_Delete(root);
	nr_buf_free(&st.rows);
	if (s) {
		nr_buf_append(out, s);
		nr_buf_append(out, "\n");
		free(s);
	}
}

static void append_replaced(nr_buf *out, const char *tpl, const char *const keys[], const char *const vals[], int n_kv) {
	const char *p = tpl;
	while (*p) {
		if (*p == '@') {
			bool matched = false;
			for (int i = 0; i < n_kv; i++) {
				size_t klen = strlen(keys[i]);
				if (strncmp(p, keys[i], klen) == 0) {
					nr_buf_append(out, vals[i]);
					p += klen;
					matched = true;
					break;
				}
			}
			if (matched)
				continue;
		}
		nr_buf_append_n(out, p, 1);
		p++;
	}
}

void nr_render_html(const char *network, const nr_peer *caller, const nr_annotated *peers, int n_peers, double now, bool manage, nr_buf *out) {
	status_parts st;
	build_status_parts(caller, peers, n_peers, now, manage, &st);

	nr_buf net_esc, caller_esc, nets_esc;
	nr_buf_init(&net_esc, 64);
	nr_buf_init(&caller_esc, 64);
	nr_buf_init(&nets_esc, 128);
	nr_buf_append_html(&net_esc, network);
	nr_buf_append_html(&caller_esc, caller->name);
	for (int i = 0; i < caller->n_vpn_addrs; i++) {
		if (i > 0) nr_buf_append(&nets_esc, ", ");
		nr_buf_append_html(&nets_esc, caller->vpn_addrs[i]);
	}

	char online_s[16], total_s[16], relayed_s[16], archived_s[16];
	snprintf(online_s, sizeof(online_s), "%d", st.online);
	snprintf(total_s, sizeof(total_s), "%d", st.total);
	snprintf(relayed_s, sizeof(relayed_s), "%d", st.relayed);
	snprintf(archived_s, sizeof(archived_s), "%d", st.archived);

	const char *keys[] = {
		"@NETWORK@", "@CALLER@", "@CALLER_NETS@",
		"@ONLINE@", "@TOTAL@", "@RELAYED@", "@ARCHIVED@",
		"@ACTIONS_HEADER@", "@RENDERED@", "@ROWS@"
	};
	const char *vals[] = {
		net_esc.data, caller_esc.data, nets_esc.data,
		online_s, total_s, relayed_s, archived_s,
		manage ? "<th class=\"c-actions\"><span class=\"sr-only\">Actions</span></th>" : "",
		st.rendered, st.rows.data ? st.rows.data : ""
	};
	append_replaced(out, (const char *)NR_PAGE_HTML, keys, vals, 10);

	nr_buf_free(&net_esc);
	nr_buf_free(&caller_esc);
	nr_buf_free(&nets_esc);
	nr_buf_free(&st.rows);
}
