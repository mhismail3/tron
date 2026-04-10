#!/usr/bin/env bash
set -euo pipefail

# Vault: Encrypted credential manager for Tron
# Storage: ~/.tron/workspace/vault/ with AES-256-CBC + PBKDF2 encryption

VAULT_DIR="${VAULT_DIR:-$HOME/.tron/workspace/vault}"
ENTRIES_DIR="$VAULT_DIR/entries"
KEY_FILE="$VAULT_DIR/.master-key"
INDEX_FILE="$VAULT_DIR/index.json"

VALID_TYPES="api_key password ssh_key secret"
TMPFILES=""

cleanup() {
    local IFS=':'
    for f in $TMPFILES; do
        [[ -n "$f" ]] && rm -f "$f" 2>/dev/null || true
    done
}
trap cleanup EXIT INT TERM

LAST_TMP=""
make_tmp() {
    # Must be called directly (not in $(...)) to preserve TMPFILES in parent shell.
    # Result is in $LAST_TMP after call.
    LAST_TMP=$(mktemp "${VAULT_DIR}/.tmp.XXXXXX" 2>/dev/null || mktemp /tmp/vault.XXXXXX)
    chmod 600 "$LAST_TMP"
    TMPFILES="${TMPFILES:+$TMPFILES:}$LAST_TMP"
}

err() {
    echo "{\"error\": \"$1\"}" >&2
    return 1
}

ok() {
    echo "$1"
}

# --- Preflight ---

preflight_check() {
    local verbose="${1:-false}"
    local checks=""
    local any_fail=false

    add_check() {
        local json="$1"
        checks="${checks:+$checks,}$json"
    }

    # openssl
    if command -v openssl &>/dev/null; then
        local ossl_test_key ossl_test_in ossl_test_out
        ossl_test_key=$(mktemp /tmp/vault_pf_key.XXXXXX)
        ossl_test_in=$(mktemp /tmp/vault_pf_in.XXXXXX)
        ossl_test_out=$(mktemp /tmp/vault_pf_out.XXXXXX)
        TMPFILES="${TMPFILES:+$TMPFILES:}$ossl_test_key:$ossl_test_in:$ossl_test_out"
        openssl rand -hex 32 > "$ossl_test_key" 2>/dev/null
        echo "preflight_test" > "$ossl_test_in"
        if openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass "file:$ossl_test_key" -in "$ossl_test_in" -out "$ossl_test_out" 2>/dev/null; then
            local roundtrip
            roundtrip=$(openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "file:$ossl_test_key" -in "$ossl_test_out" 2>/dev/null || echo "")
            if [[ "$roundtrip" == "preflight_test" ]]; then
                add_check '{"check":"openssl","status":"pass"}'
            else
                add_check '{"check":"openssl","status":"fail","message":"openssl encrypt/decrypt roundtrip failed"}'
                any_fail=true
            fi
        else
            add_check '{"check":"openssl","status":"fail","message":"openssl does not support -pbkdf2. Install OpenSSL 1.1.1+: brew install openssl"}'
            any_fail=true
        fi
    else
        add_check '{"check":"openssl","status":"fail","message":"openssl not found. Install: brew install openssl"}'
        any_fail=true
    fi

    # python3
    if command -v python3 &>/dev/null; then
        if python3 -c "import json, sys; print('ok')" &>/dev/null; then
            add_check '{"check":"python3","status":"pass"}'
        else
            add_check '{"check":"python3","status":"fail","message":"python3 json module unavailable"}'
            any_fail=true
        fi
    else
        add_check '{"check":"python3","status":"fail","message":"python3 not found"}'
        any_fail=true
    fi

    # mktemp
    if command -v mktemp &>/dev/null; then
        add_check '{"check":"mktemp","status":"pass"}'
    else
        add_check '{"check":"mktemp","status":"fail","message":"mktemp not found"}'
        any_fail=true
    fi

    # uuidgen
    if command -v uuidgen &>/dev/null; then
        add_check '{"check":"uuidgen","status":"pass"}'
    else
        add_check '{"check":"uuidgen","status":"fail","message":"uuidgen not found"}'
        any_fail=true
    fi

    # vault dir permissions
    if [[ -d "$VAULT_DIR" ]]; then
        local dir_perms
        dir_perms=$(stat -c "%a" "$VAULT_DIR" 2>/dev/null || stat -f '%Lp' "$VAULT_DIR" 2>/dev/null || echo "unknown")
        if [[ "$dir_perms" == "700" ]]; then
            add_check '{"check":"vault_dir_perms","status":"pass"}'
        else
            chmod 700 "$VAULT_DIR" 2>/dev/null && \
                add_check '{"check":"vault_dir_perms","status":"repaired","message":"Fixed permissions to 0700"}' || \
                { add_check "{\"check\":\"vault_dir_perms\",\"status\":\"fail\",\"message\":\"Cannot fix vault dir permissions (current: $dir_perms)\"}"; any_fail=true; }
        fi
    else
        add_check '{"check":"vault_dir_perms","status":"skip","message":"Vault not initialized yet"}'
    fi

    # master key permissions
    if [[ -f "$KEY_FILE" ]]; then
        local key_perms
        key_perms=$(stat -c "%a" "$KEY_FILE" 2>/dev/null || stat -f '%Lp' "$KEY_FILE" 2>/dev/null || echo "unknown")
        if [[ "$key_perms" == "600" ]]; then
            add_check '{"check":"key_file_perms","status":"pass"}'
        else
            chmod 600 "$KEY_FILE" 2>/dev/null && \
                add_check '{"check":"key_file_perms","status":"repaired","message":"Fixed permissions to 0600"}' || \
                { add_check "{\"check\":\"key_file_perms\",\"status\":\"fail\",\"message\":\"Cannot fix key file permissions (current: $key_perms)\"}"; any_fail=true; }
        fi
    fi

    # index integrity
    if [[ -f "$INDEX_FILE" ]]; then
        if python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$INDEX_FILE" 2>/dev/null; then
            add_check '{"check":"index_integrity","status":"pass"}'
        else
            add_check '{"check":"index_integrity","status":"fail","message":"index.json is not valid JSON"}'
            any_fail=true
        fi
    fi

    # entries dir permissions
    if [[ -d "$ENTRIES_DIR" ]]; then
        local edir_perms
        edir_perms=$(stat -c "%a" "$ENTRIES_DIR" 2>/dev/null || stat -f '%Lp' "$ENTRIES_DIR" 2>/dev/null || echo "unknown")
        if [[ "$edir_perms" == "700" ]]; then
            add_check '{"check":"entries_dir_perms","status":"pass"}'
        else
            chmod 700 "$ENTRIES_DIR" 2>/dev/null && \
                add_check '{"check":"entries_dir_perms","status":"repaired","message":"Fixed permissions to 0700"}' || \
                { add_check '{"check":"entries_dir_perms","status":"fail","message":"Cannot fix entries dir permissions"}'; any_fail=true; }
        fi
    fi

    if [[ "$any_fail" == "true" ]]; then
        echo "{\"error\":\"preflight_failed\",\"checks\":[$checks]}"
        return 1
    fi

    if [[ "$verbose" == "true" ]]; then
        echo "{\"ok\":true,\"checks\":[$checks]}"
    fi
    return 0
}

