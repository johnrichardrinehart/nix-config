#!/usr/bin/env bash
# Upload files as GitHub user-attachments with curl only.
#
# Usage: gh-upload-script [-r <owner>/<repo>] <path>...
#   stdout: one line per path, "<path as given>\t<https://github.com/user-attachments/assets/...>"
#   -r: repository the attachments belong to (they inherit its visibility);
#       default: the GitHub `origin` of the git repository in the current directory.
#
# Logs in to github.com as GH_UPLOAD_LOGIN (user name or email) with GH_UPLOAD_PASSWORD
# and the authenticator-app 2FA seed GH_UPLOAD_TOTP_SECRET (base32), uploads every path
# in that one session, then logs out. The caller supplies the three variables; keep them
# out of the shell's environment, e.g. by setting them only for this one command.
#
# Runs in quick succession work: each run records the 30 s authenticator step it used in
# $XDG_STATE_HOME/gh-upload-script (default ~/.local/state), and the next run uses a later step.
#
# Flow (captured from the web editor over CDP):
#   login  GET /login -> POST /session -> GET /sessions/two-factor/app -> POST TOTP code
#   0. GET a repo page with a comment editor -> CSRF from input.js-data-upload-policy-url-csrf,
#      repository id from data-upload-repository-id
#   per file:
#   1. POST /upload/policies/assets -> asset href + signed S3 form + finalize URL/token   (201)
#   2. POST <S3 upload_url>         -> returned form fields in order, file last            (204)
#   3. PUT  /upload/assets/<id>     -> authenticity_token=asset_upload_authenticity_token  (200)
#   logout POST /logout
set -euo pipefail
die() { echo "gh-upload-script: $*" >&2; exit 1; }

