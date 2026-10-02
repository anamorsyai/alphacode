use super::{Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

const DEFAULT_TIMEOUT: u64 = 300;

pub struct AmassTool;

#[derive(Deserialize)]
struct AmassInput {
    domain: String,
    #[serde(default)]
    active: bool,
    #[serde(default)]
    passive: bool,
    #[serde(default)]
    timeout: Option<u64>,
    #[serde(default)]
    json_output: bool,
    #[serde(default)]
    silent: bool,
    #[serde(default)]
    brute: bool,
    #[serde(default)]
    wordlist: Option<String>,
}

#[async_trait]
impl Tool for AmassTool {
    fn name(&self) -> &str {
        "amass"
    }

    fn description(&self) -> &str {
        "In-depth subdomain enumeration (OWASP). More comprehensive than subfinder but slower. Use when you need maximum subdomain discovery."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["domain"],
            "properties": {
                "intent": super::intent_schema_property(),
                "domain": {
                    "type": "string",
                    "description": "Target domain to enumerate."
                },
                "active": {
                    "type": "boolean",
                    "description": "Active enumeration (slower, more results). Default: false."
                },
                "passive": {
                    "type": "boolean",
                    "description": "Passive only (faster). Default: true."
                },
                "brute": {
                    "type": "boolean",
                    "description": "Enable brute forcing. Default: false."
                },
                "timeout": {
                    "type": "integer",
                    "description": "Timeout in minutes. Default: 5."
                },
                "silent": {
                    "type": "boolean",
                    "description": "Silent mode. Default: false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, _ctx: ToolContext) -> Result<ToolOutput> {
        let params: AmassInput = normalize_amass_input(&input)?;
        let args = build_args(&params)?;

        let output = super::recon_common::run_bounded(
            "amass",
            &args,
            super::recon_common::DEFAULT_TOOL_TIMEOUT,
        )
        .await
        .map_err(|e| {
            if e.starts_with("failed to run") {
                anyhow::anyhow!("{e}. {}", super::recon_common::install_hint("amass"))
            } else {
                anyhow::anyhow!("{e}")
            }
        })?;

        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).trim().to_string();

        if !output.status.success() {
            let detail = if stderr.is_empty() {
                if stdout.is_empty() {
                    "no output (binary exited non-zero with empty stderr)".to_string()
                } else {
                    crate::alphacode_core::util::truncate_str(&stdout, 500).to_string()
                }
            } else {
                crate::alphacode_core::util::truncate_str(&stderr, 500).to_string()
            };
            return Err(anyhow::anyhow!("amass exited with error: {detail}"));
        }

        let (lines, total, truncated) = super::recon_common::parse_lines(&output.stdout);

        let mut result = format!(
            "amass found {} subdomains for {}:\n\n",
            total, params.domain
        );
        for line in &lines {
            result.push_str(line);
            result.push('\n');
        }
        result.push_str(&super::recon_common::truncation_notice(lines.len(), total));

        let mut metadata = HashMap::new();
        metadata.insert("domain".to_string(), json!(params.domain));
        metadata.insert("count".to_string(), json!(lines.len()));
        metadata.insert("total_found".to_string(), json!(total));
        metadata.insert("truncated".to_string(), json!(truncated));
        metadata.insert("active".to_string(), json!(params.active));

        Ok(ToolOutput::new(result)
            .with_title(format!("amass: {total} subdomains"))
            .with_metadata(json!(metadata)))
    }
}

impl AmassTool {
    pub fn new() -> Self {
        Self
    }
}

fn normalize_amass_input(input: &Value) -> Result<AmassInput> {
    if let Ok(params) = serde_json::from_value::<AmassInput>(input.clone()) {
        return Ok(params);
    }
    let domain = super::coerce_host_arg(input, "amass", "domain")?;
    // Remaining options are optional; a payload that was a bare host string has
    // no object to read them from, so an empty map stands in for the defaults.
    let obj = input.as_object().cloned().unwrap_or_default();
    Ok(AmassInput {
        domain: domain.to_string(),
        active: obj.get("active").and_then(|v| v.as_bool()).unwrap_or(false),
        passive: obj.get("passive").and_then(|v| v.as_bool()).unwrap_or(true),
        timeout: obj.get("timeout").and_then(|v| v.as_u64()),
        json_output: obj.get("json").and_then(|v| v.as_bool()).unwrap_or(false),
        silent: obj.get("silent").and_then(|v| v.as_bool()).unwrap_or(false),
        brute: obj.get("brute").and_then(|v| v.as_bool()).unwrap_or(false),
        wordlist: obj
            .get("wordlist")
            .and_then(|v| v.as_str())
            .map(String::from),
    })
}

fn build_args(params: &AmassInput) -> Result<Vec<String>> {
    let mut args = Vec::new();
    args.push("enum".to_string());

    let domain = super::recon_common::validate_hostname(&params.domain)?;
    args.push("-d".to_string());
    args.push(domain);

    if params.active {
        args.push("-active".to_string());
    }
    if params.passive {
        args.push("-passive".to_string());
    }
    if params.brute {
        args.push("-brute".to_string());
    }
    if params.silent {
        args.push("-silent".to_string());
    }
    if params.json_output {
        args.push("-json".to_string());
    }
    if let Some(ref wl) = params.wordlist {
        args.push("-w".to_string());
        args.push(super::recon_common::validate_file_arg(wl, "wordlist")?);
    }

    let timeout = params.timeout.unwrap_or(DEFAULT_TIMEOUT);
    args.push("-timeout".to_string());
    args.push(timeout.to_string());

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_accepts_aliases() {
        for payload in [
            serde_json::json!({"target": "example.com"}),
            serde_json::json!({"host": "example.com"}),
        ] {
            let params = normalize_amass_input(&payload).expect("normalize");
            assert_eq!(params.domain, "example.com");
        }
    }
}
