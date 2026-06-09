use super::*;

#[test]
fn oauth_tokens_serde_roundtrip() {
    let tokens = OAuthTokens {
        access_token: "sk-ant-oat-abc123".to_string(),
        refresh_token: "sk-ant-srt-xyz789".to_string(),
        expires_at: 1_700_000_000_000,
    };
    let json = serde_json::to_string(&tokens).unwrap();
    let back: OAuthTokens = serde_json::from_str(&json).unwrap();
    assert_eq!(back.access_token, "sk-ant-oat-abc123");
    assert_eq!(back.expires_at, 1_700_000_000_000);
}

#[test]
fn oauth_tokens_camel_case() {
    let json = r#"{"accessToken":"tok","refreshToken":"ref","expiresAt":123}"#;
    let tokens: OAuthTokens = serde_json::from_str(json).unwrap();
    assert_eq!(tokens.access_token, "tok");
    assert_eq!(tokens.refresh_token, "ref");
    assert_eq!(tokens.expires_at, 123);
}

#[test]
fn provider_auth_empty() {
    let pa = ProviderAuth::default();
    assert!(pa.accounts.is_none());
    assert!(pa.api_keys.is_none());
    assert!(pa.active_credential.is_none());
}

#[test]
fn provider_auth_with_accounts() {
    let json = r#"{"accounts":[{"label":"work","oauth":{"accessToken":"a","refreshToken":"r","expiresAt":0}}]}"#;
    let pa: ProviderAuth = serde_json::from_str(json).unwrap();
    let accounts = pa.accounts.unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0].label, "work");
}

#[test]
fn google_provider_auth_serde() {
    let json = r#"{
        "accounts": [{"label":"test","oauth":{"accessToken":"ya29.abc","refreshToken":"r","expiresAt":0}}],
        "clientId": "cid",
        "clientSecret": "csec",
        "projectId": "my-project"
    }"#;
    let gpa: GoogleProviderAuth = serde_json::from_str(json).unwrap();
    assert_eq!(gpa.client_id.as_deref(), Some("cid"));
    assert_eq!(gpa.project_id.as_deref(), Some("my-project"));
    assert_eq!(gpa.base.accounts.as_ref().unwrap()[0].label, "test");
}

/// R3: retired auth.json files carrying `endpoint: "antigravity"` (from
/// before the CCA migration) must fail to load with an error naming
/// the unknown field. The user has to re-authenticate.
#[test]
fn google_provider_auth_rejects_retired_endpoint() {
    let json = r#"{
        "clientId": "cid",
        "endpoint": "antigravity",
        "projectId": "proj"
    }"#;
    let err = serde_json::from_str::<GoogleProviderAuth>(json).unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("endpoint"),
        "error should name the retired `endpoint` field, got: {msg}"
    );
}

/// R3 companion: completely unknown fields — not just `endpoint` — also
/// fail to load, so no other retired shape can slip through.
#[test]
fn google_provider_auth_rejects_arbitrary_unknown_field() {
    let json = r#"{
        "clientId": "cid",
        "somethingMadeUp": true
    }"#;
    assert!(serde_json::from_str::<GoogleProviderAuth>(json).is_err());
}

/// R2: `api_keys` is the canonical shape. Multiple keys are returned
/// in the order they were configured — the provider picks the first
/// by default and rotates on failure.
#[test]
fn service_auth_returns_all_api_keys() {
    let mut storage = AuthStorage::new();
    let mut services = HashMap::new();
    let _ = services.insert(
        "brave".to_string(),
        ServiceAuth {
            api_keys: vec!["first".to_string(), "second".to_string()],
        },
    );
    storage.services = Some(services);

    let keys = storage.get_service_api_keys("brave");
    assert_eq!(keys, vec!["first", "second"]);
}

#[test]
fn service_auth_missing_returns_empty() {
    let storage = AuthStorage::new();
    assert!(storage.get_service_api_keys("nonexistent").is_empty());
}

/// R2: retired `apiKey` single field is gone. An auth.json with only
/// `apiKey: "..."` fails to load with an error naming the unknown
/// field. Users must rewrite their auth.json to `apiKeys: ["..."]`.
#[test]
fn service_auth_rejects_retired_api_key_field() {
    let json = r#"{"apiKey":"sk-retired"}"#;
    let err = serde_json::from_str::<ServiceAuth>(json).unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("apiKey") || msg.contains("apiKeys"),
        "error should name the problematic field, got: {msg}"
    );
}