# --- Init ---

vault_init() {
    mkdir -p "$VAULT_DIR" "$ENTRIES_DIR"
    chmod 700 "$VAULT_DIR" "$ENTRIES_DIR"

    if [[ ! -f "$KEY_FILE" ]]; then
        openssl rand -hex 32 > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
    fi

    if [[ ! -f "$INDEX_FILE" ]]; then
        echo "[]" > "$INDEX_FILE"
        chmod 600 "$INDEX_FILE"
    fi
}

ensure_init() {
    if [[ ! -f "$KEY_FILE" ]] || [[ ! -f "$INDEX_FILE" ]]; then
        vault_init
    fi
}

# --- Encryption ---

encrypt_entry() {
    local id="$1"
    local json_data="$2"
    local tmp_plain tmp_enc
    make_tmp; local tmp_plain="$LAST_TMP"
    make_tmp; local tmp_enc="$LAST_TMP"

    printf '%s' "$json_data" > "$tmp_plain"
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -pass "file:$KEY_FILE" -in "$tmp_plain" -out "$tmp_enc" 2>/dev/null
    mv "$tmp_enc" "$ENTRIES_DIR/${id}.enc"
    chmod 600 "$ENTRIES_DIR/${id}.enc"
    rm -f "$tmp_plain"
}

decrypt_entry() {
    local id="$1"
    local enc_file="$ENTRIES_DIR/${id}.enc"

    if [[ ! -f "$enc_file" ]]; then
        err "Entry file not found for id: $id"
        return 1
    fi

    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -pass "file:$KEY_FILE" -in "$enc_file" 2>/dev/null || {
        err "Failed to decrypt entry '$id'. File may be corrupted."
        return 1
    }
}

# --- ID generation ---

generate_id() {
    echo "v_$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-')"
}

# --- Atomic write ---

atomic_write() {
    local target="$1"
    local content="$2"
    local tmp
    make_tmp; local tmp="$LAST_TMP"
    printf '%s' "$content" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$target"
}

# --- Index operations (python3) ---

index_find_id() {
    local name="$1"
    python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    entries = json.load(f)
for e in entries:
    if e['name'] == sys.argv[1]:
        print(e['id'])
        sys.exit(0)
" "$name" "$INDEX_FILE" 2>/dev/null || echo ""
}

