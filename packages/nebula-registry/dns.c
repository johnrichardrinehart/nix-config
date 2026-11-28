#define _POSIX_C_SOURCE 200809L

#include "registry.h"

#include <arpa/inet.h>
#include <ctype.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

enum {
	QTYPE_A = 1,
	QTYPE_NS = 2,
	QTYPE_SOA = 6,
	QTYPE_AAAA = 28,
	QTYPE_ANY = 255,
	QCLASS_IN = 1,
	RCODE_NOERROR = 0,
	RCODE_SERVFAIL = 2,
	RCODE_NXDOMAIN = 3,
	RCODE_REFUSED = 5,
};

typedef struct {
	uint16_t id;
	uint16_t flags;
	char qname[256];
	uint16_t qtype;
	uint16_t qclass;
} dns_query;

static uint16_t rd16(const uint8_t *p) { return (uint16_t)((p[0] << 8) | p[1]); }
static void wr16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)(v >> 8); p[1] = (uint8_t)(v & 0xFF); }
static void wr32(uint8_t *p, uint32_t v) {
	p[0] = (uint8_t)(v >> 24);
	p[1] = (uint8_t)(v >> 16);
	p[2] = (uint8_t)(v >> 8);
	p[3] = (uint8_t)(v & 0xFF);
}

static bool decode_name(const uint8_t *pkt, size_t len, size_t off, char *out, size_t out_sz, size_t *end_off) {
	size_t w = 0;
	bool jumped = false;
	size_t steps = 0;
	*end_off = off;
	for (;;) {
		if (off >= len || ++steps > len)
			return false;
		uint8_t l = pkt[off];
		if (l == 0) {
			if (!jumped) *end_off = off + 1;
			break;
		}
		if ((l & 0xC0) == 0xC0) {
			if (off + 1 >= len) return false;
			size_t ptr = (size_t)(((l & 0x3F) << 8) | pkt[off + 1]);
			if (!jumped) {
				*end_off = off + 2;
				jumped = true;
			}
			off = ptr;
			continue;
		}
		if ((l & 0xC0) != 0)
			return false;
		off++;
		if (off + l > len)
			return false;
		if (w > 0) {
			if (w + 1 >= out_sz) return false;
			out[w++] = '.';
		}
		if (w + l >= out_sz) return false;
		memcpy(out + w, pkt + off, l);
		w += l;
		off += l;
	}
	out[w] = '\0';
	return true;
}

static size_t encode_name(const char *name, uint8_t *out, size_t cap) {
	size_t w = 0;
	const char *p = name;
	while (*p) {
		const char *dot = strchr(p, '.');
		size_t l = dot ? (size_t)(dot - p) : strlen(p);
		if (l == 0) {
			if (!dot) break;
			p = dot + 1;
			continue;
		}
		if (l > 63) l = 63;
		if (w + 1 + l + 1 > cap) return 0;
		out[w++] = (uint8_t)l;
		memcpy(out + w, p, l);
		w += l;
		if (!dot) break;
		p = dot + 1;
	}
	if (w + 1 > cap) return 0;
	out[w++] = 0;
	return w;
}

static bool parse_query(const uint8_t *pkt, size_t len, dns_query *q) {
	if (len < 12) return false;
	q->id = rd16(pkt);
	q->flags = rd16(pkt + 2);
	if (rd16(pkt + 4) < 1) return false;
	size_t off = 0;
	if (!decode_name(pkt, len, 12, q->qname, sizeof(q->qname), &off))
		return false;
	if (off + 4 > len) return false;
	q->qtype = rd16(pkt + off);
	q->qclass = rd16(pkt + off + 2);
	return true;
}

static void lower_strip_dot(const char *in, char *out, size_t sz) {
	size_t i = 0;
	for (; in[i] && i + 1 < sz; i++)
		out[i] = (char)tolower((unsigned char)in[i]);
	while (i > 0 && out[i - 1] == '.') i--;
	out[i] = '\0';
}

