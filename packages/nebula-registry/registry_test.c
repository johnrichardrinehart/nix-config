#define _POSIX_C_SOURCE 200809L

#include "registry.h"

#include <arpa/inet.h>
#include <assert.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cjson/cJSON.h>
#include <mbedtls/ctr_drbg.h>
#include <mbedtls/entropy.h>
#include <mbedtls/ssl.h>
#include <mbedtls/x509_crt.h>
#include <psa/crypto.h>

static char *read_fixture(const char *path) {
	FILE *f = fopen(path, "rb");
	assert(f != NULL);
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	char *buf = malloc((size_t)sz + 1);
	assert(buf != NULL);
	size_t rd = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	buf[rd] = '\0';
	return buf;
}

static nr_obs make_obs(const char *fp, const char *name, const char *cidr, const char *group, const char *underlay, bool relayed) {
	nr_obs o;
	memset(&o, 0, sizeof(o));
	snprintf(o.fingerprint, sizeof(o.fingerprint), "%s", fp);
	snprintf(o.name, sizeof(o.name), "%s", name);
	snprintf(o.vpn_addrs[0], 64, "%s", cidr);
	o.n_vpn_addrs = 1;
	if (group && group[0]) {
		snprintf(o.groups[0], 64, "%s", group);
		o.n_groups = 1;
	}
	snprintf(o.issuer, sizeof(o.issuer), "ca");
	snprintf(o.not_before, sizeof(o.not_before), "2026-09-27T20:36:28Z");
	snprintf(o.not_after, sizeof(o.not_after), "2027-09-25T12:52:29Z");
	if (underlay && underlay[0]) {
		snprintf(o.underlay, sizeof(o.underlay), "%s", underlay);
		o.has_underlay = true;
	}
	o.relayed = relayed;
	return o;
}

static size_t build_dns_query(const char *name, uint16_t qtype, uint8_t *out, size_t cap) {
	assert(cap >= 512);
	memset(out, 0, 12);
	out[0] = 0x12; out[1] = 0x34;
	out[2] = 0x01; out[3] = 0x00; /* RD */
	out[5] = 1;                   /* QDCOUNT = 1 */
	size_t pos = 12;
	const char *p = name;
	while (*p) {
		const char *dot = strchr(p, '.');
		size_t l = dot ? (size_t)(dot - p) : strlen(p);
		if (l == 0) {
			if (!dot) break;
			p = dot + 1;
			continue;
		}
		out[pos++] = (uint8_t)l;
		memcpy(out + pos, p, l);
		pos += l;
		if (!dot) break;
		p = dot + 1;
	}
	out[pos++] = 0;
	out[pos++] = (uint8_t)(qtype >> 8);
	out[pos++] = (uint8_t)(qtype & 0xFF);
	out[pos++] = 0;
	out[pos++] = 1;
	return pos;
}

static void test_console_fixtures(void) {
	char *hm = read_fixture("fixtures/list-hostmap.json");
	char *pc = read_fixture("fixtures/print-cert.json");
	nr_obs obs[16];
	int n = nr_parse_hostmap(hm, obs, 16);
	assert(n == 1);
	assert(strcmp(obs[0].name, "framework") == 0);
	assert(strcmp(obs[0].vpn_addrs[0], "10.77.0.2/24") == 0);
	assert(strcmp(obs[0].groups[0], "peer") == 0);
	assert(obs[0].has_underlay && strcmp(obs[0].underlay, "203.0.113.10:55065") == 0);
	assert(!obs[0].relayed);

	nr_obs self_o;
	assert(nr_parse_self(pc, &self_o) == NR_OK);
	assert(strcmp(self_o.name, "lighthouse") == 0);
	assert(strcmp(self_o.vpn_addrs[0], "10.77.0.1/24") == 0);
	assert(self_o.n_groups == 0);
	assert(!self_o.has_underlay);
	free(hm);
	free(pc);
}

static void test_dns_labels_and_cidr(void) {
	char label[64];
	assert(nr_dns_label("My_Host.01!", label, sizeof(label)));
	assert(strcmp(label, "my-host-01") == 0);
	assert(!nr_dns_label("---", label, sizeof(label)));
	assert(nr_ip_in_cidr("10.77.0.2", "10.77.0.1/24"));
	assert(!nr_ip_in_cidr("10.78.0.2", "10.77.0.1/24"));
}