/// R2: `apiKeys: []` is indistinguishable from an unconfigured service
/// and is explicitly rejected.
#[test]
fn service_auth_rejects_empty_api_keys_array() {
    let json = r#"{"apiKeys":[]}"#;
    let err = serde_json::from_str::<ServiceAuth>(json).unwrap_err();
    assert!(err.to_string().contains("apiKeys"));
}

/// R2: a single-element `apiKeys` array loads cleanly — this is the
/// canonical replacement for the old `apiKey` single-field shape.
#[test]
fn service_auth_accepts_single_element_api_keys() {
    let json = r#"{"apiKeys":["sk-one"]}"#;
    let svc: ServiceAuth = serde_json::from_str(json).unwrap();
    assert_eq!(svc.api_keys, vec!["sk-one"]);
}

/// R2: empty-string entries inside `apiKeys` are rejected (they would
/// silently authenticate as anonymous).
#[test]
fn service_auth_rejects_empty_string_entry() {
    let json = r#"{"apiKeys":[""]}"#;
    assert!(serde_json::from_str::<ServiceAuth>(json).is_err());
}

#[test]
fn auth_storage_roundtrip() {
    let mut storage = AuthStorage::new();
    let pa = ProviderAuth {
        api_keys: Some(vec![ApiKeyEntry {
            label: "(default)".to_string(),
            key: "sk-123".to_string(),
        }]),
        ..Default::default()
    };
    storage.set_provider_auth("anthropic", &pa);

    let json = serde_json::to_string(&storage).unwrap();
    let back: AuthStorage = serde_json::from_str(&json).unwrap();
    assert_eq!(back.version, 1);
    let restored = back.get_provider_auth("anthropic").unwrap();
    assert_eq!(restored.api_keys.as_ref().unwrap()[0].key, "sk-123");
}

#[test]
fn auth_storage_get_google_auth() {
    let mut storage = AuthStorage::new();
    let gpa = GoogleProviderAuth {
        project_id: Some("proj".to_string()),
        ..Default::default()
    };
    storage.set_google_auth(&gpa);

    let restored = storage.get_google_auth().unwrap();
    assert_eq!(restored.project_id.as_deref(), Some("proj"));
}

#[test]
fn server_auth_oauth() {
    let tokens = OAuthTokens {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: 999,
    };
    let sa = ServerAuth::from_oauth(&tokens);
    assert!(sa.is_oauth());
    assert_eq!(sa.token(), "tok");
}

#[test]
fn server_auth_api_key() {
    let sa = ServerAuth::from_api_key("sk-123");
    assert!(!sa.is_oauth());
    assert_eq!(sa.token(), "sk-123");
}

#[test]
fn should_refresh_expired() {
    let tokens = OAuthTokens {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: 0,
    };
    assert!(should_refresh(&tokens, 0));
}

#[test]
fn should_refresh_with_buffer() {
    let tokens = OAuthTokens {
        access_token: "tok".to_string(),
        refresh_token: "ref".to_string(),
        expires_at: now_ms() + 60_000, // 60s from now
    };
    // With 120s buffer (120_000ms), should need refresh
    assert!(should_refresh(&tokens, 120_000));
    // With 0 buffer, should NOT need refresh
    assert!(!should_refresh(&tokens, 0));
}

#[test]
fn calculate_expires_at_basic() {
    let before = now_ms();
    let result = calculate_expires_at(3600, 300);
    let after = now_ms();

    // Should be approximately now + (3600 - 300) * 1000 = now + 3_300_000
    assert!(result >= before + 3_300_000);
    assert!(result <= after + 3_300_000);
}

#[test]
fn oauth_token_refresh_response_with_refresh_token() {
    let json = r#"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#;
    let resp: OAuthTokenRefreshResponse = serde_json::from_str(json).unwrap();
    assert_eq!(resp.access_token, "at");
    assert_eq!(resp.refresh_token.as_deref(), Some("rt"));
    assert_eq!(resp.expires_in, 3600);
}

