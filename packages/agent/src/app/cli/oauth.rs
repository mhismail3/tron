//! Bearer-token rotation and contributor OAuth commands.

use super::*;

pub(super) fn rotate_bearer_token_cli() -> Result<()> {
    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    let token = crate::app::lifecycle::onboarding::rotate_bearer_token(&path)
        .with_context(|| format!("Failed to rotate bearer token at {}", path.display()))?;
    eprintln!("Bearer token rotated. All paired iOS devices must re-pair with the new token.");
    println!("{token}");
    Ok(())
}

pub(super) fn begin_oauth_cli(provider: &str) -> Result<()> {
    ensure!(
        matches!(provider, "anthropic" | "openai-codex"),
        "Contributor OAuth supports anthropic and openai-codex"
    );
    let path = crate::app::lifecycle::onboarding::bearer_token_path();
    let flow = crate::domains::auth::oauth::flows::prepare_oauth_flow_with_state(provider, &path)
        .context("Failed to prepare contributor OAuth")?
        .context("Contributor OAuth supports anthropic and openai-codex")?;
    let state = flow
        .state
        .context("Contributor OAuth flow did not include callback state")?;
    println!(
        "{}\t{}\t{}\t{}",
        flow.verifier, state, flow.auth_url, flow.redirect_uri
    );
    Ok(())
}

pub(super) async fn complete_oauth_cli() -> Result<()> {
    let stdin = std::io::stdin();
    complete_oauth_from_reader_at(
        &crate::app::lifecycle::onboarding::bearer_token_path(),
        stdin.lock(),
    )
    .await
}

pub(super) fn read_nul_fields<const N: usize>(
    mut reader: impl Read,
    description: &str,
) -> Result<[String; N]> {
    let mut raw = Vec::new();
    reader
        .read_to_end(&mut raw)
        .with_context(|| format!("Failed to read {description} from stdin"))?;
    let fields = (|| -> Result<[String; N]> {
        let payload = raw
            .strip_suffix(&[0])
            .with_context(|| format!("{description} input must end with a NUL delimiter"))?;
        let decoded = payload
            .split(|byte| *byte == 0)
            .map(|field| {
                String::from_utf8(field.to_vec())
                    .with_context(|| format!("{description} fields must be valid UTF-8"))
            })
            .collect::<Result<Vec<_>>>()?;
        decoded.try_into().map_err(|values: Vec<String>| {
            anyhow::anyhow!(
                "{description} input must contain exactly {N} NUL-delimited fields; got {}",
                values.len()
            )
        })
    })();
    raw.fill(0);
    fields
}

pub(super) fn read_oauth_completion(reader: impl Read) -> Result<OAuthCompletionInput> {
    let [
        provider,
        label,
        code,
        verifier,
        expected_state,
        completion_kind,
        returned_state,
    ] = read_nul_fields(reader, "OAuth completion")?;
    Ok(OAuthCompletionInput {
        provider,
        label,
        code,
        verifier,
        expected_state,
        completion_kind,
        returned_state,
    })
}

pub(super) fn auth_storage_is_initialized(path: &Path) -> Result<bool> {
    let initialized = crate::domains::auth::oauth::contributor_auth_storage_is_initialized(path)
        .with_context(|| format!("Failed to load auth storage at {}", path.display()))?;
    Ok(initialized)
}

pub(super) fn save_oauth_tokens_at(
    path: &Path,
    provider: &str,
    label: &str,
    tokens: &crate::domains::auth::credentials::OAuthTokens,
) -> Result<()> {
    ensure!(
        crate::domains::auth::oauth::save_contributor_oauth_tokens(path, provider, label, tokens,)
            .with_context(|| format!(
                "Failed to persist OAuth credentials at {}",
                path.display()
            ))?,
        "Auth storage is not initialized; start the Tron server once and retry login"
    );
    Ok(())
}

pub(super) async fn complete_oauth_from_reader_at(path: &Path, reader: impl Read) -> Result<()> {
    let input = read_oauth_completion(reader)?;
    validate_oauth_completion(&input)?;
    ensure!(
        auth_storage_is_initialized(path)?,
        "Auth storage is not initialized; start the Tron server once and retry login"
    );

    let tokens = crate::domains::auth::oauth::flows::exchange_oauth_code(
        &input.provider,
        path,
        &input.code,
        &input.verifier,
        Some(&input.expected_state),
    )
    .await
    .context("OAuth authorization code exchange failed")?
    .context("Contributor OAuth supports anthropic and openai-codex")?;
    let expires_at = tokens.expires_at;
    save_oauth_tokens_at(path, &input.provider, &input.label, &tokens)?;
    println!("{expires_at}");
    Ok(())
}

pub(super) fn validate_oauth_completion(input: &OAuthCompletionInput) -> Result<()> {
    ensure!(
        matches!(input.provider.as_str(), "anthropic" | "openai-codex"),
        "Contributor OAuth supports anthropic and openai-codex"
    );
    ensure!(
        !input.label.trim().is_empty(),
        "OAuth label must not be empty"
    );
    ensure!(
        !input.code.trim().is_empty(),
        "OAuth authorization code must not be empty"
    );
    ensure!(
        !input.verifier.trim().is_empty(),
        "OAuth verifier must not be empty"
    );
    ensure!(
        !input.expected_state.trim().is_empty(),
        "OAuth expected state must not be empty"
    );
    match input.completion_kind.as_str() {
        "callback" => ensure!(
            input.returned_state == input.expected_state,
            "OAuth state parameter mismatch; refusing authorization code exchange"
        ),
        "manual" => {
            ensure!(
                input.provider == "anthropic",
                "Manual OAuth completion is supported only for Anthropic"
            );
            ensure!(
                input.returned_state.is_empty(),
                "Manual OAuth completion must not synthesize callback state"
            );
        }
        _ => bail!("OAuth completion kind must be callback or manual"),
    }
    Ok(())
}