static void test_liveness_persistence_and_archive(const char *tmpdir) {
	char state[512];
	snprintf(state, sizeof(state), "%s/registry.json", tmpdir);

	nr_registry reg;
	assert(nr_registry_init(&reg, state, 30.0) == NR_OK);

	nr_obs obs[2];
	obs[0] = make_obs("fp-lh-0000000001", "lighthouse", "10.77.0.1/24", NULL, NULL, false);
	obs[1] = make_obs("fp-fw-0000000002", "framework", "10.77.0.2/24", "peer", "1.2.3.4:5000", false);
	assert(nr_registry_record(&reg, "mycelium", obs, 2, 1000.0) == NR_OK);
	assert(reg.n_peers == 2);
	assert(reg.peers[1].online);

	/* Underlay change + relay flag */
	obs[1] = make_obs("fp-fw-0000000002", "framework", "10.77.0.2/24", "peer", "5.6.7.8:6000", true);
	assert(nr_registry_record(&reg, "mycelium", obs, 2, 1010.0) == NR_OK);
	assert(reg.peers[1].relayed);
	assert(strcmp(reg.peers[1].last_underlay, "5.6.7.8:6000") == 0);

	/* Cannot archive online peer */
	assert(nr_registry_archive(&reg, "mycelium", "fp-fw-0000000002", "admin", 1015.0) == NR_ERR_ONLINE);

	/* Sweep marks framework offline when only lighthouse reports */
	assert(nr_registry_record(&reg, "mycelium", &obs[0], 1, 1050.0) == NR_OK);
	assert(nr_registry_sweep(&reg, "mycelium", 1050.0) == NR_OK);
	assert(!reg.peers[1].online);

	/* Archive offline peer & reload from disk */
	assert(nr_registry_archive(&reg, "mycelium", "fp-fw-0000000002", "admin (123456789012)", 1060.0) == NR_OK);
	assert(reg.peers[1].is_archived);
	nr_registry_free(&reg);

	nr_registry reloaded;
	assert(nr_registry_init(&reloaded, state, 30.0) == NR_OK);
	assert(reloaded.n_peers == 2);
	assert(reloaded.peers[1].is_archived);
	assert(strcmp(reloaded.peers[1].archived_by, "admin (123456789012)") == 0);

	/* Reconnecting auto-restores archived peer */
	assert(nr_registry_record(&reloaded, "mycelium", &obs[1], 1, 1070.0) == NR_OK);
	assert(!reloaded.peers[1].is_archived);
	assert(reloaded.peers[1].online);

	/* Prune old events */
	assert(nr_registry_prune(&reloaded, 1070.0 + 400.0 * 86400.0, 365) == NR_OK);
	assert(reloaded.n_events == 0);
	nr_registry_free(&reloaded);
}

static void test_annotations_and_visibility(void) {
	nr_registry reg;
	assert(nr_registry_init(&reg, "", 30.0) == NR_OK);
	nr_obs a = make_obs("fp-old-1111111111", "dupnode", "10.77.0.5/24", "peer", "1.1.1.1:1", false);
	nr_obs b = make_obs("fp-new-2222222222", "dupnode", "10.77.0.6/24", "peer", "1.1.1.1:2", false);
	nr_obs c = make_obs("fp-shr-3333333333", "sharer", "10.77.0.5/24", "peer", "1.1.1.1:3", false);
	nr_obs other_net = make_obs("fp-oth-4444444444", "outsider", "10.88.0.5/24", "peer", "1.1.1.1:4", false);

	assert(nr_registry_record(&reg, "mycelium", &a, 1, 100.0) == NR_OK);
	assert(nr_registry_record(&reg, "mycelium", &b, 1, 110.0) == NR_OK);
	assert(nr_registry_record(&reg, "mycelium", &c, 1, 110.0) == NR_OK);
	assert(nr_registry_record(&reg, "mycelium", &other_net, 1, 110.0) == NR_OK);

	const nr_peer *caller = nr_find_caller(&reg, "mycelium", "10.77.0.6");
	assert(caller != NULL && strcmp(caller->fingerprint, "fp-new-2222222222") == 0);

	const nr_peer *vis[16];
	int n_vis = nr_visible_peers(&reg, "mycelium", caller, vis, 16);
	assert(n_vis == 3); /* outsider on 10.88.0.5/24 excluded */

	nr_annotated ann[16];
	nr_annotate(vis, n_vis, ann);
	bool saw_superseded = false, saw_dup = false, saw_share = false;
	for (int i = 0; i < n_vis; i++) {
		if (strcmp(ann[i].peer->fingerprint, "fp-old-1111111111") == 0) {
			assert(strcmp(ann[i].superseded_by, "fp-new-2222222222") == 0);
			assert(ann[i].n_duplicates == 1);
			assert(ann[i].n_shares == 1 && strcmp(ann[i].shares[0].name, "sharer") == 0);
			saw_superseded = saw_dup = saw_share = true;
		}
	}
	assert(saw_superseded && saw_dup && saw_share);
	nr_registry_free(&reg);
}

