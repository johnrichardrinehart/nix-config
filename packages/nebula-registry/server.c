#define _GNU_SOURCE

#include "registry.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#include <cjson/cJSON.h>
#include <mbedtls/base64.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/ecp.h>
#include <mbedtls/entropy.h>
#include <mbedtls/error.h>
#include <mbedtls/pk.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <psa/crypto.h>

#ifndef IP_FREEBIND
#define IP_FREEBIND 15
#endif
#ifndef SO_BINDTODEVICE
#define SO_BINDTODEVICE 25
#endif

static volatile sig_atomic_t g_stop = 0;

static void on_signal(int sig) {
	(void)sig;
	g_stop = 1;
}

static double now_epoch(void) {
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static double now_mono(void) {
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

/* ---- TLS Server (mbedtls 3.6 with preloaded SNI certs) ---- */

typedef struct {
	char host[256];
	mbedtls_x509_crt crt;
	mbedtls_pk_context key;
} nr_sni_cert;

struct nr_tls_server {
	mbedtls_entropy_context entropy;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_ssl_config conf;
	mbedtls_ssl_context ssl;
	mbedtls_x509_crt default_crt;
	mbedtls_pk_context default_key;
	nr_sni_cert extras[NR_MAX_EXTRA_CERTS];
	int n_extras;
};

static void norm_host(const char *in, char *out, size_t sz) {
	size_t i = 0;
	for (; in && in[i] && i + 1 < sz; i++)
		out[i] = (char)tolower((unsigned char)in[i]);
	while (i > 0 && out[i - 1] == '.')
		i--;
	out[i] = '\0';
}

static int sni_callback(void *p_info, mbedtls_ssl_context *ssl, const unsigned char *name, size_t name_len) {
	nr_tls_server *s = p_info;
	if (!name || name_len == 0 || name_len >= 256)
		return 0;
	char host[256];
	memcpy(host, name, name_len);
	host[name_len] = '\0';
	norm_host(host, host, sizeof(host));

	for (int i = 0; i < s->n_extras; i++) {
		if (strcmp(s->extras[i].host, host) == 0)
			return mbedtls_ssl_set_hs_own_cert(ssl, &s->extras[i].crt, &s->extras[i].key);
	}
	return 0;
}

static void log_mbedtls_err(const char *what, int rc) {
	char msg[128];
	mbedtls_strerror(rc, msg, sizeof(msg));
	fprintf(stderr, "nebula-registry: %s: %s (-0x%04x)\n", what, msg, (unsigned)(-rc));
}

nr_tls_server *nr_tls_server_new(const nr_tls_config *cfg) {
	if (!cfg || !cfg->cert_file[0] || !cfg->key_file[0])
		return NULL;
	(void)psa_crypto_init();

	nr_tls_server *s = calloc(1, sizeof(*s));
	if (!s)
		return NULL;

	mbedtls_entropy_init(&s->entropy);
	mbedtls_ctr_drbg_init(&s->drbg);
	mbedtls_ssl_config_init(&s->conf);
	mbedtls_ssl_init(&s->ssl);
	mbedtls_x509_crt_init(&s->default_crt);
	mbedtls_pk_init(&s->default_key);

	const char *pers = "nebula-registry";
	int rc = mbedtls_ctr_drbg_seed(&s->drbg, mbedtls_entropy_func, &s->entropy,
	                               (const unsigned char *)pers, strlen(pers));
	if (rc != 0) {
		log_mbedtls_err("ctr_drbg_seed", rc);
		goto fail;
	}

	rc = mbedtls_x509_crt_parse_file(&s->default_crt, cfg->cert_file);
	if (rc != 0) {
		log_mbedtls_err(cfg->cert_file, rc);
		goto fail;
	}
	rc = mbedtls_pk_parse_keyfile(&s->default_key, cfg->key_file, NULL,
	                              mbedtls_ctr_drbg_random, &s->drbg);
	if (rc != 0) {
		log_mbedtls_err(cfg->key_file, rc);
		goto fail;
	}

	for (int i = 0; i < cfg->n_extras && i < NR_MAX_EXTRA_CERTS; i++) {
		nr_sni_cert *e = &s->extras[s->n_extras];
		mbedtls_x509_crt_init(&e->crt);
		mbedtls_pk_init(&e->key);
		s->n_extras++;
		norm_host(cfg->extras[i].host, e->host, sizeof(e->host));
		rc = mbedtls_x509_crt_parse_file(&e->crt, cfg->extras[i].cert_file);
		if (rc != 0) {
			log_mbedtls_err(cfg->extras[i].cert_file, rc);
			goto fail;
		}
		rc = mbedtls_pk_parse_keyfile(&e->key, cfg->extras[i].key_file, NULL,
		                              mbedtls_ctr_drbg_random, &s->drbg);
		if (rc != 0) {
			log_mbedtls_err(cfg->extras[i].key_file, rc);
			goto fail;
		}
	}

	rc = mbedtls_ssl_config_defaults(&s->conf, MBEDTLS_SSL_IS_SERVER,
	                                 MBEDTLS_SSL_TRANSPORT_STREAM,
	                                 MBEDTLS_SSL_PRESET_DEFAULT);
	if (rc != 0) {
		log_mbedtls_err("ssl_config_defaults", rc);
		goto fail;
	}
	mbedtls_ssl_conf_min_tls_version(&s->conf, MBEDTLS_SSL_VERSION_TLS1_2);
	mbedtls_ssl_conf_rng(&s->conf, mbedtls_ctr_drbg_random, &s->drbg);
	rc = mbedtls_ssl_conf_own_cert(&s->conf, &s->default_crt, &s->default_key);
	if (rc != 0) {
		log_mbedtls_err("ssl_conf_own_cert", rc);
		goto fail;
	}
	if (s->n_extras > 0)
		mbedtls_ssl_conf_sni(&s->conf, sni_callback, s);

	rc = mbedtls_ssl_setup(&s->ssl, &s->conf);
	if (rc != 0) {
		log_mbedtls_err("ssl_setup", rc);
		goto fail;
	}
	return s;

fail:
	nr_tls_server_free(s);
	return NULL;
}

void nr_tls_server_free(nr_tls_server *s) {
	if (!s)
		return;
	for (int i = 0; i < s->n_extras; i++) {
		mbedtls_x509_crt_free(&s->extras[i].crt);
		mbedtls_pk_free(&s->extras[i].key);
	}
	mbedtls_ssl_free(&s->ssl);
	mbedtls_ssl_config_free(&s->conf);
	mbedtls_x509_crt_free(&s->default_crt);
	mbedtls_pk_free(&s->default_key);
	mbedtls_ctr_drbg_free(&s->drbg);
	mbedtls_entropy_free(&s->entropy);
	free(s);
}

static int bio_send(void *ctx, const unsigned char *buf, size_t len) {
	int fd = *(int *)ctx;
	ssize_t n = send(fd, buf, len, MSG_NOSIGNAL);
	if (n < 0) {
		if (errno == EINTR)
			return MBEDTLS_ERR_SSL_WANT_WRITE;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return MBEDTLS_ERR_SSL_TIMEOUT;
		return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
	}
	return (int)n;
}

static int bio_recv(void *ctx, unsigned char *buf, size_t len) {
	int fd = *(int *)ctx;
	ssize_t n = recv(fd, buf, len, 0);
	if (n < 0) {
		if (errno == EINTR)
			return MBEDTLS_ERR_SSL_WANT_READ;
		if (errno == EAGAIN || errno == EWOULDBLOCK)
			return MBEDTLS_ERR_SSL_TIMEOUT;
		return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
	}
	return (int)n;
}

/* ---- HTTP/1.1 Handler ---- */

static void http_response(nr_buf *out, int status, const char *reason, const char *ctype, const char *body, size_t body_len, bool head_only) {
	nr_buf_appendf(out,
	               "HTTP/1.1 %d %s\r\n"
	               "Content-Type: %s\r\n"
	               "Content-Length: %zu\r\n"
	               "Cache-Control: no-store\r\n"
	               "X-Content-Type-Options: nosniff\r\n"
	               "Connection: close\r\n"
	               "\r\n",
	               status, reason, ctype, body_len);
	if (!head_only && body && body_len > 0)
		nr_buf_append_n(out, body, body_len);
}

static void http_json_err(nr_buf *out, int status, const char *reason, const char *msg) {
	char body[256];
	int n = snprintf(body, sizeof(body), "{\"error\":\"%s\"}\n", msg);
	http_response(out, status, reason, "application/json", body, n > 0 ? (size_t)n : 0, false);
}

int nr_handle_http_request(const char *raw_req, size_t raw_len, const char *src_ip, const char *network,
                           nr_registry *reg, const char admin_groups[][64], int n_admin_groups,
                           double now, nr_buf *resp_out) {
	/* Find end of HTTP headers */
	const char *hdr_end = NULL;
	for (size_t i = 0; i + 3 < raw_len; i++) {
		if (raw_req[i] == '\r' && raw_req[i + 1] == '\n' && raw_req[i + 2] == '\r' && raw_req[i + 3] == '\n') {
			hdr_end = raw_req + i;
			break;
		}
	}
	if (!hdr_end) {
		http_response(resp_out, 400, "Bad Request", "text/plain; charset=utf-8", "bad request\n", 12, false);
		return 400;
	}

	/* Parse request line */
	const char *line_end = memchr(raw_req, '\n', (size_t)(hdr_end - raw_req));
	size_t line_len = line_end ? (size_t)(line_end - raw_req) : (size_t)(hdr_end - raw_req);
	if (line_len > 0 && raw_req[line_len - 1] == '\r')
		line_len--;
	char req_line[512];
	if (line_len >= sizeof(req_line))
		line_len = sizeof(req_line) - 1;
	memcpy(req_line, raw_req, line_len);
	req_line[line_len] = '\0';

	char method[16] = "", target[384] = "";
	if (sscanf(req_line, "%15s %383s", method, target) != 2) {
		http_response(resp_out, 400, "Bad Request", "text/plain; charset=utf-8", "bad request\n", 12, false);
		return 400;
	}
	char *qmark = strchr(target, '?');
	if (qmark)
		*qmark = '\0';

	/* Parse relevant headers */
	char host[256] = "", origin[320] = "";
	long content_length = -1;
	const char *p = line_end ? line_end + 1 : hdr_end;
	while (p < hdr_end) {
		const char *nl = memchr(p, '\n', (size_t)(hdr_end - p));
		size_t ll = nl ? (size_t)(nl - p) : (size_t)(hdr_end - p);
		if (ll > 0 && p[ll - 1] == '\r')
			ll--;
		const char *colon = memchr(p, ':', ll);
		if (colon) {
			size_t klen = (size_t)(colon - p);
			const char *val = colon + 1;
			size_t vlen = ll - klen - 1;
			while (vlen > 0 && (*val == ' ' || *val == '\t')) { val++; vlen--; }
			while (vlen > 0 && (val[vlen - 1] == ' ' || val[vlen - 1] == '\t')) vlen--;
			if (klen == 4 && strncasecmp(p, "host", 4) == 0 && vlen < sizeof(host)) {
				memcpy(host, val, vlen);
				host[vlen] = '\0';
			} else if (klen == 6 && strncasecmp(p, "origin", 6) == 0 && vlen < sizeof(origin)) {
				memcpy(origin, val, vlen);
				origin[vlen] = '\0';
			} else if (klen == 14 && strncasecmp(p, "content-length", 14) == 0) {
				char clbuf[32];
				size_t cll = vlen < sizeof(clbuf) - 1 ? vlen : sizeof(clbuf) - 1;
				memcpy(clbuf, val, cll);
				clbuf[cll] = '\0';
				content_length = strtol(clbuf, NULL, 10);
			}
		}
		if (!nl) break;
		p = nl + 1;
	}

	const char *body = hdr_end + 4;
	size_t body_avail = raw_len - (size_t)(body - raw_req);

	bool is_get = strcmp(method, "GET") == 0;
	bool is_head = strcmp(method, "HEAD") == 0;
	bool is_post = strcmp(method, "POST") == 0;
	if (!is_get && !is_head && !is_post) {
		http_response(resp_out, 405, "Method Not Allowed", "text/plain; charset=utf-8", "method not allowed\n", 19, false);
		return 405;
	}

	const nr_peer *caller = nr_find_caller(reg, network, src_ip);
	if (!caller) {
		http_response(resp_out, 403, "Forbidden", "text/plain; charset=utf-8", "caller is not a known peer\n", 27, is_head);
		return 403;
	}

	const nr_peer *vis[NR_MAX_PEERS];
	int n_vis = nr_visible_peers(reg, network, caller, vis, NR_MAX_PEERS);
	nr_annotated *ann = n_vis > 0 ? calloc((size_t)n_vis, sizeof(nr_annotated)) : NULL;
	if (n_vis > 0 && !ann) {
		http_response(resp_out, 500, "Internal Server Error", "text/plain; charset=utf-8", "out of memory\n", 14, is_head);
		return 500;
	}
	if (n_vis > 0)
		nr_annotate(vis, n_vis, ann);
	bool manage = nr_can_manage(caller, admin_groups, n_admin_groups);

	int status = 200;
	if (is_get || is_head) {
		nr_buf out;
		nr_buf_init(&out, 4096);
		if (strcmp(target, "/") == 0) {
			nr_render_html(network, caller, ann, n_vis, now, manage, &out);
			http_response(resp_out, 200, "OK", "text/html; charset=utf-8", out.data, out.len, is_head);
		} else if (strcmp(target, "/api/peers") == 0) {
			nr_render_peers_json(network, caller, ann, n_vis, &out);
			http_response(resp_out, 200, "OK", "application/json", out.data, out.len, is_head);
		} else if (strcmp(target, "/api/status") == 0) {
			nr_render_status_json(caller, ann, n_vis, now, manage, &out);
			http_response(resp_out, 200, "OK", "application/json", out.data, out.len, is_head);
		} else {
			status = 404;
			http_response(resp_out, 404, "Not Found", "text/plain; charset=utf-8", "not found\n", 10, is_head);
		}
		nr_buf_free(&out);
	} else if (is_post && (strcmp(target, "/api/archive") == 0 || strcmp(target, "/api/restore") == 0)) {
		bool is_archive = strcmp(target, "/api/archive") == 0;
		if (!manage) {
			status = 403;
			http_json_err(resp_out, 403, "Forbidden", "forbidden");
		} else if (!nr_same_origin(origin, host)) {
			status = 403;
			http_json_err(resp_out, 403, "Forbidden", "cross-origin request rejected");
		} else if (content_length > NR_MAX_ACTION_BODY || body_avail > NR_MAX_ACTION_BODY) {
			status = 413;
			http_json_err(resp_out, 413, "Content Too Large", "request body too large");
		} else {
			size_t blen = (content_length >= 0 && (size_t)content_length <= body_avail)
			                  ? (size_t)content_length
			                  : body_avail;
			char bstr[NR_MAX_ACTION_BODY + 1];
			memcpy(bstr, body, blen);
			bstr[blen] = '\0';
			cJSON *j = cJSON_Parse(bstr);
			const cJSON *jfp = j ? cJSON_GetObjectItemCaseSensitive(j, "fingerprint") : NULL;
			if (!j || !cJSON_IsObject(j) || !cJSON_IsString(jfp) || !jfp->valuestring || !jfp->valuestring[0]) {
				status = 400;
				http_json_err(resp_out, 400, "Bad Request", "invalid request");
			} else {
				const char *fp = jfp->valuestring;
				bool is_vis = false;
				for (int i = 0; i < n_vis; i++) {
					if (strcmp(vis[i]->fingerprint, fp) == 0) {
						is_vis = true;
						break;
					}
				}
				if (!is_vis) {
					status = 404;
					http_json_err(resp_out, 404, "Not Found", "peer not found");
				} else {
					char by[192];
					snprintf(by, sizeof(by), "%s (%.12s)", caller->name, caller->fingerprint);
					int rc = is_archive ? nr_registry_archive(reg, network, fp, by, now)
					                    : nr_registry_restore(reg, network, fp, by, now);
					if (rc == NR_OK) {
						http_response(resp_out, 200, "OK", "application/json", "{\"ok\":true}\n", 12, false);
					} else if (rc == NR_ERR_ONLINE) {
						status = 409;
						http_json_err(resp_out, 409, "Conflict", "peer is online");
					} else if (rc == NR_ERR_NOTFOUND) {
						status = 404;
						http_json_err(resp_out, 404, "Not Found", "peer not found");
					} else {
						status = 500;
						http_json_err(resp_out, 500, "Internal Server Error", "storage error");
					}
				}
			}
			cJSON_Delete(j);
		}
	} else {
		status = 404;
		http_response(resp_out, 404, "Not Found", "text/plain; charset=utf-8", "not found\n", 10, false);
	}

	free(ann);
	return status;
}

int nr_tls_accept_and_serve_once(nr_tls_server *tls, int client_fd, const char *src_ip, const char *network,
                                 nr_registry *reg, const char admin_groups[][64], int n_admin_groups, double now) {
	struct timeval tv = {.tv_sec = 5, .tv_usec = 0};
	setsockopt(client_fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
	setsockopt(client_fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

	int rc = mbedtls_ssl_session_reset(&tls->ssl);
	if (rc != 0)
		return rc;
	mbedtls_ssl_set_bio(&tls->ssl, &client_fd, bio_send, bio_recv, NULL);

	while ((rc = mbedtls_ssl_handshake(&tls->ssl)) != 0) {
		if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE)
			return rc;
	}

	char req[16384];
	size_t total = 0;
	const char *hdr_end = NULL;
	long content_len = 0;
	while (total + 1 < sizeof(req)) {
		rc = mbedtls_ssl_read(&tls->ssl, (unsigned char *)req + total, sizeof(req) - 1 - total);
		if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE)
			continue;
		if (rc <= 0)
			break;
		total += (size_t)rc;
		req[total] = '\0';
		if (!hdr_end) {
			hdr_end = strstr(req, "\r\n\r\n");
			if (hdr_end) {
				/* Quick Content-Length scan */
				const char *p = req;
				while (p < hdr_end) {
					if (strncasecmp(p, "content-length:", 15) == 0) {
						content_len = strtol(p + 15, NULL, 10);
						break;
					}
					const char *nl = strchr(p, '\n');
					if (!nl || nl >= hdr_end) break;
					p = nl + 1;
				}
			}
		}
		if (hdr_end) {
			size_t body_got = total - (size_t)((hdr_end + 4) - req);
			if (content_len <= 0 || body_got >= (size_t)content_len || body_got > NR_MAX_ACTION_BODY)
				break;
		}
	}

	if (total > 0) {
		nr_buf resp;
		nr_buf_init(&resp, 4096);
		nr_handle_http_request(req, total, src_ip, network, reg, admin_groups, n_admin_groups, now, &resp);
		size_t sent = 0;
		while (sent < resp.len) {
			rc = mbedtls_ssl_write(&tls->ssl, (const unsigned char *)resp.data + sent, resp.len - sent);
			if (rc == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE)
				continue;
			if (rc <= 0)
				break;
			sent += (size_t)rc;
		}
		nr_buf_free(&resp);
	}

	while ((rc = mbedtls_ssl_close_notify(&tls->ssl)) == MBEDTLS_ERR_SSL_WANT_WRITE) {
	}
	return 0;
}

/* ---- ECDSA P-256 PEM + OpenSSH .pub Key Generator ---- */

static size_t ssh_put_str(uint8_t *dst, const void *data, size_t len) {
	dst[0] = (uint8_t)((len >> 24) & 0xFF);
	dst[1] = (uint8_t)((len >> 16) & 0xFF);
	dst[2] = (uint8_t)((len >> 8) & 0xFF);
	dst[3] = (uint8_t)(len & 0xFF);
	memcpy(dst + 4, data, len);
	return 4 + len;
}

int nr_keygen_ecdsa(const char *path) {
	if (!path || !path[0])
		return NR_ERR_IO;
	(void)psa_crypto_init();

	mbedtls_entropy_context entropy;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_pk_context pk;
	mbedtls_ecp_group grp;
	mbedtls_ecp_point Q;

	mbedtls_entropy_init(&entropy);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_pk_init(&pk);
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&Q);

	int ret = NR_ERR_IO;
	const char *pers = "nr-keygen";
	if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
	                          (const unsigned char *)pers, strlen(pers)) != 0)
		goto done;
	if (mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY)) != 0)
		goto done;
	if (mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(pk),
	                        mbedtls_ctr_drbg_random, &drbg) != 0)
		goto done;

	unsigned char pem[2048];
	if (mbedtls_pk_write_key_pem(&pk, pem, sizeof(pem)) != 0)
		goto done;

	/* Export uncompressed SEC1 public point for OpenSSH .pub format */
	if (mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) != 0)
		goto done;
	if (mbedtls_ecp_export(mbedtls_pk_ec(pk), NULL, NULL, &Q) != 0)
		goto done;
	unsigned char qbuf[128];
	size_t qlen = 0;
	if (mbedtls_ecp_point_write_binary(&grp, &Q, MBEDTLS_ECP_PF_UNCOMPRESSED,
	                                   &qlen, qbuf, sizeof(qbuf)) != 0)
		goto done;

	uint8_t blob[256];
	size_t blen = 0;
	blen += ssh_put_str(blob + blen, "ecdsa-sha2-nistp256", 19);
	blen += ssh_put_str(blob + blen, "nistp256", 8);
	blen += ssh_put_str(blob + blen, qbuf, qlen);

	unsigned char b64[512];
	size_t b64len = 0;
	if (mbedtls_base64_encode(b64, sizeof(b64), &b64len, blob, blen) != 0)
		goto done;

	int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (fd < 0)
		goto done;
	size_t pemlen = strlen((const char *)pem);
	ssize_t w = write(fd, pem, pemlen);
	int cl = close(fd);
	if (w != (ssize_t)pemlen || cl != 0)
		goto done;

	char pub_path[528];
	snprintf(pub_path, sizeof(pub_path), "%.512s.pub", path);
	int pfd = open(pub_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (pfd < 0)
		goto done;
	char pub_line[640];
	int plen = snprintf(pub_line, sizeof(pub_line), "ecdsa-sha2-nistp256 %.*s nebula-console\n",
	                    (int)b64len, (const char *)b64);
	if (plen <= 0 || write(pfd, pub_line, (size_t)plen) != plen || close(pfd) != 0) {
		goto done;
	}

	ret = NR_OK;
done:
	mbedtls_ecp_point_free(&Q);
	mbedtls_ecp_group_free(&grp);
	mbedtls_pk_free(&pk);
	mbedtls_ctr_drbg_free(&drbg);
	mbedtls_entropy_free(&entropy);
	return ret;
}