static bool match_zone_domain(const char *qname_l, const nr_zone *zone, char *dom_out, size_t dom_sz) {
	char cand[256];
	lower_strip_dot(zone->domain, cand, sizeof(cand));
	size_t cl = strlen(cand), ql = strlen(qname_l);
	if (cl > 0 && (strcmp(qname_l, cand) == 0 || (ql > cl && qname_l[ql - cl - 1] == '.' && strcmp(qname_l + ql - cl, cand) == 0))) {
		snprintf(dom_out, dom_sz, "%s", cand);
		return true;
	}
	for (int i = 0; i < zone->n_aliases; i++) {
		lower_strip_dot(zone->aliases[i], cand, sizeof(cand));
		cl = strlen(cand);
		if (cl > 0 && (strcmp(qname_l, cand) == 0 || (ql > cl && qname_l[ql - cl - 1] == '.' && strcmp(qname_l + ql - cl, cand) == 0))) {
			snprintf(dom_out, dom_sz, "%s", cand);
			return true;
		}
	}
	return false;
}

bool nr_dns_is_local(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone) {
	dns_query q;
	if (!parse_query(pkt, pkt_len, &q))
		return false;
	char ql[256], dom[256], site_l[256];
	lower_strip_dot(q.qname, ql, sizeof(ql));
	if (match_zone_domain(ql, zone, dom, sizeof(dom)))
		return true;
	if (zone->site[0]) {
		lower_strip_dot(zone->site, site_l, sizeof(site_l));
		if (strcmp(ql, site_l) == 0)
			return true;
	}
	return false;
}

static size_t append_rr(uint8_t *out, size_t pos, size_t cap, const char *name, uint16_t type, uint32_t ttl, const uint8_t *rdata, uint16_t rdlen) {
	size_t nl = encode_name(name, out + pos, cap - pos);
	if (nl == 0 || pos + nl + 10 + rdlen > cap)
		return 0;
	pos += nl;
	wr16(out + pos, type);
	wr16(out + pos + 2, QCLASS_IN);
	wr32(out + pos + 4, ttl);
	wr16(out + pos + 8, rdlen);
	pos += 10;
	memcpy(out + pos, rdata, rdlen);
	return pos + rdlen;
}

static size_t append_soa(uint8_t *out, size_t pos, size_t cap, const char *dom, const char *primary, uint32_t serial) {
	uint8_t rdata[512];
	char hm[300];
	snprintf(hm, sizeof(hm), "hostmaster.%s", dom);
	size_t n1 = encode_name(primary, rdata, sizeof(rdata));
	if (n1 == 0) return 0;
	size_t n2 = encode_name(hm, rdata + n1, sizeof(rdata) - n1);
	if (n2 == 0 || n1 + n2 + 20 > sizeof(rdata)) return 0;
	size_t o = n1 + n2;
	wr32(rdata + o, serial);
	wr32(rdata + o + 4, 3600);
	wr32(rdata + o + 8, 600);
	wr32(rdata + o + 12, 86400);
	wr32(rdata + o + 16, NR_DNS_TTL);
	return append_rr(out, pos, cap, dom, QTYPE_SOA, NR_DNS_TTL, rdata, (uint16_t)(o + 20));
}