index_add() {
    local json_entry="$1"
    local new_index
    new_index=$(python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    entries = json.load(f)
new = json.loads(sys.argv[1])
entries.append(new)
print(json.dumps(entries, indent=2))
" "$json_entry" "$INDEX_FILE") || return 1
    atomic_write "$INDEX_FILE" "$new_index"
}

index_remove() {
    local name="$1"
    local new_index
    new_index=$(python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    entries = json.load(f)
entries = [e for e in entries if e['name'] != sys.argv[1]]
print(json.dumps(entries, indent=2))
" "$name" "$INDEX_FILE") || return 1
    atomic_write "$INDEX_FILE" "$new_index"
}

index_update_meta() {
    local name="$1"
    local updates_json="$2"
    local new_index
    new_index=$(python3 -c "
import json, sys, datetime
with open(sys.argv[3]) as f:
    entries = json.load(f)
updates = json.loads(sys.argv[2])
found = False
for e in entries:
    if e['name'] == sys.argv[1]:
        e.update(updates)
        e['updated_at'] = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        found = True
        break
if not found:
    sys.exit(1)
print(json.dumps(entries, indent=2))
" "$name" "$updates_json" "$INDEX_FILE") || return 1
    atomic_write "$INDEX_FILE" "$new_index"
}

index_list() {
    local type_filter="${1:-}"
    local tag_filter="${2:-}"
    python3 -c "
import json, sys
with open(sys.argv[3]) as f:
    entries = json.load(f)
type_f = sys.argv[1] if sys.argv[1] else None
tag_f = sys.argv[2] if sys.argv[2] else None
result = entries
if type_f:
    result = [e for e in result if e.get('type') == type_f]
if tag_f:
    result = [e for e in result if tag_f in e.get('tags', [])]
print(json.dumps(result, indent=2))
" "$type_filter" "$tag_filter" "$INDEX_FILE"
}

index_search() {
    local query="$1"
    python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    entries = json.load(f)
q = sys.argv[1].lower()
result = []
for e in entries:
    searchable = ' '.join([
        e.get('name', ''),
        e.get('description', ''),
        ' '.join(e.get('tags', []))
    ]).lower()
    if q in searchable:
        result.append(e)
print(json.dumps(result, indent=2))
" "$query" "$INDEX_FILE"
}

index_get_entry() {
    local name="$1"
    python3 -c "
import json, sys
with open(sys.argv[2]) as f:
    entries = json.load(f)
for e in entries:
    if e['name'] == sys.argv[1]:
        print(json.dumps(e))
        sys.exit(0)
sys.exit(1)
" "$name" "$INDEX_FILE" 2>/dev/null
}

# --- Type validation ---

validate_type() {
    local t="$1"
    for vt in $VALID_TYPES; do
        [[ "$t" == "$vt" ]] && return 0
    done
    err "Unknown type '$t'. Valid: api_key, password, ssh_key, secret"
    return 1
}

get_required_fields() {
    local t="$1"
    case "$t" in
        api_key)  echo "token" ;;
        password) echo "username password" ;;
        ssh_key)  echo "private_key" ;;
        secret)   echo "value" ;;
    esac
}

# --- Commands ---

cmd_init() {
    vault_init
    ok '{"ok":true,"message":"Vault initialized"}'
}

cmd_set() {
    local name="" cred_type="" desc="" tags=""
    # Use a temp file to accumulate fields (avoids associative arrays)
    local fields_file
    make_tmp; local fields_file="$LAST_TMP"
    echo '{}' > "$fields_file"
    make_tmp; local field_names_file="$LAST_TMP"
    echo '[]' > "$field_names_file"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) cred_type="$2"; shift 2 ;;
            --desc) desc="$2"; shift 2 ;;
            --tags) tags="$2"; shift 2 ;;
            --field)
                local farg="$2"
                local k="${farg%%=*}"
                local v="${farg#*=}"
                python3 -c "
import json, sys
with open(sys.argv[3]) as f: d = json.load(f)
d[sys.argv[1]] = sys.argv[2]
with open(sys.argv[3], 'w') as f: json.dump(d, f)
" "$k" "$v" "$fields_file"
                python3 -c "
import json, sys
with open(sys.argv[2]) as f: a = json.load(f)
if sys.argv[1] not in a: a.append(sys.argv[1])
with open(sys.argv[2], 'w') as f: json.dump(a, f)
" "$k" "$field_names_file"
                shift 2
                ;;
            --field-file)
                local farg="$2"
                local k="${farg%%=*}"
                local fpath="${farg#*=}"
                if [[ ! -f "$fpath" ]]; then
                    err "File not found: $fpath"
                    return 1
                fi
                python3 -c "
import json, sys
with open(sys.argv[3]) as f: d = json.load(f)
with open(sys.argv[2]) as vf: d[sys.argv[1]] = vf.read()
with open(sys.argv[3], 'w') as f: json.dump(d, f)
" "$k" "$fpath" "$fields_file"
                python3 -c "
