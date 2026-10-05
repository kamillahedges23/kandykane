# App Store Connect API auth.
# Reads credentials from environment variables (set them in the Claude Code
# environment settings so they survive container recycling):
#   ASC_KEY_ID       10-character key ID from App Store Connect
#   ASC_ISSUER_ID    issuer UUID from App Store Connect
#   ASC_PRIVATE_KEY  contents of the .p8 file (raw PEM, or base64 of it)
# Falls back to ~/.app-store-connect/AuthKey_<id>.p8 if ASC_PRIVATE_KEY is unset.
# Usage: source ~/.app-store-connect/setup.sh; asc-bundles

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
  echo "App Store Connect: set ASC_KEY_ID and ASC_ISSUER_ID in your environment settings." >&2
  return 1 2>/dev/null || exit 1
fi
if [ -z "$ASC_PRIVATE_KEY" ] && [ ! -f "$HOME/.app-store-connect/AuthKey_${ASC_KEY_ID}.p8" ]; then
  echo "App Store Connect: set ASC_PRIVATE_KEY in your environment settings." >&2
  return 1 2>/dev/null || exit 1
fi

asc_token() {
  node -e '
const fs=require("fs"),os=require("os"),c=require("crypto"),e=process.env;
let pem=e.ASC_PRIVATE_KEY||fs.readFileSync(os.homedir()+"/.app-store-connect/AuthKey_"+e.ASC_KEY_ID+".p8","utf8");
if(!pem.includes("BEGIN")) pem=Buffer.from(pem,"base64").toString("utf8");
pem=pem.replace(/\\n/g,"\n");
const b=s=>Buffer.from(s).toString("base64url"),n=Math.floor(Date.now()/1000);
const u=b(JSON.stringify({alg:"ES256",kid:e.ASC_KEY_ID,typ:"JWT"}))+"."+b(JSON.stringify({iss:e.ASC_ISSUER_ID,aud:"appstoreconnect-v1",iat:n,exp:n+600}));
process.stdout.write(u+"."+c.sign("sha256",Buffer.from(u),{key:pem,dsaEncoding:"ieee-p1363"}).toString("base64url"))'
}
# asc_api <path> [curl args...]   e.g. asc_api /v1/apps
asc_api() { local p="$1"; shift; curl -sS -H "Authorization: Bearer $(asc_token)" "https://api.appstoreconnect.apple.com$p" "$@"; }
asc-bundles() { asc_api "/v1/bundleIds?limit=200"; }