static void test_dns_answers(void) {
	nr_registry reg;
	assert(nr_registry_init(&reg, "", 30.0) == NR_OK);
	nr_obs fw = make_obs("fp-fw", "framework", "10.77.0.2/24", "peer", "1.2.3.4:5", false);
	assert(nr_registry_record(&reg, "mycelium", &fw, 1, 100.0) == NR_OK);

	nr_zone z;
	memset(&z, 0, sizeof(z));
	snprintf(z.domain, sizeof(z.domain), "mycelium.nebula.johnrinehart.dev");
	snprintf(z.address, sizeof(z.address), "10.77.0.1");
	snprintf(z.site, sizeof(z.site), "lighthouse.mycelium.nebula.johnrinehart.dev");
	snprintf(z.aliases[0], 256, "mycelium.internal");
	z.n_aliases = 1;

	uint8_t q[512], resp[1024];
	/* Peer lookup in alias zone */
	size_t qlen = build_dns_query("framework.mycelium.internal", 1, q, sizeof(q));
	assert(nr_dns_is_local(q, qlen, &z));
	size_t rlen = nr_dns_answer(q, qlen, &z, &reg, "mycelium", 1, resp, sizeof(resp));
	assert(rlen > qlen);
	assert((resp[3] & 0x0F) == 0); /* NOERROR */
	assert(((resp[6] << 8) | resp[7]) == 1); /* ANCOUNT = 1 */
	assert(resp[rlen - 4] == 10 && resp[rlen - 3] == 77 && resp[rlen - 2] == 0 && resp[rlen - 1] == 2);

	/* Site lookup */
	qlen = build_dns_query("lighthouse.mycelium.nebula.johnrinehart.dev", 1, q, sizeof(q));
	rlen = nr_dns_answer(q, qlen, &z, &reg, "mycelium", 1, resp, sizeof(resp));
	assert(rlen > qlen && (resp[3] & 0x0F) == 0);
	assert(resp[rlen - 4] == 10 && resp[rlen - 3] == 77 && resp[rlen - 2] == 0 && resp[rlen - 1] == 1);

	/* NXDOMAIN for unknown peer */
	qlen = build_dns_query("missing.mycelium.internal", 1, q, sizeof(q));
	rlen = nr_dns_answer(q, qlen, &z, &reg, "mycelium", 1, resp, sizeof(resp));
	assert(rlen > 12 && (resp[3] & 0x0F) == 3); /* NXDOMAIN */

	/* AAAA returns NODATA (NOERROR + 0 answers + SOA authority) */
	qlen = build_dns_query("framework.mycelium.internal", 28, q, sizeof(q));
	rlen = nr_dns_answer(q, qlen, &z, &reg, "mycelium", 1, resp, sizeof(resp));
	assert(rlen > 12 && (resp[3] & 0x0F) == 0 && ((resp[6] << 8) | resp[7]) == 0 && ((resp[8] << 8) | resp[9]) == 1);

	/* Outside zone returns REFUSED when no upstreams */
	qlen = build_dns_query("example.com", 1, q, sizeof(q));
	assert(!nr_dns_is_local(q, qlen, &z));
	rlen = nr_dns_respond(q, qlen, &z, &reg, "mycelium", 1, NULL, 0, false, resp, sizeof(resp));
	assert(rlen > 12 && (resp[3] & 0x0F) == 5); /* REFUSED */

	nr_registry_free(&reg);
}