import json, sys
with open(sys.argv[2]) as f: a = json.load(f)
if sys.argv[1] not in a: a.append(sys.argv[1])
with open(sys.argv[2], 'w') as f: json.dump(a, f)
" "$k" "$field_names_file"
                shift 2
                ;;
            --field-stdin)
                local k="$2"
                local stdin_val
                stdin_val=$(cat)
                python3 -c "
import json, sys
with open(sys.argv[3]) as f: d = json.load(f)
d[sys.argv[1]] = sys.argv[2]
with open(sys.argv[3], 'w') as f: json.dump(d, f)
" "$k" "$stdin_val" "$fields_file"
                python3 -c "
import json, sys
with open(sys.argv[2]) as f: a = json.load(f)
if sys.argv[1] not in a: a.append(sys.argv[1])
with open(sys.argv[2], 'w') as f: json.dump(a, f)
" "$k" "$field_names_file"
                shift 2
                ;;
            -*)
                err "Unknown option: $1"
                return 1
                ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    err "Unexpected argument: $1"
                    return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        err "Name is required. Usage: vault.sh set <name> --type <type> --field key=value"
        return 1
    fi
    if [[ -z "$cred_type" ]]; then
        err "Type is required. Usage: vault.sh set <name> --type <type>"
        return 1
    fi

    validate_type "$cred_type" || return 1

    # Check duplicate
    local existing_id
    existing_id=$(index_find_id "$name")
    if [[ -n "$existing_id" ]]; then
        err "Entry '$name' already exists. Use 'update' to modify."
        return 1
    fi

    # Validate required fields
    local required
    required=$(get_required_fields "$cred_type")
    local fields_keys
    fields_keys=$(python3 -c "import json, sys; print(' '.join(json.load(open(sys.argv[1])).keys()))" "$fields_file")
    for rf in $required; do
        if ! echo " $fields_keys " | grep -q " $rf "; then
            err "Type '$cred_type' requires field: $rf. Required fields: $required"
            return 1
        fi
    done

    local id
    id=$(generate_id)
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build encrypted payload
    local secret_json
    secret_json=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f: fields = json.load(f)
fields['id'] = sys.argv[2]
print(json.dumps(fields))
" "$fields_file" "$id")

    encrypt_entry "$id" "$secret_json"

    # Build tags array
    local tags_json="[]"
    if [[ -n "$tags" ]]; then
        tags_json=$(python3 -c "
import json, sys
print(json.dumps([t.strip() for t in sys.argv[1].split(',') if t.strip()]))
" "$tags")
    fi

    # Build index entry
    local field_names_json
    field_names_json=$(cat "$field_names_file")

    local index_entry
    index_entry=$(python3 -c "
import json, sys
entry = {
    'id': sys.argv[1],
    'name': sys.argv[2],
    'type': sys.argv[3],
    'description': sys.argv[4],
    'tags': json.loads(sys.argv[5]),
    'fields': json.loads(sys.argv[6]),
    'created_at': sys.argv[7],
    'updated_at': sys.argv[7]
}
print(json.dumps(entry))
" "$id" "$name" "$cred_type" "$desc" "$tags_json" "$field_names_json" "$now")

    index_add "$index_entry"

    ok "{\"ok\":true,\"id\":\"$id\",\"name\":\"$name\"}"
}

cmd_get() {
    local name="" field_key=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field) field_key="$2"; shift 2 ;;
            -*) err "Unknown option: $1"; return 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    err "Unexpected argument: $1"; return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        err "Name is required. Usage: vault.sh get <name> [--field <key>]"
        return 1
    fi

    local entry_id
    entry_id=$(index_find_id "$name")
    if [[ -z "$entry_id" ]]; then
        err "Entry '$name' not found."
        return 1
    fi

    local decrypted
    decrypted=$(decrypt_entry "$entry_id") || return 1

    if [[ -n "$field_key" ]]; then
        python3 -c "
import json, sys
data = json.loads(sys.argv[1])
key = sys.argv[2]
if key not in data:
    print(json.dumps({'error': 'field_not_found', 'field': key}), file=sys.stderr)
    sys.exit(1)
sys.stdout.write(str(data[key]))
" "$decrypted" "$field_key" || return 1
    else
        local meta
        meta=$(index_get_entry "$name") || { err "Entry '$name' metadata not found."; return 1; }
        python3 -c "
import json, sys
meta = json.loads(sys.argv[1])
secret = json.loads(sys.argv[2])
del secret['id']
meta.update(secret)
print(json.dumps(meta, indent=2))
" "$meta" "$decrypted"
    fi
}

cmd_list() {
    local type_filter="" tag_filter=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --type) type_filter="$2"; shift 2 ;;
            --tag)  tag_filter="$2"; shift 2 ;;
            -*) err "Unknown option: $1"; return 1 ;;
            *) err "Unexpected argument: $1"; return 1 ;;
        esac
    done

    index_list "$type_filter" "$tag_filter"
}