int nr_self_signed(const char *cert_path, const char *key_path, const char *hostname) {
	if (!cert_path || !cert_path[0] || !key_path || !key_path[0] || !hostname || !hostname[0])
		return NR_ERR_IO;
	(void)psa_crypto_init();

	mbedtls_entropy_context entropy;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_pk_context pk;
	mbedtls_x509write_cert crt;

	mbedtls_entropy_init(&entropy);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_pk_init(&pk);
	mbedtls_x509write_crt_init(&crt);

	int ret = NR_ERR_IO;
	const char *pers = "nr-self-signed";
	if (mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &entropy,
	                          (const unsigned char *)pers, strlen(pers)) != 0)
		goto done;
	if (mbedtls_pk_setup(&pk, mbedtls_pk_info_from_type(MBEDTLS_PK_ECKEY)) != 0)
		goto done;
	if (mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, mbedtls_pk_ec(pk),
	                        mbedtls_ctr_drbg_random, &drbg) != 0)
		goto done;

	unsigned char serial[16];
	if (mbedtls_ctr_drbg_random(&drbg, serial, sizeof(serial)) != 0)
		goto done;
	serial[0] = (unsigned char)((serial[0] & 0x7F) | 0x01);

	char dn[300];
	snprintf(dn, sizeof(dn), "CN=%.250s", hostname);
	mbedtls_x509write_crt_set_subject_key(&crt, &pk);
	mbedtls_x509write_crt_set_issuer_key(&crt, &pk);
	if (mbedtls_x509write_crt_set_subject_name(&crt, dn) != 0 ||
	    mbedtls_x509write_crt_set_issuer_name(&crt, dn) != 0)
		goto done;
	mbedtls_x509write_crt_set_md_alg(&crt, MBEDTLS_MD_SHA256);
	if (mbedtls_x509write_crt_set_serial_raw(&crt, serial, sizeof(serial)) != 0 ||
	    mbedtls_x509write_crt_set_validity(&crt, "20250101000000", "20350101000000") != 0)
		goto done;

	unsigned char key_pem[2048], crt_pem[4096];
	if (mbedtls_pk_write_key_pem(&pk, key_pem, sizeof(key_pem)) != 0 ||
	    mbedtls_x509write_crt_pem(&crt, crt_pem, sizeof(crt_pem),
	                              mbedtls_ctr_drbg_random, &drbg) != 0)
		goto done;

	int kfd = open(key_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
	if (kfd < 0)
		goto done;
	size_t klen = strlen((const char *)key_pem);
	if (write(kfd, key_pem, klen) != (ssize_t)klen || close(kfd) != 0)
		goto done;

	int cfd = open(cert_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (cfd < 0)
		goto done;
	size_t clen = strlen((const char *)crt_pem);
	if (write(cfd, crt_pem, clen) != (ssize_t)clen || close(cfd) != 0)
		goto done;

	ret = NR_OK;
done:
	mbedtls_x509write_crt_free(&crt);
	mbedtls_pk_free(&pk);
	mbedtls_ctr_drbg_free(&drbg);
	mbedtls_entropy_free(&entropy);
	return ret;
}

/* ---- Nebula Debug Console Poller (OpenSSH ssh or Dropbear dbclient) ---- */

static bool is_dbclient(const char *ssh_bin) {
	const char *base = strrchr(ssh_bin, '/');
	base = base ? base + 1 : ssh_bin;
	return strstr(base, "dbclient") != NULL;
}

static int run_console_cmd(const nr_app_config *cfg, int console_port, const char *cmd, nr_buf *out) {
	int pipefd[2];
	if (pipe(pipefd) != 0)
		return NR_ERR_IO;

	pid_t pid = fork();
	if (pid < 0) {
		close(pipefd[0]);
		close(pipefd[1]);
		return NR_ERR_IO;
	}
	if (pid == 0) {
		close(pipefd[0]);
		dup2(pipefd[1], STDOUT_FILENO);
		int devnull = open("/dev/null", O_RDWR);
		if (devnull >= 0) {
			dup2(devnull, STDIN_FILENO);
			dup2(devnull, STDERR_FILENO);
			close(devnull);
		}
		close(pipefd[1]);

		char port_s[16], target[128], key_path[544], kh_opt[576], cp_opt[576];
		snprintf(port_s, sizeof(port_s), "%d", console_port);
		snprintf(target, sizeof(target), "%s@127.0.0.1", cfg->console_user);
		snprintf(key_path, sizeof(key_path), "%s/client_key", cfg->state_dir);

		if (is_dbclient(cfg->ssh_bin)) {
			const char *argv[] = {
				cfg->ssh_bin, "-y", "-y", "-T", "-q", "-o", "BatchMode=yes",
				"-i", key_path, "-p", port_s, target, cmd, NULL
			};
			execvp(cfg->ssh_bin, (char *const *)argv);
		} else {
			snprintf(kh_opt, sizeof(kh_opt), "UserKnownHostsFile=%s/known_hosts", cfg->state_dir);
			snprintf(cp_opt, sizeof(cp_opt), "ControlPath=%s/ctrl-%%p", cfg->state_dir);
			const char *argv[] = {
				cfg->ssh_bin,
				"-o", "BatchMode=yes",
				"-o", "StrictHostKeyChecking=yes",
				"-o", kh_opt,
				"-o", "ControlMaster=auto",
				"-o", cp_opt,
				"-o", "ControlPersist=120",
				"-o", "ConnectTimeout=5",
				"-i", key_path,
				"-p", port_s,
				target, cmd, NULL
			};
			execvp(cfg->ssh_bin, (char *const *)argv);
		}
		_exit(127);
	}

	close(pipefd[1]);
	double deadline = now_mono() + 10.0;
	for (;;) {
		double rem = deadline - now_mono();
		if (rem <= 0) {
			kill(pid, SIGKILL);
			break;
		}
		struct pollfd pfd = {.fd = pipefd[0], .events = POLLIN};
		int pr = poll(&pfd, 1, (int)(rem * 1000.0));
		if (pr < 0) {
			if (errno == EINTR) continue;
			break;
		}
		if (pr == 0) {
			kill(pid, SIGKILL);
			break;
		}
		char buf[4096];
		ssize_t n = read(pipefd[0], buf, sizeof(buf));
		if (n <= 0)
			break;
		if (out->len + (size_t)n <= 512 * 1024)
			nr_buf_append_n(out, buf, (size_t)n);
	}
	close(pipefd[0]);

	int status = 0;
	while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
	}
	return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? NR_OK : NR_ERR_IO;
}

