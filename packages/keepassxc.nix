# KeePassXC with the keepassxc-hybrid patches:
# - passkeys-get can sign a client data hash it is given, which signing in
#   through keepassxc-hybrid needs (the hybrid transport's browser sends only
#   the hash of the client data it built);
# - "Add to selected entry" puts a new passkey into the entry selected in
#   KeePassXC's window, and keeping an entry's existing passkey cancels the
#   registration instead of reporting success for a passkey stored nowhere.
{ keepassxc, keepassxc-hybrid }:

keepassxc.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [
    "${keepassxc-hybrid}/patches/keepassxc-passkeys-client-data-hash.patch"
    "${keepassxc-hybrid}/patches/keepassxc-passkeys-add-to-selected-entry.patch"
  ];
})