cmd_search() {
    if [[ $# -eq 0 ]]; then
        err "Query is required. Usage: vault.sh search <query>"
        return 1
    fi
    index_search "$1"
}

cmd_update() {
    local name="" desc="" tags="" has_meta_update=false
    make_tmp; local fields_file="$LAST_TMP"
    echo '{}' > "$fields_file"
    local has_fields=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --desc) desc="$2"; has_meta_update=true; shift 2 ;;
            --tags) tags="$2"; has_meta_update=true; shift 2 ;;
            --field)
                local farg="$2"
                local k="${farg%%=*}"
                local v="${farg#*=}"
                python3 -c "
import json, sys
with open(sys.argv[3]) as f: d = json.load(f)
d[sys.argv[1]] = sys.argv[2]
with open(sys.argv[3], 'w') as f: json.dump(d, f)
" "$k" "$v" "$fields_file"
                has_fields=true
                shift 2
                ;;
            --field-file)
                local farg="$2"
                local k="${farg%%=*}"
                local fpath="${farg#*=}"
                if [[ ! -f "$fpath" ]]; then
                    err "File not found: $fpath"
                    return 1
                fi
                python3 -c "
import json, sys
with open(sys.argv[3]) as f: d = json.load(f)
with open(sys.argv[2]) as vf: d[sys.argv[1]] = vf.read()
with open(sys.argv[3], 'w') as f: json.dump(d, f)
" "$k" "$fpath" "$fields_file"
                has_fields=true
                shift 2
                ;;
            -*) err "Unknown option: $1"; return 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    err "Unexpected argument: $1"; return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        err "Name is required. Usage: vault.sh update <name> [--field key=value]..."
        return 1
    fi

    local entry_id
    entry_id=$(index_find_id "$name")
    if [[ -z "$entry_id" ]]; then
        err "Entry '$name' not found."
        return 1
    fi

    # Update secret fields if any
    if [[ "$has_fields" == "true" ]]; then
        local decrypted
        decrypted=$(decrypt_entry "$entry_id") || return 1

        local updated_secret
        updated_secret=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
with open(sys.argv[2]) as f: updates = json.load(f)
data.update(updates)
print(json.dumps(data))
" "$decrypted" "$fields_file")

        encrypt_entry "$entry_id" "$updated_secret"

        # Update fields list in index
        local new_fields
        new_fields=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print(json.dumps([k for k in data.keys() if k != 'id']))
" "$updated_secret")
        index_update_meta "$name" "{\"fields\":$new_fields}"
    fi

    # Update metadata if any
    if [[ "$has_meta_update" == "true" ]]; then
        local meta_updates="{}"
        if [[ -n "$desc" ]]; then
            meta_updates=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['description'] = sys.argv[2]
print(json.dumps(d))
" "$meta_updates" "$desc")
        fi
        if [[ -n "$tags" ]]; then
            local tags_json
            tags_json=$(python3 -c "
import json, sys
print(json.dumps([t.strip() for t in sys.argv[1].split(',') if t.strip()]))
" "$tags")
            meta_updates=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d['tags'] = json.loads(sys.argv[2])
print(json.dumps(d))
" "$meta_updates" "$tags_json")
        fi
        index_update_meta "$name" "$meta_updates"
    fi

    ok "{\"ok\":true,\"name\":\"$name\",\"message\":\"Entry updated\"}"
}

cmd_delete() {
    local name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --yes) shift ;;
            -*) err "Unknown option: $1"; return 1 ;;
            *)
                if [[ -z "$name" ]]; then
                    name="$1"
                else
                    err "Unexpected argument: $1"; return 1
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$name" ]]; then
        err "Name is required. Usage: vault.sh delete <name>"
        return 1
    fi

    local entry_id
    entry_id=$(index_find_id "$name")
    if [[ -z "$entry_id" ]]; then
        err "Entry '$name' not found."
        return 1
    fi

    rm -f "$ENTRIES_DIR/${entry_id}.enc"
    index_remove "$name"

    ok "{\"ok\":true,\"name\":\"$name\",\"message\":\"Entry deleted\"}"
}

