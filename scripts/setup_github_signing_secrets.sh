#!/usr/bin/env bash
set -euo pipefail

REPO="${FOLIO_REPOSITORY:-lukeredmore/folio}"

if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi

echo "=== Folio macOS Code Signing -> GitHub Actions Secrets Setup ==="
echo "Target GitHub Repository: $REPO"
echo ""

# Parse valid code signing identities (SHA-1 + Common Name + exact expiration date + PEM)
IDENTITIES_JSON="$(python3 -c '
import json, re, subprocess

raw = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
all_certs = subprocess.check_output(["security", "find-certificate", "-a", "-Z", "-p"], text=True)

cert_by_sha1 = {}
for block in all_certs.split("SHA-1 hash: ")[1:]:
    sha1 = block.splitlines()[0].strip().upper()
    m = re.search(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", block, re.S)
    if m:
        pem = m.group(0)
        dates = subprocess.check_output(["openssl", "x509", "-noout", "-enddate"], input=pem, text=True).strip()
        end_date = dates.replace("notAfter=", "")
        cert_by_sha1[sha1] = {"expires": end_date, "pem": pem}

items = []
for line in raw.splitlines():
    m = re.match(r"^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+\"([^\"]+)\"", line)
    if m:
        sha1, name = m.group(1).upper(), m.group(2)
        info = cert_by_sha1.get(sha1, {"expires": "unknown", "pem": ""})
        items.append({
            "sha1": sha1,
            "name": name,
            "expires": info["expires"],
            "pem": info["pem"],
        })
print(json.dumps(items))
')"

COUNT="$(python3 -c 'import json, sys; print(len(json.loads(sys.argv[1])))' "$IDENTITIES_JSON")"

if [[ "$COUNT" -eq 0 ]]; then
  cat <<'EOF'
No valid code-signing identities found in your macOS Keychain.

To create one:
  1. Open Xcode -> Settings (⌘,) -> Accounts
  2. Select your Apple ID -> click "Manage Certificates..."
  3. Click "+" in the bottom-left and choose:
     - "Developer ID Application" (if you have a paid $99/yr Apple Developer Program membership), OR
     - "Apple Development" (works with any Apple ID / Personal Team)
  4. Re-run this script: ./scripts/setup_github_signing_secrets.sh
EOF
  exit 1
fi

echo "Found $COUNT valid code-signing identit$([[ "$COUNT" -eq 1 ]] && echo "y" || echo "ies") in Keychain:"
python3 -c '
import json, sys
for idx, item in enumerate(json.loads(sys.argv[1]), 1):
    name, sha1, expires = item["name"], item["sha1"], item["expires"]
    print(f"  [{idx}] {name}")
    print(f"      SHA-1:   {sha1}")
    print(f"      Expires: {expires}")
' "$IDENTITIES_JSON"
echo ""

DEFAULT_CHOICE="$COUNT"
SELECTED_INDEX=$((DEFAULT_CHOICE - 1))
if [[ "$COUNT" -gt 1 ]]; then
  read -r -p "Select identity number [$DEFAULT_CHOICE (newest)]: " CHOICE
  CHOICE="${CHOICE:-$DEFAULT_CHOICE}"
  SELECTED_INDEX=$((CHOICE - 1))
fi

SELECTED_SHA1="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["sha1"])' "$IDENTITIES_JSON" "$SELECTED_INDEX")"
SELECTED_NAME="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["name"])' "$IDENTITIES_JSON" "$SELECTED_INDEX")"
SELECTED_EXPIRES="$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])[int(sys.argv[2])]["expires"])' "$IDENTITIES_JSON" "$SELECTED_INDEX")"

echo "Selected: $SELECTED_NAME"
echo "  SHA-1:   $SELECTED_SHA1"
echo "  Expires: $SELECTED_EXPIRES"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ALL_P12_PATH="$TMP_DIR/all-identities.p12"
SINGLE_P12_PATH="$TMP_DIR/folio-signing-cert.p12"

# Generate a strong random password for the temporary .p12 bundle
P12_PASSWORD="$(openssl rand -base64 24)"

echo ""
echo "Exporting signing identities from Keychain..."
echo "(macOS Keychain will prompt for your login password / Touch ID to allow exporting the private key)"
security export \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -t identities \
  -f pkcs12 \
  -P "$P12_PASSWORD" \
  -o "$ALL_P12_PATH"

# Filter the exported .p12 down to ONLY the single selected certificate + its matching private key (~3 KB)
python3 -c '
import json, re, subprocess, sys

items = json.loads(sys.argv[1])
selected = items[int(sys.argv[2])]
all_p12 = sys.argv[3]
single_p12 = sys.argv[4]
password = sys.argv[5]
tmp_dir = sys.argv[6]

cert_pem = selected["pem"]
cert_pub = subprocess.check_output(["openssl", "x509", "-noout", "-pubkey"], input=cert_pem, text=True).strip()

keys_pem = subprocess.check_output(
    ["openssl", "pkcs12", "-in", all_p12, "-nocerts", "-nodes", "-passin", f"pass:{password}"],
    text=True,
    stderr=subprocess.DEVNULL,
)

matched_key = None
for m in re.finditer(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----", keys_pem, re.S):
    candidate = m.group(0)
    pub = subprocess.check_output(["openssl", "pkey", "-pubout"], input=candidate, text=True, stderr=subprocess.DEVNULL).strip()
    if pub == cert_pub:
        matched_key = candidate
        break

if not matched_key:
    raise SystemExit("Error: Could not find matching private key for selected certificate in exported PKCS12.")

cert_file = f"{tmp_dir}/selected_cert.pem"
key_file = f"{tmp_dir}/selected_key.pem"
with open(cert_file, "w") as f:
    f.write(cert_pem + "\n")
with open(key_file, "w") as f:
    f.write(matched_key + "\n")

subprocess.check_call([
    "openssl", "pkcs12", "-export",
    "-inkey", key_file,
    "-in", cert_file,
    "-name", selected["name"],
    "-passout", f"pass:{password}",
    "-out", single_p12,
])
' "$IDENTITIES_JSON" "$SELECTED_INDEX" "$ALL_P12_PATH" "$SINGLE_P12_PATH" "$P12_PASSWORD" "$TMP_DIR"

SINGLE_SIZE="$(wc -c < "$SINGLE_P12_PATH" | tr -d ' ')"
echo "Packaged single-identity PKCS#12 (${SINGLE_SIZE} bytes)."

P12_BASE64="$(base64 < "$SINGLE_P12_PATH" | tr -d '\n')"

echo "Uploading encrypted secrets to GitHub ($REPO)..."
gh secret set APPLE_CERTIFICATE_P12_BASE64 -R "$REPO" --body "$P12_BASE64"
gh secret set APPLE_CERTIFICATE_PASSWORD -R "$REPO" --body "$P12_PASSWORD"
# Use the 40-char SHA-1 fingerprint so codesign is unambiguous even if multiple certs share the same Common Name
gh secret set APPLE_CODESIGN_IDENTITY -R "$REPO" --body "$SELECTED_SHA1"

echo ""
echo "✅ Uploaded code-signing secrets to $REPO:"
echo "   - APPLE_CERTIFICATE_P12_BASE64"
echo "   - APPLE_CERTIFICATE_PASSWORD"
echo "   - APPLE_CODESIGN_IDENTITY ($SELECTED_SHA1 — $SELECTED_NAME)"

if [[ "$SELECTED_NAME" == Developer\ ID\ Application:* ]]; then
  echo ""
  read -r -p "Would you also like to configure Apple Notarization secrets (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD)? [y/N]: " SETUP_NOTARY
  if [[ "$SETUP_NOTARY" =~ ^[Yy]$ ]]; then
    read -r -p "Apple ID email (e.g. luke.redmore@gmail.com): " APPLE_ID_INPUT
    read -r -p "Apple Team ID (10-char ID from developer.apple.com): " APPLE_TEAM_ID_INPUT
    read -r -s -p "App-Specific Password (from appleid.apple.com): " APPLE_PASS_INPUT
    echo ""
    gh secret set APPLE_ID -R "$REPO" --body "$APPLE_ID_INPUT"
    gh secret set APPLE_TEAM_ID -R "$REPO" --body "$APPLE_TEAM_ID_INPUT"
    gh secret set APPLE_APP_SPECIFIC_PASSWORD -R "$REPO" --body "$APPLE_PASS_INPUT"
    echo "✅ Uploaded notarization secrets (APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD)."
  fi
fi

echo ""
echo "Done! Temporary .p12 files have been securely wiped."