static void poll_all_networks(const nr_app_config *cfg, nr_registry *reg, uint32_t *serial, double *last_prune) {
	double now = now_epoch();
	for (int i = 0; i < cfg->n_nets; i++) {
		const nr_net_config *nc = &cfg->nets[i];
		if (nc->console_port <= 0)
			continue;

		nr_buf hm, self_b;
		nr_buf_init(&hm, 4096);
		nr_buf_init(&self_b, 1024);

		int rc_hm = run_console_cmd(cfg, nc->console_port, "list-hostmap -json", &hm);
		int rc_self = run_console_cmd(cfg, nc->console_port, "print-cert -json", &self_b);

		if (rc_hm == NR_OK) {
			nr_obs obs[NR_MAX_PEERS];
			int n = nr_parse_hostmap(hm.data, obs, NR_MAX_PEERS - 1);
			if (n < 0)
				n = 0;
			if (rc_self == NR_OK && n < NR_MAX_PEERS) {
				if (nr_parse_self(self_b.data, &obs[n]) == NR_OK)
					n++;
			}
			int prev_n = reg->n_peers;
			nr_registry_record(reg, nc->name, obs, n, now);
			nr_registry_sweep(reg, nc->name, now);
			if (reg->n_peers != prev_n)
				(*serial)++;
		} else {
			fprintf(stderr, "nebula-registry: console poll failed for %s (port %d)\n",
			        nc->name, nc->console_port);
		}

		nr_buf_free(&hm);
		nr_buf_free(&self_b);
	}

	if (now - *last_prune >= 3600.0) {
		nr_registry_prune(reg, now, cfg->event_retention_days);
		*last_prune = now;
	}
}

