# KeePassXC whose passkeys-get can sign a client data hash it is given, which
# signing in through keepassxc-hybrid needs: in the hybrid transport the
# browser builds the client data and sends only its hash.
{ keepassxc, keepassxc-hybrid }:

keepassxc.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    "${keepassxc-hybrid}/patches/keepassxc-passkeys-client-data-hash.patch"
  ];
})