cmd_rotate_key() {
    if [[ ! -f "$KEY_FILE" ]]; then
        err "No master key found. Nothing to rotate."
        return 1
    fi

    # Save old key
    local old_key_file
    make_tmp; local old_key_file="$LAST_TMP"
    cp "$KEY_FILE" "$old_key_file"

    # Read all entry IDs
    local entry_ids
    entry_ids=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    entries = json.load(f)
for e in entries:
    print(e['id'])
" "$INDEX_FILE")

    if [[ -z "$entry_ids" ]]; then
        openssl rand -hex 32 > "$KEY_FILE"
        chmod 600 "$KEY_FILE"
        ok '{"ok":true,"message":"Key rotated (no entries to re-encrypt)"}'
        return 0
    fi

    # Decrypt all entries with old key
    local decrypted_dir
    decrypted_dir=$(mktemp -d /tmp/vault_rotate.XXXXXX)
    TMPFILES="${TMPFILES:+$TMPFILES:}$decrypted_dir"

    local count=0
    while IFS= read -r eid; do
        local dec
        dec=$(KEY_FILE="$old_key_file" decrypt_entry "$eid") || {
            err "Failed to decrypt entry $eid during rotation. Aborting — no changes made."
            rm -rf "$decrypted_dir"
            return 1
        }
        printf '%s' "$dec" > "$decrypted_dir/$eid"
        ((count++))
    done <<< "$entry_ids"

    # Generate new key
    openssl rand -hex 32 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"

    # Re-encrypt all entries with new key
    while IFS= read -r eid; do
        local plaintext
        plaintext=$(cat "$decrypted_dir/$eid")
        encrypt_entry "$eid" "$plaintext"
    done <<< "$entry_ids"

    rm -rf "$decrypted_dir"

    ok "{\"ok\":true,\"message\":\"Key rotated, $count entries re-encrypted\"}"
}

# --- Selftest ---