/* ---- Socket Setup & Single-Process poll() Loop ---- */

static int bind_socket(const char *addr, int port, int socktype, const char *iface) {
	struct sockaddr_in sa;
	memset(&sa, 0, sizeof(sa));
	sa.sin_family = AF_INET;
	sa.sin_port = htons((uint16_t)port);
	if (inet_pton(AF_INET, addr, &sa.sin_addr) != 1)
		return -1;

	int fd = socket(AF_INET, socktype, 0);
	if (fd < 0)
		return -1;
	int one = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	setsockopt(fd, IPPROTO_IP, IP_FREEBIND, &one, sizeof(one));
	if (iface && iface[0]) {
		if (setsockopt(fd, SOL_SOCKET, SO_BINDTODEVICE, iface, (socklen_t)strlen(iface) + 1) != 0) {
			fprintf(stderr, "nebula-registry: SO_BINDTODEVICE(%s): %s\n", iface, strerror(errno));
			close(fd);
			return -1;
		}
	}

	if (bind(fd, (struct sockaddr *)&sa, sizeof(sa)) != 0) {
		fprintf(stderr, "nebula-registry: bind %s:%d (%s): %s\n",
		        addr, port, socktype == SOCK_DGRAM ? "udp" : "tcp", strerror(errno));
		close(fd);
		return -1;
	}
	if (socktype == SOCK_STREAM && listen(fd, 16) != 0) {
		close(fd);
		return -1;
	}
	return fd;
}