static void test_http_and_xss(void) {
	nr_registry reg;
	assert(nr_registry_init(&reg, "", 30.0) == NR_OK);
	nr_obs admin = make_obs("fp-adm-111111111111", "admin<script>", "10.77.0.2/24", "registry-admin", "1.2.3.4:1", false);
	nr_obs peer = make_obs("fp-off-222222222222", "thinkie", "10.77.0.8/24", "peer", "1.2.3.4:2", false);
	assert(nr_registry_record(&reg, "mycelium", &admin, 1, 100.0) == NR_OK);
	assert(nr_registry_record(&reg, "mycelium", &peer, 1, 100.0) == NR_OK);
	assert(nr_registry_record(&reg, "mycelium", &admin, 1, 200.0) == NR_OK);
	assert(nr_registry_sweep(&reg, "mycelium", 200.0) == NR_OK);

	char admins[1][64] = {"registry-admin"};
	nr_buf resp;

	/* GET / escapes HTML */
	nr_buf_init(&resp, 4096);
	const char *get_root = "GET / HTTP/1.1\r\nHost: lighthouse.mycelium.internal\r\n\r\n";
	assert(nr_handle_http_request(get_root, strlen(get_root), "10.77.0.2", "mycelium", &reg, admins, 1, 200.0, &resp) == 200);
	assert(strstr(resp.data, "admin&lt;script&gt;") != NULL);
	assert(strstr(resp.data, "<script>alert") == NULL);
	nr_buf_free(&resp);

	/* Unknown caller gets 403 */
	nr_buf_init(&resp, 512);
	assert(nr_handle_http_request(get_root, strlen(get_root), "10.77.0.99", "mycelium", &reg, admins, 1, 200.0, &resp) == 403);
	nr_buf_free(&resp);

	/* Cross-origin POST /api/archive rejected with 403 */
	const char *bad_post =
	    "POST /api/archive HTTP/1.1\r\nHost: lighthouse.mycelium.internal\r\n"
	    "Origin: https://evil.example\r\nContent-Length: 38\r\n\r\n"
	    "{\"fingerprint\":\"fp-off-222222222222\"}";
	nr_buf_init(&resp, 512);
	assert(nr_handle_http_request(bad_post, strlen(bad_post), "10.77.0.2", "mycelium", &reg, admins, 1, 200.0, &resp) == 403);
	nr_buf_free(&resp);

	/* Same-origin POST /api/archive succeeds with 200 */
	const char *good_post =
	    "POST /api/archive HTTP/1.1\r\nHost: lighthouse.mycelium.internal\r\n"
	    "Origin: https://lighthouse.mycelium.internal\r\nContent-Length: 37\r\n\r\n"
	    "{\"fingerprint\":\"fp-off-222222222222\"}";
	nr_buf_init(&resp, 512);
	assert(nr_handle_http_request(good_post, strlen(good_post), "10.77.0.2", "mycelium", &reg, admins, 1, 200.0, &resp) == 200);
	nr_buf_free(&resp);

	/* Restore succeeds */
	const char *rest_post =
	    "POST /api/restore HTTP/1.1\r\nHost: lighthouse.mycelium.internal\r\n"
	    "Origin: https://lighthouse.mycelium.internal\r\nContent-Length: 37\r\n\r\n"
	    "{\"fingerprint\":\"fp-off-222222222222\"}";
	nr_buf_init(&resp, 512);
	assert(nr_handle_http_request(rest_post, strlen(rest_post), "10.77.0.2", "mycelium", &reg, admins, 1, 200.0, &resp) == 200);
	nr_buf_free(&resp);

	nr_registry_free(&reg);
}

/* ---- Live mbedtls TLS SNI + preload test ---- */

typedef struct {
	nr_tls_server *tls;
	int listen_fd;
	nr_registry *reg;
} tls_thread_ctx;

static void *tls_server_thread(void *arg) {
	tls_thread_ctx *ctx = arg;
	for (int i = 0; i < 2; i++) {
		int cfd = accept(ctx->listen_fd, NULL, NULL);
		if (cfd >= 0) {
			nr_tls_accept_and_serve_once(ctx->tls, cfd, "10.77.0.2", "mycelium", ctx->reg, NULL, 0, 200.0);
			close(cfd);
		}
	}
	return NULL;
}