#[test]
fn oauth_token_refresh_response_without_refresh_token() {
    let json = r#"{"access_token":"at","expires_in":3600}"#;
    let resp: OAuthTokenRefreshResponse = serde_json::from_str(json).unwrap();
    assert_eq!(resp.access_token, "at");
    assert!(resp.refresh_token.is_none());
}

#[test]
fn now_ms_is_reasonable() {
    let ms = now_ms();
    // Should be after 2024-01-01 and before 2100-01-01
    assert!(ms > 1_704_067_200_000);
    assert!(ms < 4_102_444_800_000);
}

// ─── ApiKeyEntry ────────────────────────────────────────────────────

#[test]
fn api_key_entry_serde_roundtrip() {
    let entry = ApiKeyEntry {
        label: "work".to_string(),
        key: "sk-abc123".to_string(),
    };
    let json = serde_json::to_string(&entry).unwrap();
    let back: ApiKeyEntry = serde_json::from_str(&json).unwrap();
    assert_eq!(back.label, "work");
    assert_eq!(back.key, "sk-abc123");
}

// ─── ActiveCredential ───────────────────────────────────────────────

#[test]
fn active_credential_oauth_serde() {
    let cred = ActiveCredential::OAuth {
        label: "personal".to_string(),
    };
    let json = serde_json::to_string(&cred).unwrap();
    assert!(json.contains(r#""type":"oauth""#));
    assert!(json.contains(r#""label":"personal""#));

    let back: ActiveCredential = serde_json::from_str(&json).unwrap();
    assert_eq!(
        back,
        ActiveCredential::OAuth {
            label: "personal".to_string()
        }
    );
}

#[test]
fn active_credential_api_key_serde() {
    let cred = ActiveCredential::ApiKey {
        label: "work".to_string(),
    };
    let json = serde_json::to_string(&cred).unwrap();
    assert!(json.contains(r#""type":"apiKey""#));
    assert!(json.contains(r#""label":"work""#));

    let back: ActiveCredential = serde_json::from_str(&json).unwrap();
    assert_eq!(
        back,
        ActiveCredential::ApiKey {
            label: "work".to_string()
        }
    );
}

#[test]
fn active_credential_equality() {
    let a = ActiveCredential::OAuth {
        label: "x".to_string(),
    };
    let b = ActiveCredential::OAuth {
        label: "x".to_string(),
    };
    let c = ActiveCredential::ApiKey {
        label: "x".to_string(),
    };
    assert_eq!(a, b);
    assert_ne!(a, c);
}

// ─── ProviderAuth new fields ────────────────────────────────────────

#[test]
fn provider_auth_with_api_keys() {
    let json =
        r#"{"apiKeys":[{"label":"work","key":"sk-123"},{"label":"personal","key":"sk-456"}]}"#;
    let pa: ProviderAuth = serde_json::from_str(json).unwrap();
    let keys = pa.api_keys.unwrap();
    assert_eq!(keys.len(), 2);
    assert_eq!(keys[0].label, "work");
    assert_eq!(keys[1].key, "sk-456");
}

#[test]
fn provider_auth_with_active_credential() {
    let json = r#"{"activeCredential":{"type":"oauth","label":"main"}}"#;
    let pa: ProviderAuth = serde_json::from_str(json).unwrap();
    assert_eq!(
        pa.active_credential,
        Some(ActiveCredential::OAuth {
            label: "main".to_string()
        })
    );
}

#[test]
fn provider_auth_all_fields_roundtrip() {
    let pa = ProviderAuth {
        accounts: Some(vec![AccountEntry {
            label: "acc1".to_string(),
            oauth: OAuthTokens {
                access_token: "at".to_string(),
                refresh_token: "rt".to_string(),
                expires_at: 999,
            },
        }]),
        api_keys: Some(vec![ApiKeyEntry {
            label: "key1".to_string(),
            key: "sk-x".to_string(),
        }]),
        active_credential: Some(ActiveCredential::OAuth {
            label: "acc1".to_string(),
        }),
    };
    let json = serde_json::to_string(&pa).unwrap();
    let back: ProviderAuth = serde_json::from_str(&json).unwrap();
    assert_eq!(back.accounts.as_ref().unwrap().len(), 1);
    assert_eq!(back.api_keys.as_ref().unwrap().len(), 1);
    assert_eq!(
        back.active_credential,
        Some(ActiveCredential::OAuth {
            label: "acc1".to_string()
        })
    );
}