typedef enum {
	SOCK_DNS_UDP = 1,
	SOCK_DNS_TCP = 2,
	SOCK_HTTPS = 3,
} sock_kind;

typedef struct {
	int fd;
	sock_kind kind;
	int net_idx;
} listen_slot;

int nr_run_server(const nr_app_config *cfg) {
	signal(SIGPIPE, SIG_IGN);
	struct sigaction sa;
	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = on_signal;
	sigaction(SIGTERM, &sa, NULL);
	sigaction(SIGINT, &sa, NULL);

	char state_path[544];
	snprintf(state_path, sizeof(state_path), "%s/registry.json", cfg->state_dir);
	nr_registry reg;
	double offline_after = cfg->poll_interval * cfg->offline_after_polls;
	if (nr_registry_init(&reg, state_path, offline_after) != NR_OK) {
		fprintf(stderr, "nebula-registry: failed to load state %s\n", state_path);
		return 1;
	}

	nr_tls_server *tls = NULL;
	if (cfg->tls.enabled) {
		tls = nr_tls_server_new(&cfg->tls);
		if (!tls) {
			fprintf(stderr, "nebula-registry: failed to initialize TLS\n");
			nr_registry_free(&reg);
			return 1;
		}
	}

	nr_zone zones[NR_MAX_NETWORKS];
	memset(zones, 0, sizeof(zones));
	listen_slot slots[NR_MAX_NETWORKS * 3];
	int n_slots = 0;

	for (int i = 0; i < cfg->n_nets; i++) {
		const nr_net_config *nc = &cfg->nets[i];
		snprintf(zones[i].domain, sizeof(zones[i].domain), "%s", nc->domain);
		snprintf(zones[i].address, sizeof(zones[i].address), "%s", nc->address);
		snprintf(zones[i].site, sizeof(zones[i].site), "%s", nc->site);
		zones[i].n_aliases = nc->n_aliases;
		for (int a = 0; a < nc->n_aliases; a++)
			snprintf(zones[i].aliases[a], 256, "%s", nc->aliases[a]);
		zones[i].n_statics = nc->n_statics;
		for (int s = 0; s < nc->n_statics; s++)
			zones[i].statics[s] = nc->statics[s];

		if (nc->dns_port > 0) {
			int ufd = bind_socket(nc->address, nc->dns_port, SOCK_DGRAM, nc->iface);
			int tfd = bind_socket(nc->address, nc->dns_port, SOCK_STREAM, nc->iface);
			if (ufd < 0 || tfd < 0) {
				if (ufd >= 0) close(ufd);
				if (tfd >= 0) close(tfd);
				goto fail;
			}
			slots[n_slots++] = (listen_slot){.fd = ufd, .kind = SOCK_DNS_UDP, .net_idx = i};
			slots[n_slots++] = (listen_slot){.fd = tfd, .kind = SOCK_DNS_TCP, .net_idx = i};
		}
		if (tls && cfg->tls.port > 0) {
			int hfd = bind_socket(nc->address, cfg->tls.port, SOCK_STREAM, nc->iface);
			if (hfd < 0)
				goto fail;
			slots[n_slots++] = (listen_slot){.fd = hfd, .kind = SOCK_HTTPS, .net_idx = i};
		}
	}

	uint32_t serial = (uint32_t)time(NULL);
	double last_prune = 0.0;
	poll_all_networks(cfg, &reg, &serial, &last_prune);
	double next_poll = now_mono() + cfg->poll_interval;

	fprintf(stderr, "nebula-registry: serving %d network(s) on %d socket(s)\n", cfg->n_nets, n_slots);

	while (!g_stop) {
		struct pollfd pfds[NR_MAX_NETWORKS * 3];
		for (int i = 0; i < n_slots; i++) {
			pfds[i].fd = slots[i].fd;
			pfds[i].events = POLLIN;
			pfds[i].revents = 0;
		}
		double wait_s = next_poll - now_mono();
		int timeout_ms = wait_s > 0 ? (int)(wait_s * 1000.0) : 0;
		if (timeout_ms > 5000)
			timeout_ms = 5000;

		int pr = poll(pfds, (nfds_t)n_slots, timeout_ms);
		if (pr > 0) {
			for (int i = 0; i < n_slots; i++) {
				if (!(pfds[i].revents & POLLIN))
					continue;
				int ni = slots[i].net_idx;
				const nr_net_config *nc = &cfg->nets[ni];

				if (slots[i].kind == SOCK_DNS_UDP) {
					uint8_t qbuf[4096], rbuf[4096];
					struct sockaddr_in peer;
					socklen_t plen = sizeof(peer);
					ssize_t n = recvfrom(slots[i].fd, qbuf, sizeof(qbuf), 0,
					                     (struct sockaddr *)&peer, &plen);
					if (n > 0) {
						size_t rn = nr_dns_respond(qbuf, (size_t)n, &zones[ni], &reg, nc->name,
						                           serial, cfg->upstreams, cfg->n_upstreams,
						                           false, rbuf, sizeof(rbuf));
						if (rn > 0)
							(void)sendto(slots[i].fd, rbuf, rn, 0, (struct sockaddr *)&peer, plen);
					}
				} else if (slots[i].kind == SOCK_DNS_TCP) {
					int cfd = accept(slots[i].fd, NULL, NULL);
					if (cfd >= 0) {
						struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
						setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
						setsockopt(cfd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
						uint8_t hdr[2];
						if (recv(cfd, hdr, 2, MSG_WAITALL) == 2) {
							uint16_t qlen = (uint16_t)((hdr[0] << 8) | hdr[1]);
							if (qlen > 0 && qlen <= 4096) {
								uint8_t qbuf[4096], rbuf[4096];
								if (recv(cfd, qbuf, qlen, MSG_WAITALL) == qlen) {
									size_t rn = nr_dns_respond(qbuf, qlen, &zones[ni], &reg, nc->name,
									                           serial, cfg->upstreams, cfg->n_upstreams,
									                           true, rbuf, sizeof(rbuf));
									if (rn > 0) {
										uint8_t rh[2] = {(uint8_t)(rn >> 8), (uint8_t)(rn & 0xFF)};
										(void)send(cfd, rh, 2, MSG_NOSIGNAL);
										(void)send(cfd, rbuf, rn, MSG_NOSIGNAL);
									}
								}
							}
						}
						close(cfd);
					}
				} else if (slots[i].kind == SOCK_HTTPS) {
					struct sockaddr_in peer;
					socklen_t plen = sizeof(peer);
					int cfd = accept(slots[i].fd, (struct sockaddr *)&peer, &plen);
					if (cfd >= 0) {
						char ip[64] = "";
						inet_ntop(AF_INET, &peer.sin_addr, ip, sizeof(ip));
						(void)nr_tls_accept_and_serve_once(tls, cfd, ip, nc->name, &reg,
						                                   nc->admin_groups, nc->n_admin_groups,
						                                   now_epoch());
						close(cfd);
					}
				}
			}
		}

		if (now_mono() >= next_poll) {
			poll_all_networks(cfg, &reg, &serial, &last_prune);
			next_poll = now_mono() + cfg->poll_interval;
		}
	}

	for (int i = 0; i < n_slots; i++)
		close(slots[i].fd);
	nr_tls_server_free(tls);
	nr_registry_free(&reg);
	return 0;

fail:
	for (int i = 0; i < n_slots; i++)
		close(slots[i].fd);
	nr_tls_server_free(tls);
	nr_registry_free(&reg);
	return 1;
}
