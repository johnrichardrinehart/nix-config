{
  monstar,
  system,
  runCommandCC,
  writeText,
}:
let
  # Zig 0.16 connects to every address of a host concurrently and does not
  # return the winning connection until the losing connects finish; its
  # cancellation does not interrupt a blocked connect(2). On a host whose IPv6
  # route blackholes SYNs, each fetch from a dual-stack server
  # (deps.files.ghostty.org) waits for the IPv6 SYN timeout while the
  # accepted IPv4 connection idles, the server closes it, and the fetch fails
  # with TlsInitializationFailed. Refusing IPv6 connects in the dependency
  # fetch makes Zig use the IPv4 connection immediately; the fetched content
  # and its hash are unchanged.
  ipv4OnlyConnect = runCommandCC "zig-fetch-ipv4-only-connect" { } ''
    mkdir -p "$out/lib"
    $CC -shared -fPIC -O2 -o "$out/lib/ipv4-only-connect.so" ${writeText "ipv4-only-connect.c" ''
      #define _GNU_SOURCE
      #include <dlfcn.h>
      #include <errno.h>
      #include <stddef.h>
      #include <sys/socket.h>

      int connect(int fd, const struct sockaddr *addr, socklen_t len)
      {
              static int (*real_connect)(int, const struct sockaddr *, socklen_t);

              if (addr != NULL && addr->sa_family == AF_INET6) {
                      errno = ENETUNREACH;
                      return -1;
              }
              if (real_connect == NULL)
                      real_connect = dlsym(RTLD_NEXT, "connect");
              return real_connect(fd, addr, len);
      }
    ''}
  '';
in
monstar.packages.${system}.default.overrideAttrs (old: {
  zigDeps = old.zigDeps.overrideAttrs {
    LD_PRELOAD = "${ipv4OnlyConnect}/lib/ipv4-only-connect.so";
  };
  meta = (old.meta or { }) // {
    mainProgram = "monstar";
  };
  passthru = (old.passthru or { }) // {
    windowClass = "dev.rockorager.monstar";
  };
})