size_t nr_dns_answer(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone, const nr_registry *r, const char *network, uint32_t serial, uint8_t *out, size_t out_cap) {
	dns_query q;
	if (!parse_query(pkt, pkt_len, &q) || out_cap < 512)
		return 0;

	char ql[256], dom[256], site_l[256], primary_dom[256], primary[300];
	lower_strip_dot(q.qname, ql, sizeof(ql));
	bool in_zone = match_zone_domain(ql, zone, dom, sizeof(dom));
	if (in_zone)
		snprintf(primary_dom, sizeof(primary_dom), "%s", dom);
	else
		lower_strip_dot(zone->domain, primary_dom, sizeof(primary_dom));
	if (zone->site[0])
		lower_strip_dot(zone->site, primary, sizeof(primary));
	else
		snprintf(primary, sizeof(primary), "ns.%s", primary_dom);

	/* Write header placeholder + question */
	memset(out, 0, 12);
	wr16(out, q.id);
	wr16(out + 4, 1);
	size_t nl = encode_name(q.qname, out + 12, out_cap - 12);
	if (nl == 0 || 12 + nl + 4 > out_cap)
		return 0;
	size_t pos = 12 + nl;
	wr16(out + pos, q.qtype);
	wr16(out + pos + 2, q.qclass);
	pos += 4;

	uint16_t ancount = 0, nscount = 0, rcode = RCODE_NOERROR;
	bool aa = true;

	char found_ips[NR_MAX_ADDRS][64];
	int n_found = 0;
	bool have_found = false;

	site_l[0] = '\0';
	if (zone->site[0])
		lower_strip_dot(zone->site, site_l, sizeof(site_l));

	if (site_l[0] && strcmp(ql, site_l) == 0) {
		snprintf(found_ips[0], 64, "%s", zone->address);
		n_found = 1;
		have_found = true;
	} else if (in_zone && strcmp(ql, dom) == 0) {
		if (q.qtype == QTYPE_SOA || q.qtype == QTYPE_ANY) {
			pos = append_soa(out, pos, out_cap, dom, primary, serial);
			ancount++;
		}
		if (q.qtype == QTYPE_NS || q.qtype == QTYPE_ANY) {
			uint8_t ns_rd[300];
			size_t nsl = encode_name(primary, ns_rd, sizeof(ns_rd));
			pos = append_rr(out, pos, out_cap, dom, QTYPE_NS, NR_DNS_TTL, ns_rd, (uint16_t)nsl);
			ancount++;
		}
		if (ancount == 0) {
			pos = append_soa(out, pos, out_cap, dom, primary, serial);
			nscount++;
		}
		goto finish;
	} else if (in_zone) {
		size_t dl = strlen(dom), qll = strlen(ql);
		if (qll > dl + 1 && ql[qll - dl - 1] == '.') {
			char label[256];
			size_t ll = qll - dl - 1;
			memcpy(label, ql, ll);
			label[ll] = '\0';
			if (!strchr(label, '.')) {
				/* Latest unarchived peer with matching DNS label wins */
				double best_last = -1.0;
				const nr_peer *best = NULL;
				for (int i = 0; i < r->n_peers; i++) {
					const nr_peer *p = &r->peers[i];
					if (p->is_archived || strcmp(p->network, network) != 0)
						continue;
					char pl[64];
					if (nr_dns_label(p->name, pl, sizeof(pl)) && strcmp(pl, label) == 0) {
						if (!best || p->last_seen >= best_last) {
							best = p;
							best_last = p->last_seen;
						}
					}
				}
				if (best) {
					for (int j = 0; j < best->n_vpn_addrs && n_found < NR_MAX_ADDRS; j++) {
						if (nr_cidr_to_ip(best->vpn_addrs[j], found_ips[n_found], 64))
							n_found++;
					}
					have_found = true;
				} else {
					for (int j = 0; j < zone->n_statics; j++) {
						if (strcmp(zone->statics[j].label, label) == 0) {
							snprintf(found_ips[0], 64, "%s", zone->statics[j].address);
							n_found = 1;
							have_found = true;
							break;
						}
					}
				}
			}
		}
		if (!have_found) {
			rcode = RCODE_NXDOMAIN;
			pos = append_soa(out, pos, out_cap, primary_dom, primary, serial);
			nscount = 1;
			goto finish;
		}
	} else {
		aa = false;
		rcode = RCODE_REFUSED;
		goto finish;
	}

	for (int i = 0; i < n_found; i++) {
		struct in_addr a4;
		struct in6_addr a6;
		if (inet_pton(AF_INET, found_ips[i], &a4) == 1 && (q.qtype == QTYPE_A || q.qtype == QTYPE_ANY)) {
			pos = append_rr(out, pos, out_cap, q.qname, QTYPE_A, NR_DNS_TTL, (const uint8_t *)&a4, 4);
			ancount++;
		} else if (inet_pton(AF_INET6, found_ips[i], &a6) == 1 && (q.qtype == QTYPE_AAAA || q.qtype == QTYPE_ANY)) {
			pos = append_rr(out, pos, out_cap, q.qname, QTYPE_AAAA, NR_DNS_TTL, (const uint8_t *)&a6, 16);
			ancount++;
		}
	}
	if (ancount == 0) {
		pos = append_soa(out, pos, out_cap, primary_dom, primary, serial);
		nscount = 1;
	}

finish:
	if (pos == 0)
		return 0;
	uint16_t flags = 0x8000 | (q.flags & 0x0100) | (rcode & 0x000F);
	if (aa) flags |= 0x0400;
	wr16(out + 2, flags);
	wr16(out + 6, ancount);
	wr16(out + 8, nscount);
	return pos;
}