static int client_bio_send(void *ctx, const unsigned char *buf, size_t len) {
	return (int)send(*(int *)ctx, buf, len, MSG_NOSIGNAL);
}
static int client_bio_recv(void *ctx, unsigned char *buf, size_t len) {
	return (int)recv(*(int *)ctx, buf, len, 0);
}

static void fetch_sni_cn(int port, const char *sni_host, char *cn_out, size_t cn_sz) {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	assert(fd >= 0);
	struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = htons((uint16_t)port)};
	inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
	assert(connect(fd, (struct sockaddr *)&sa, sizeof(sa)) == 0);

	mbedtls_entropy_context ent;
	mbedtls_ctr_drbg_context drbg;
	mbedtls_ssl_config conf;
	mbedtls_ssl_context ssl;
	mbedtls_entropy_init(&ent);
	mbedtls_ctr_drbg_init(&drbg);
	mbedtls_ssl_config_init(&conf);
	mbedtls_ssl_init(&ssl);

	assert(mbedtls_ctr_drbg_seed(&drbg, mbedtls_entropy_func, &ent, (const unsigned char *)"cli", 3) == 0);
	assert(mbedtls_ssl_config_defaults(&conf, MBEDTLS_SSL_IS_CLIENT, MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) == 0);
	mbedtls_ssl_conf_authmode(&conf, MBEDTLS_SSL_VERIFY_NONE);
	mbedtls_ssl_conf_rng(&conf, mbedtls_ctr_drbg_random, &drbg);
	assert(mbedtls_ssl_setup(&ssl, &conf) == 0);
	assert(mbedtls_ssl_set_hostname(&ssl, sni_host) == 0);
	mbedtls_ssl_set_bio(&ssl, &fd, client_bio_send, client_bio_recv, NULL);

	int rc;
	while ((rc = mbedtls_ssl_handshake(&ssl)) == MBEDTLS_ERR_SSL_WANT_READ || rc == MBEDTLS_ERR_SSL_WANT_WRITE) {}
	assert(rc == 0);

	const mbedtls_x509_crt *peer = mbedtls_ssl_get_peer_cert(&ssl);
	assert(peer != NULL);
	char dn[256];
	mbedtls_x509_dn_gets(dn, sizeof(dn), &peer->subject);
	snprintf(cn_out, cn_sz, "%s", dn);

	const char *req = "GET /api/peers HTTP/1.1\r\nHost: test\r\n\r\n";
	assert(mbedtls_ssl_write(&ssl, (const unsigned char *)req, strlen(req)) > 0);
	unsigned char resp[2048];
	int n = mbedtls_ssl_read(&ssl, resp, sizeof(resp) - 1);
	assert(n > 0);
	resp[n] = '\0';
	assert(strstr((const char *)resp, "200 OK") != NULL);

	mbedtls_ssl_free(&ssl);
	mbedtls_ssl_config_free(&conf);
	mbedtls_ctr_drbg_free(&drbg);
	mbedtls_entropy_free(&ent);
	close(fd);
}