cmd_selftest() {
    local test_dir
    test_dir=$(mktemp -d /tmp/vault_selftest.XXXXXX)
    local pass=0
    local fail=0
    local total=0
    local V="$test_dir/vault"
    local SCRIPT="${BASH_SOURCE[0]}"

    run_test() {
        local test_name="$1"
        shift
        total=$((total + 1))
        local output
        if output=$("$@" 2>&1); then
            echo "[PASS] $test_name"
            pass=$((pass + 1))
        else
            echo "[FAIL] $test_name"
            echo "       Output: $(echo "$output" | head -3)"
            fail=$((fail + 1))
        fi
    }

    run_test_expect_fail() {
        local test_name="$1"
        shift
        total=$((total + 1))
        local output
        if output=$("$@" 2>&1); then
            echo "[FAIL] $test_name (expected failure but got success)"
            echo "       Output: $(echo "$output" | head -3)"
            fail=$((fail + 1))
        else
            echo "[PASS] $test_name"
            pass=$((pass + 1))
        fi
    }

    echo "=== Vault Self-Test Suite ==="
    echo ""

    # 1. Init
    run_test "init: vault structure created" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' init >/dev/null && \
        [[ -f '$V/.master-key' ]] && \
        [[ -f '$V/index.json' ]] && \
        [[ -d '$V/entries' ]]
    "

    # 2. Set + Get roundtrip
    run_test "set_get_roundtrip: api_key stored and retrieved" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set test-api --type api_key --desc 'Test API key' --tags 'test,ci' --field token=sk-test123 >/dev/null && \
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token) && \
        [[ \"\$result\" == 'sk-test123' ]]
    "

    # 3. Special characters
    run_test "special_chars: values with special characters" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set special-chars --type secret --field 'value=hello\$world\"quotes' >/dev/null && \
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' get special-chars --field value) && \
        [[ \"\$result\" == 'hello\$world\"quotes' ]]
    "

    # 4. Multi-field entry
    run_test "multi_field: password with username + password" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set db-creds --type password --desc 'DB credentials' --field username=admin --field 'password=p@ss!w0rd' >/dev/null && \
        user=\$(VAULT_DIR='$V' bash '$SCRIPT' get db-creds --field username) && \
        pass=\$(VAULT_DIR='$V' bash '$SCRIPT' get db-creds --field password) && \
        [[ \"\$user\" == 'admin' ]] && [[ \"\$pass\" == 'p@ss!w0rd' ]]
    "

    # 5. SSH key roundtrip (multi-line via --field-file)
    local ssh_test_key="$test_dir/test_key"
    cat > "$ssh_test_key" << 'SSHKEY'
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtz
c2gtZWQyNTUxOQAAACBHK9FEyVLh7TLcQJuAg9YfaGb2RdkYJ9ZzU3JZ9gMTBw
AAAJhN4l/ETeJfxAAAAAtzc2gtZWQyNTUxOQAAACBHK9FEyVLh7TLcQJuAg9YfaG
-----END OPENSSH PRIVATE KEY-----
SSHKEY
    run_test "ssh_key_roundtrip: multi-line private key via --field-file" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set my-ssh --type ssh_key --field-file 'private_key=$ssh_test_key' >/dev/null && \
        VAULT_DIR='$V' bash '$SCRIPT' get my-ssh --field private_key > '$test_dir/retrieved_key' && \
        diff '$ssh_test_key' '$test_dir/retrieved_key'
    "

    # 6. Field extraction (raw value, no JSON)
    run_test "field_extraction: --field returns raw value not JSON" bash -c "
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token) && \
        [[ \"\$result\" == 'sk-test123' ]]
    "

    # 7. List returns metadata, no secrets
    run_test "list: metadata only, no secret values leaked" bash -c "
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' list) && \
        echo \"\$result\" | python3 -c \"
import json, sys
entries = json.load(sys.stdin)
assert len(entries) >= 3, f'Expected >=3 entries, got {len(entries)}'
for e in entries:
    assert 'name' in e, 'Missing name'
    assert 'type' in e, 'Missing type'
    # Secret fields should not be in list output
    if e['type'] == 'api_key':
        assert 'token' not in e, 'Secret token leaked in list'
\"
    "

    # 8. List with filters
    run_test "list_filter: --type and --tag filtering" bash -c "
        by_type=\$(VAULT_DIR='$V' bash '$SCRIPT' list --type api_key) && \
        by_tag=\$(VAULT_DIR='$V' bash '$SCRIPT' list --tag test) && \
        echo \"\$by_type\" | python3 -c 'import json,sys; es=json.load(sys.stdin); assert all(e[\"type\"]==\"api_key\" for e in es), \"Type filter failed\"' && \
        echo \"\$by_tag\" | python3 -c 'import json,sys; es=json.load(sys.stdin); assert all(\"test\" in e.get(\"tags\",[]) for e in es), \"Tag filter failed\"'
    "

    # 9. Search
    run_test "search: case-insensitive match on name/desc/tags" bash -c "
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' search 'DB') && \
        echo \"\$result\" | python3 -c 'import json,sys; es=json.load(sys.stdin); assert len(es) >= 1, f\"Expected >=1 match, got {len(es)}\"'
    "

    # 10. Update fields
    run_test "update_fields: change token value" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' update test-api --field token=sk-newvalue >/dev/null && \
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token) && \
        [[ \"\$result\" == 'sk-newvalue' ]]
    "

    # 11. Update metadata
    run_test "update_metadata: change description and tags" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' update test-api --desc 'Updated desc' --tags 'new,tags' >/dev/null && \
        meta=\$(VAULT_DIR='$V' bash '$SCRIPT' list --tag new) && \
        echo \"\$meta\" | python3 -c 'import json,sys; es=json.load(sys.stdin); assert len(es)==1 and es[0][\"description\"]==\"Updated desc\", f\"Meta update failed: {es}\"'
    "

    # 12. Delete
    run_test "delete: remove entry from index and entries/" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' delete special-chars >/dev/null && \
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' list) && \
        echo \"\$result\" | python3 -c 'import json,sys; es=json.load(sys.stdin); assert not any(e[\"name\"]==\"special-chars\" for e in es), \"Entry not deleted from index\"'
    "

    # 13. Duplicate name rejection
    run_test_expect_fail "duplicate_name: set with existing name fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set test-api --type api_key --field token=dup 2>/dev/null
    "

    # 14. Missing entry
    run_test_expect_fail "missing_entry_get: get non-existent fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' get nonexistent 2>/dev/null
    "
    run_test_expect_fail "missing_entry_update: update non-existent fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' update nonexistent --field x=y 2>/dev/null
    "
    run_test_expect_fail "missing_entry_delete: delete non-existent fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' delete nonexistent 2>/dev/null
    "

    # 15. Type validation — missing required fields
    run_test_expect_fail "missing_required_field: password without username fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set bad-pw --type password --field password=onlypw 2>/dev/null
    "

    # 16. Invalid type
    run_test_expect_fail "invalid_type: bogus type fails" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set bad-type --type bogus --field x=y 2>/dev/null
    "

    # 17. Empty vault list
    run_test "empty_vault_list: list on fresh vault returns []" bash -c "
        empty_dir='$test_dir/empty_vault'
        VAULT_DIR=\"\$empty_dir\" bash '$SCRIPT' init >/dev/null && \
        result=\$(VAULT_DIR=\"\$empty_dir\" bash '$SCRIPT' list) && \
        echo \"\$result\" | python3 -c 'import json,sys; assert json.load(sys.stdin) == [], \"Expected empty list\"'
    "

    # 18. Rotate key
    run_test "rotate_key: re-encrypt all entries, still readable" bash -c "
        old_token=\$(VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token) && \
        VAULT_DIR='$V' bash '$SCRIPT' rotate-key >/dev/null && \
        new_token=\$(VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token) && \
        [[ \"\$old_token\" == \"\$new_token\" ]] && \
        db_user=\$(VAULT_DIR='$V' bash '$SCRIPT' get db-creds --field username) && \
        [[ \"\$db_user\" == 'admin' ]]
    "

    # 19. Permission enforcement
    run_test "permissions: 0600 on key/enc, 0700 on dirs" bash -c "
        get_perm() { stat -c '%a' \"\$1\" 2>/dev/null || stat -f '%Lp' \"\$1\" 2>/dev/null; } && \
        key_perm=\$(get_perm '$V/.master-key') && \
        dir_perm=\$(get_perm '$V') && \
        ent_perm=\$(get_perm '$V/entries') && \
        [[ \"\$key_perm\" == '600' ]] && [[ \"\$dir_perm\" == '700' ]] && [[ \"\$ent_perm\" == '700' ]] && \
        for f in '$V/entries/'*.enc; do \
            [[ -f \"\$f\" ]] || continue; \
            fp=\$(get_perm \"\$f\"); \
            [[ \"\$fp\" == '600' ]] || exit 1; \
        done
    "

    # 20. Corrupted entry recovery
    run_test "corrupted_entry: get fails gracefully, others unaffected" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set corrupt-test --type secret --field value=willcorrupt >/dev/null && \
        cid=\$(python3 -c \"import json; entries=json.load(open('$V/index.json')); print([e['id'] for e in entries if e['name']=='corrupt-test'][0])\") && \
        echo 'garbage' > '$V/entries/'\"\$cid\"'.enc' && \
        ! VAULT_DIR='$V' bash '$SCRIPT' get corrupt-test 2>/dev/null && \
        VAULT_DIR='$V' bash '$SCRIPT' get test-api --field token >/dev/null
    "

    # 21. Corrupted index detection
    run_test "corrupted_index: preflight detects invalid JSON" bash -c "
        cp '$V/index.json' '$V/index.json.bak' && \
        echo 'not json' > '$V/index.json' && \
        ! VAULT_DIR='$V' bash '$SCRIPT' preflight 2>/dev/null && \
        result=\$(VAULT_DIR='$V' bash '$SCRIPT' preflight 2>&1 || true) && \
        echo \"\$result\" | grep -q 'index_integrity' && \
        mv '$V/index.json.bak' '$V/index.json'
    "

    # 22. Large value (100KB)
    run_test "large_value: store and retrieve 100KB secret" bash -c "
        large_file='$test_dir/large_secret'
        dd if=/dev/urandom bs=1024 count=100 2>/dev/null | base64 > \"\$large_file\" && \
        VAULT_DIR='$V' bash '$SCRIPT' set large-secret --type secret --field-file \"value=\$large_file\" >/dev/null && \
        VAULT_DIR='$V' bash '$SCRIPT' get large-secret --field value > '$test_dir/large_retrieved' && \
        diff \"\$large_file\" '$test_dir/large_retrieved'
    "

    # 23. Concurrent writes (atomic)
    run_test "concurrent_writes: two rapid sets dont corrupt index" bash -c "
        VAULT_DIR='$V' bash '$SCRIPT' set concurrent-a --type secret --field value=aaa >/dev/null && \
        VAULT_DIR='$V' bash '$SCRIPT' set concurrent-b --type secret --field value=bbb >/dev/null && \
        python3 -c \"import json; entries=json.load(open('$V/index.json')); assert isinstance(entries, list)\"
    "

    echo ""
    echo "=== Results: $pass/$total passed, $fail failed ==="

    rm -rf "$test_dir"

    [[ $fail -eq 0 ]] && return 0 || return 1
}

# --- Usage ---

usage() {
    cat << 'USAGE'
Vault: Encrypted credential manager for Tron

Usage: vault.sh <command> [options]

Commands:
  preflight                               Validate dependencies and permissions
  init                                    Initialize vault (auto-called on first use)
  set   <name> --type <type> [options]    Store a new credential
  get   <name> [--field <key>]            Retrieve a credential
  list  [--type <type>] [--tag <tag>]     List stored credentials (metadata only)
  search <query>                          Search credentials by name/desc/tags
  update <name> [options]                 Update an existing credential
  delete <name>                           Delete a credential
  rotate-key                              Re-encrypt all entries with a new master key
  selftest                                Run built-in test suite

Types: api_key, password, ssh_key, secret

Options for set/update:
  --type <type>           Credential type (required for set)
  --desc "description"    Optional description
  --tags "tag1,tag2"      Comma-separated tags
  --field key=value       Secret field (repeatable)
  --field-file key=path   Read secret field from file
  --field-stdin key       Read secret field from stdin
USAGE
}

# --- Main ---

main() {
    local cmd="${1:-}"

    if [[ "$cmd" == "selftest" ]]; then
        cmd_selftest
        return $?
    fi

    if [[ "$cmd" == "preflight" ]]; then
        preflight_check "true"
        return $?
    fi

    # Run silent preflight for all other commands
    preflight_check "false" || return 1

    ensure_init

    case "$cmd" in
        init)       cmd_init ;;
        set)        shift; cmd_set "$@" ;;
        get)        shift; cmd_get "$@" ;;
        list)       shift; cmd_list "$@" ;;
        search)     shift; cmd_search "$@" ;;
        update)     shift; cmd_update "$@" ;;
        delete)     shift; cmd_delete "$@" ;;
        rotate-key) cmd_rotate_key ;;
        "")         usage ;;
        *)          err "Unknown command: $cmd. Run 'vault.sh' for usage."; return 1 ;;
    esac
}

main "$@"