repo=
if [[ ${1:-} == -r ]]; then repo=${2:?-r needs <owner>/<repo>}; shift 2; fi
[[ ${1:-} == -- ]] && shift
(($#)) || { echo "usage: gh-upload-script [-r <owner>/<repo>] <path>..." >&2; exit 2; }
if [[ -z $repo ]]; then
  origin=$(git remote get-url origin 2>/dev/null) || die "not in a git repository with an origin; pass -r <owner>/<repo>"
  [[ $origin =~ github[^:/]*[:/]+([^/]+/[^/]+)$ ]] || die "origin is not a GitHub remote: $origin"
  repo=${BASH_REMATCH[1]%.git}
fi
[[ $repo =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]] || die "bad repository: $repo"
for p; do
  [[ -f $p && -r $p ]] || die "not a readable file: $p"
  [[ $p != *$'\t'* && $p != *$'\n'* ]] || die "path contains a tab or newline: $p"
done

for v in GH_UPLOAD_LOGIN GH_UPLOAD_PASSWORD GH_UPLOAD_TOTP_SECRET; do
  [[ -n ${!v:-} ]] || die "$v is not set"
done
login=$GH_UPLOAD_LOGIN

d=$(mktemp -d); chmod 700 "$d"; jar=$d/jar
gh() { curl -sS -b "$jar" -c "$jar" "$@"; }

# py form <html> <action-regex> [exclude...]: hidden/text inputs of the first matching form as name=value lines
# py otp-field <html>: name of the one-time-code input; py totp <step>: the code of a 30 s time step
py() {
  python3 - "$@" <<'PY'
import base64, hashlib, hmac, html, os, re, struct, sys, time
mode = sys.argv[1]
if mode == "totp":
    s = os.environ["GH_UPLOAD_TOTP_SECRET"].replace(" ", "").upper()
    key = base64.b32decode(s + "=" * (-len(s) % 8))
    h = hmac.new(key, struct.pack(">Q", int(sys.argv[2])), hashlib.sha1).digest()
    o = h[-1] & 15
    print(f"{(struct.unpack('>I', h[o:o + 4])[0] & 0x7FFFFFFF) % 1000000:06d}")
    sys.exit()
page = open(sys.argv[2], encoding="utf-8", errors="replace").read()
attr = lambda tag, name: (m := re.search(rf'\b{name}="([^"]*)"', tag)) and html.unescape(m.group(1))
if mode == "otp-field":
    for tag in re.findall(r"<input[^>]*>", page):
        if attr(tag, "autocomplete") == "one-time-code" or re.fullmatch(r"(app_)?otp", attr(tag, "name") or ""):
            print(attr(tag, "name")); sys.exit()
    sys.exit(1)
if mode == "form":
    rx, exclude = re.compile(sys.argv[3]), set(sys.argv[4:])
    for form in re.findall(r"<form\b.*?</form>", page, re.S):
        if rx.search(attr(form[:form.index(">")], "action") or ""):
            for tag in re.findall(r"<input[^>]*>", form):
                name = attr(tag, "name")
                if name and name not in exclude and attr(tag, "type") in (None, "hidden", "text"):
                    print(f"{name}={attr(tag, 'value') or ''}")
            sys.exit()
    sys.exit(1)
PY
}
form_args() { local kv; while IFS= read -r kv; do args+=(--data-urlencode "$kv"); done; }

# --- TOTP time step ---
# GitHub accepts each authenticator code once: after a login, it refuses the code of that 30 s
# step and of every earlier step. It also accepts the code of the next step. So runs on this
# machine record the last step they used, and a quick re-run uses the next step. A lock keeps
# two runs from picking the same step.
state=${XDG_STATE_HOME:-$HOME/.local/state}/gh-upload-script
mkdir -p "$state"
account=$state/$(printf %s "$login" | tr '[:upper:]' '[:lower:]' | sha256sum | cut -c1-16)
lock=$account.lock
until mkdir "$lock" 2>/dev/null; do
  holder=$(cat "$lock/pid" 2>/dev/null || true)
  if [[ -n $holder ]] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  sleep 1
done
echo $$ >"$lock/pid"
unlock() { [[ $(cat "$lock/pid" 2>/dev/null) != "$$" ]] || rm -rf "$lock"; }

# pick_step: print the step to use; wait first if the next unused step is too far ahead.
pick_step() {
  local now last step wait
  now=$(($(date +%s) / 30))
  last=$(cat "$account.step" 2>/dev/null || echo 0)
  step=$((last >= now ? last + 1 : now))
  if ((step > now + 1)); then
    wait=$(((step - 1) * 30 - $(date +%s)))
    echo "gh-upload-script: an earlier run used the authenticator code of step $last; waiting ${wait}s until GitHub accepts the code of step $step" >&2
    sleep "$wait"
  fi
  echo "$step"
}

logout() {
  unlock
  if gh -o "$d/lo.html" https://github.com/logout && grep -q 'action="/logout"' "$d/lo.html"; then
    args=(); form_args < <(py form "$d/lo.html" '^/logout$')
    gh -o /dev/null "${args[@]}" https://github.com/logout || true
  fi
  rm -rf "$d"
}
trap logout EXIT

# --- login ---
# A rejected authenticator code means that a newer code was used elsewhere (a browser, another
# tool, or a run without this machine's record). GitHub does not take a second code in the same
# sign-in, so each attempt starts a new sign-in with the next step.
for attempt in 1 2 3; do
  : >"$jar"
  gh -o "$d/login.html" https://github.com/login
  args=(); form_args < <(py form "$d/login.html" '^/session$' login password) || die "no login form"
  args+=(--data-urlencode "login=$login" --data-urlencode "password=$GH_UPLOAD_PASSWORD")
  url=$(gh -L -o "$d/after.html" -w '%{url_effective}' "${args[@]}" https://github.com/session)
  [[ $url == */sessions/two-factor* ]] || break
  url=$(gh -L -o "$d/2fa.html" -w '%{url_effective}' https://github.com/sessions/two-factor/app)
  field=$(py otp-field "$d/2fa.html") || die "no authenticator-app 2FA form at $url (app 2FA not enabled?)"
  args=(); form_args < <(py form "$d/2fa.html" '^/sessions/two-factor' "$field") || die "no 2FA form"
  step=$(pick_step)
  args+=(--data-urlencode "$field=$(py totp "$step")")
  url=$(gh -L -o "$d/after.html" -w '%{url_effective}' "${args[@]}" https://github.com/sessions/two-factor)
  echo "$step" >"$account.step"
  [[ $url == */sessions/two-factor* ]] || break
  echo "gh-upload-script: GitHub rejected the authenticator code of step $step (attempt $attempt of 3)" >&2
done
[[ $url != */sessions/two-factor* ]] || die "GitHub rejected 3 authenticator codes. GitHub accepts each code once and refuses codes older than the newest one used. Check GH_UPLOAD_TOTP_SECRET and the clock of this machine."
case $url in
  */sessions/verified-device*) die "GitHub wants an emailed device-verification code; not scriptable" ;;
  */login*|*/session|*/sessions/two-factor*) die "login rejected (at $url)" ;;
esac
user=$(awk -F'\t' '$6 == "dotcom_user" {print $7}' "$jar")
grep -q $'\tuser_session\t' "$jar" && [[ -n $user ]] || die "no session after login (at $url)"
[[ $login == *@* || $(tr '[:upper:]' '[:lower:]' <<<"$user") == $(tr '[:upper:]' '[:lower:]' <<<"$login") ]] || die "logged in as $user, not $login"
unlock

# --- upload token: any repo page that renders the classic comment editor ---
csrf= repo_id=
for p in releases/new issues/1; do
  url=$(gh -L -o "$d/page.html" -w '%{url_effective}' "https://github.com/$repo/$p")
  [[ $url == */sso* ]] && die "org requires SAML SSO re-auth ($url)"
  csrf=$(grep -o '<input[^>]*js-data-upload-policy-url-csrf[^>]*>' "$d/page.html" | head -1 | sed -n 's/.*value="\([^"]*\)".*/\1/p')
  repo_id=$(grep -o 'data-upload-repository-id="[0-9]*"' "$d/page.html" | head -1 | grep -o '[0-9]\+' || true)
  [[ -n $csrf && -n $repo_id ]] && break
done
[[ -n $csrf && -n $repo_id ]] || die "no upload token for $repo (no access, or no releases/new or issues/1 page)"
xhr=(-H 'Accept: application/json' -H 'X-Requested-With: XMLHttpRequest' -H 'Origin: https://github.com' -H "Referer: $url")

# --- uploads ---
for p; do
  name=$(basename "$p"); size=$(wc -c <"$p" | tr -d " "); ctype=$(file -b --mime-type "$p")
  gh --fail-with-body "${xhr[@]}" -o "$d/policy.json" https://github.com/upload/policies/assets \
    -F "name=$name" -F "size=$size" -F "content_type=$ctype" -F "authenticity_token=$csrf" -F "repository_id=$repo_id" \
    || die "upload policy rejected for $p: $(head -c 300 "$d/policy.json")"
  s3=(); while IFS= read -r kv; do s3+=(--form-string "$kv"); done < <(jq -r '.form | to_entries[] | "\(.key)=\(.value)"' "$d/policy.json")
  curl -sS --fail-with-body -o /dev/null "$(jq -r .upload_url "$d/policy.json")" "${s3[@]}" -F "file=@$p;type=$ctype;filename=$name"
  gh --fail-with-body -X PUT "${xhr[@]}" -o "$d/final.json" "https://github.com$(jq -r .asset_upload_url "$d/policy.json")" \
    -F "authenticity_token=$(jq -r .asset_upload_authenticity_token "$d/policy.json")"
  printf '%s\t%s\n' "$p" "$(jq -er .href "$d/final.json")"
done