static void test_tls_sni_and_keygen(const char *tmpdir) {
	/* Test built-in ECDSA keygen and self-signed TLS cert generator */
	char kpath[512], ppath[528], scrt[512], skey[512];
	snprintf(kpath, sizeof(kpath), "%s/host_key", tmpdir);
	snprintf(ppath, sizeof(ppath), "%s/host_key.pub", tmpdir);
	snprintf(scrt, sizeof(scrt), "%s/self.crt", tmpdir);
	snprintf(skey, sizeof(skey), "%s/self.key", tmpdir);
	assert(nr_keygen_ecdsa(kpath) == NR_OK);
	char *pem = read_fixture(kpath);
	char *pub = read_fixture(ppath);
	assert(strstr(pem, "BEGIN EC PRIVATE KEY") != NULL);
	assert(strncmp(pub, "ecdsa-sha2-nistp256 ", 20) == 0);
	free(pem);
	free(pub);

	assert(nr_self_signed(scrt, skey, "uz801-0.mycelium.internal") == NR_OK);
	nr_tls_config self_cfg;
	memset(&self_cfg, 0, sizeof(self_cfg));
	self_cfg.enabled = true;
	snprintf(self_cfg.cert_file, sizeof(self_cfg.cert_file), "%s", scrt);
	snprintf(self_cfg.key_file, sizeof(self_cfg.key_file), "%s", skey);
	nr_tls_server *self_srv = nr_tls_server_new(&self_cfg);
	assert(self_srv != NULL);
	nr_tls_server_free(self_srv);

	/* Generate two self-signed certs via openssl in tmpdir for SNI test */
	char cmd[1024];
	snprintf(cmd, sizeof(cmd),
	         "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes "
	         "-keyout %s/def.key -out %s/def.crt -days 1 -subj /CN=default.example 2>/dev/null && "
	         "openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes "
	         "-keyout %s/ext.key -out %s/ext.crt -days 1 -subj /CN=extra.internal 2>/dev/null",
	         tmpdir, tmpdir, tmpdir, tmpdir);
	assert(system(cmd) == 0);

	/* Missing extra cert must fail startup */
	nr_tls_config bad;
	memset(&bad, 0, sizeof(bad));
	bad.enabled = true;
	snprintf(bad.cert_file, sizeof(bad.cert_file), "%s/def.crt", tmpdir);
	snprintf(bad.key_file, sizeof(bad.key_file), "%s/def.key", tmpdir);
	bad.n_extras = 1;
	snprintf(bad.extras[0].host, sizeof(bad.extras[0].host), "missing.internal");
	snprintf(bad.extras[0].cert_file, sizeof(bad.extras[0].cert_file), "%s/nope.crt", tmpdir);
	snprintf(bad.extras[0].key_file, sizeof(bad.extras[0].key_file), "%s/nope.key", tmpdir);
	assert(nr_tls_server_new(&bad) == NULL);

	/* Valid SNI preload survives deletion of extra cert/key files */
	nr_tls_config good = bad;
	snprintf(good.extras[0].host, sizeof(good.extras[0].host), "extra.internal");
	snprintf(good.extras[0].cert_file, sizeof(good.extras[0].cert_file), "%s/ext.crt", tmpdir);
	snprintf(good.extras[0].key_file, sizeof(good.extras[0].key_file), "%s/ext.key", tmpdir);
	nr_tls_server *tls = nr_tls_server_new(&good);
	assert(tls != NULL);
	unlink(good.extras[0].cert_file);
	unlink(good.extras[0].key_file);

	nr_registry reg;
	assert(nr_registry_init(&reg, "", 30.0) == NR_OK);
	nr_obs fw = make_obs("fp-fw", "framework", "10.77.0.2/24", "peer", NULL, false);
	assert(nr_registry_record(&reg, "mycelium", &fw, 1, 200.0) == NR_OK);

	int lfd = socket(AF_INET, SOCK_STREAM, 0);
	struct sockaddr_in sa = {.sin_family = AF_INET, .sin_port = 0};
	inet_pton(AF_INET, "127.0.0.1", &sa.sin_addr);
	assert(bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) == 0);
	assert(listen(lfd, 4) == 0);
	socklen_t slen = sizeof(sa);
	assert(getsockname(lfd, (struct sockaddr *)&sa, &slen) == 0);
	int port = ntohs(sa.sin_port);

	tls_thread_ctx ctx = {.tls = tls, .listen_fd = lfd, .reg = &reg};
	pthread_t tid;
	assert(pthread_create(&tid, NULL, tls_server_thread, &ctx) == 0);

	char dn1[256], dn2[256];
	fetch_sni_cn(port, "default.example", dn1, sizeof(dn1));
	fetch_sni_cn(port, "extra.internal", dn2, sizeof(dn2));
	pthread_join(tid, NULL);

	assert(strstr(dn1, "CN=default.example") != NULL);
	assert(strstr(dn2, "CN=extra.internal") != NULL);

	close(lfd);
	nr_tls_server_free(tls);
	nr_registry_free(&reg);
}

int main(void) {
	char tmpl[] = "/tmp/nr-test-XXXXXX";
	char *tmpdir = mkdtemp(tmpl);
	assert(tmpdir != NULL);

	test_console_fixtures();
	test_dns_labels_and_cidr();
	test_liveness_persistence_and_archive(tmpdir);
	test_annotations_and_visibility();
	test_dns_answers();
	test_http_and_xss();
	test_tls_sni_and_keygen(tmpdir);

	printf("All nebula-registry C tests passed.\n");
	return 0;
}
