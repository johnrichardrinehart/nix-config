/*
 * pam_biometrics: run a helper that decides the biometric factor.
 *
 * Usage: auth [success=ok ignore=ignore default=die] pam_biometrics.so HELPER [ARGS...]
 *
 * The module runs HELPER with PAM_USER, PAM_SERVICE, and PAM_TYPE in the
 * environment. Each line that HELPER writes to standard output goes to the
 * application as an information message. The exit status of HELPER gives the
 * result:
 *
 *   0       A biometric factor matched.          PAM_SUCCESS
 *   10      A biometric factor did not match.    PAM_AUTH_ERR
 *   other   No decision.                         PAM_IGNORE
 *
 * A crash of HELPER gives no decision, so a fault cannot lock the user out.
 * The password stays required in the rest of the stack.
 */

#define _GNU_SOURCE
#define PAM_SM_AUTH

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

#include <security/pam_ext.h>
#include <security/pam_modules.h>

enum { HELPER_MATCH = 0, HELPER_MISMATCH = 10 };

static char *env_entry(const char *name, const char *value)
{
	char *entry = NULL;

	if (asprintf(&entry, "%s=%s", name, value ? value : "") < 0)
		return NULL;
	return entry;
}

static void run_helper(int out, const char *user, const char *service, int argc,
		       const char **argv)
{
	char *helper_argv[argc + 1];
	char *envp[] = {
		env_entry("PAM_USER", user),
		env_entry("PAM_SERVICE", service),
		"PAM_TYPE=auth",
		NULL,
	};
	int null = open("/dev/null", O_RDWR);

	if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(out, STDOUT_FILENO) < 0 ||
	    dup2(null, STDERR_FILENO) < 0)
		_exit(127);
	for (int i = 0; i < argc; i++)
		helper_argv[i] = (char *)argv[i];
	helper_argv[argc] = NULL;
	execve(argv[0], helper_argv, envp);
	_exit(127);
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
				   const char **argv)
{
	const char *user = NULL;
	const void *service = NULL;
	char *line = NULL;
	size_t size = 0;
	int pipefd[2];
	int status;
	FILE *output;
	pid_t pid;

	(void)flags;

	if (argc < 1 || argv[0][0] != '/') {
		pam_syslog(pamh, LOG_ERR, "expected an absolute helper path");
		return PAM_IGNORE;
	}
	if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
		return PAM_IGNORE;
	pam_get_item(pamh, PAM_SERVICE, &service);

	if (pipe2(pipefd, O_CLOEXEC) < 0) {
		pam_syslog(pamh, LOG_ERR, "pipe: %m");
		return PAM_IGNORE;
	}

	pid = fork();
	if (pid < 0) {
		pam_syslog(pamh, LOG_ERR, "fork: %m");
		close(pipefd[0]);
		close(pipefd[1]);
		return PAM_IGNORE;
	}
	if (pid == 0)
		run_helper(pipefd[1], user, service, argc, argv);

	close(pipefd[1]);
	output = fdopen(pipefd[0], "r");
	if (output == NULL) {
		close(pipefd[0]);
	} else {
		ssize_t length;

		while ((length = getline(&line, &size, output)) > 0) {
			if (line[length - 1] == '\n')
				line[length - 1] = '\0';
			if (line[0] != '\0')
				pam_info(pamh, "%s", line);
		}
		free(line);
		fclose(output);
	}

	while (waitpid(pid, &status, 0) < 0) {
		if (errno != EINTR) {
			pam_syslog(pamh, LOG_ERR, "waitpid: %m");
			return PAM_IGNORE;
		}
	}

	if (WIFEXITED(status)) {
		switch (WEXITSTATUS(status)) {
		case HELPER_MATCH:
			return PAM_SUCCESS;
		case HELPER_MISMATCH:
			return PAM_AUTH_ERR;
		}
	}
	pam_syslog(pamh, LOG_WARNING, "helper gave no decision (status %d)", status);
	return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc,
			      const char **argv)
{
	(void)pamh;
	(void)flags;
	(void)argc;
	(void)argv;
	return PAM_IGNORE;
}
