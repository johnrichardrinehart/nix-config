#define _POSIX_C_SOURCE 200809L

#include "registry.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_file_all(const char *path) {
	FILE *f = fopen(path, "rb");
	if (!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if (sz < 0 || sz > 1024 * 1024) {
		fclose(f);
		return NULL;
	}
	char *buf = malloc((size_t)sz + 1);
	if (!buf) {
		fclose(f);
		return NULL;
	}
	size_t rd = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	buf[rd] = '\0';
	return buf;
}

int main(int argc, char **argv) {
	if (argc == 3 && strcmp(argv[1], "--keygen-ecdsa") == 0) {
		if (nr_keygen_ecdsa(argv[2]) != NR_OK) {
			fprintf(stderr, "nebula-registry: failed to generate ECDSA key at %s\n", argv[2]);
			return 1;
		}
		return 0;
	}

	if (argc == 5 && strcmp(argv[1], "--self-signed") == 0) {
		if (nr_self_signed(argv[2], argv[3], argv[4]) != NR_OK) {
			fprintf(stderr, "nebula-registry: failed to generate self-signed cert at %s\n", argv[2]);
			return 1;
		}
		return 0;
	}

	if (argc == 3 && strcmp(argv[1], "--config") == 0) {
		char *json = read_file_all(argv[2]);
		if (!json) {
			fprintf(stderr, "nebula-registry: cannot read config %s\n", argv[2]);
			return 1;
		}
		nr_app_config cfg;
		int rc = nr_parse_config(json, &cfg);
		free(json);
		if (rc != NR_OK) {
			fprintf(stderr, "nebula-registry: invalid config %s\n", argv[2]);
			return 1;
		}
		return nr_run_server(&cfg);
	}

	fprintf(stderr, "Usage:\n  %s --config <path>\n  %s --keygen-ecdsa <path>\n", argv[0], argv[0]);
	return 2;
}