static bool recv_exact(int fd, uint8_t *buf, size_t n) {
	size_t got = 0;
	while (got < n) {
		ssize_t r = recv(fd, buf + got, n - got, 0);
		if (r <= 0) return false;
		got += (size_t)r;
	}
	return true;
}

static bool parse_host_port(const char *spec, char *host, size_t hsz, int *port) {
	*port = 53;
	const char *colon = strrchr(spec, ':');
	if (colon && !strchr(spec, ']')) {
		/* Check if IPv6 without brackets (multiple colons) */
		if (strchr(spec, ':') != colon) {
			snprintf(host, hsz, "%s", spec);
			return true;
		}
		size_t l = (size_t)(colon - spec);
		if (l >= hsz) return false;
		memcpy(host, spec, l);
		host[l] = '\0';
		*port = atoi(colon + 1);
		return true;
	}
	snprintf(host, hsz, "%s", spec);
	return true;
}

size_t nr_dns_forward(const uint8_t *pkt, size_t pkt_len, const char upstreams[][64], int n_upstreams, bool tcp, uint8_t *out, size_t out_cap) {
	for (int i = 0; i < n_upstreams; i++) {
		char host[64];
		int port = 53;
		if (!parse_host_port(upstreams[i], host, sizeof(host), &port))
			continue;
		struct sockaddr_in sa4;
		memset(&sa4, 0, sizeof(sa4));
		sa4.sin_family = AF_INET;
		sa4.sin_port = htons((uint16_t)port);
		if (inet_pton(AF_INET, host, &sa4.sin_addr) != 1)
			continue;

		int fd = socket(AF_INET, tcp ? SOCK_STREAM : SOCK_DGRAM, 0);
		if (fd < 0) continue;
		struct timeval tv = {.tv_sec = tcp ? 3 : 2, .tv_usec = 0};
		setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
		setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

		if (connect(fd, (struct sockaddr *)&sa4, sizeof(sa4)) != 0) {
			close(fd);
			continue;
		}
		if (tcp) {
			uint8_t fl[2];
			wr16(fl, (uint16_t)pkt_len);
			if (send(fd, fl, 2, 0) != 2 || send(fd, pkt, pkt_len, 0) != (ssize_t)pkt_len || !recv_exact(fd, fl, 2)) {
				close(fd);
				continue;
			}
			uint16_t rlen = rd16(fl);
			if (rlen > out_cap || !recv_exact(fd, out, rlen)) {
				close(fd);
				continue;
			}
			close(fd);
			return rlen;
		} else {
			if (send(fd, pkt, pkt_len, 0) != (ssize_t)pkt_len) {
				close(fd);
				continue;
			}
			ssize_t r = recv(fd, out, out_cap, 0);
			close(fd);
			if (r > 0)
				return (size_t)r;
		}
	}
	return 0;
}

size_t nr_dns_respond(const uint8_t *pkt, size_t pkt_len, const nr_zone *zone, const nr_registry *r, const char *network, uint32_t serial, const char upstreams[][64], int n_upstreams, bool tcp, uint8_t *out, size_t out_cap) {
	dns_query q;
	if (!parse_query(pkt, pkt_len, &q))
		return 0;
	if (n_upstreams > 0 && !nr_dns_is_local(pkt, pkt_len, zone)) {
		size_t n = nr_dns_forward(pkt, pkt_len, upstreams, n_upstreams, tcp, out, out_cap);
		if (n > 0)
			return n;
		/* SERVFAIL */
		memset(out, 0, 12);
		wr16(out, q.id);
		wr16(out + 2, 0x8000 | (q.flags & 0x0100) | RCODE_SERVFAIL);
		wr16(out + 4, 1);
		size_t nl = encode_name(q.qname, out + 12, out_cap - 12);
		if (nl == 0 || 12 + nl + 4 > out_cap) return 0;
		wr16(out + 12 + nl, q.qtype);
		wr16(out + 12 + nl + 2, q.qclass);
		return 12 + nl + 4;
	}
	return nr_dns_answer(pkt, pkt_len, zone, r, network, serial, out, out_cap);
}
