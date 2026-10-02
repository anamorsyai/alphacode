use super::{Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

pub struct AssetfinderTool;

#[derive(Deserialize)]
struct AssetfinderInput {
    domain: String,
    #[serde(default)]
    subs_only: bool,
    #[serde(default)]
    #[allow(dead_code)]
    silent: bool,
}

#[async_trait]
impl Tool for AssetfinderTool {
    fn name(&self) -> &str {
        "assetfinder"
    }

    fn description(&self) -> &str {
        "Find related domains and subdomains. Use alongside subfinder for comprehensive asset discovery."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["domain"],
            "properties": {
                "intent": super::intent_schema_property(),
                "domain": {
                    "type": "string",
                    "description": "Target domain."
                },
                "subs_only": {
                    "type": "boolean",
                    "description": "Only output subdomains. Default: false."
                },
                "silent": {
                    "type": "boolean",
                    "description": "Silent mode. Default: false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, _ctx: ToolContext) -> Result<ToolOutput> {
        let params: AssetfinderInput = normalize_assetfinder_input(&input)?;
        let args = build_args(&params)?;

        let output = super::recon_common::run_bounded(
            "assetfinder",
            &args,
            super::recon_common::DEFAULT_TOOL_TIMEOUT,
        )
        .await
        .map_err(|e| {
            if e.starts_with("failed to run") {
                anyhow::anyhow!("{e}. {}", super::recon_common::install_hint("assetfinder"))
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
            return Err(anyhow::anyhow!("assetfinder exited with error: {detail}"));
        }

        let (lines, total, truncated) = super::recon_common::parse_lines(&output.stdout);

        let mut result = format!(
            "assetfinder found {} assets for {}:\n\n",
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

        Ok(ToolOutput::new(result)
            .with_title(format!("assetfinder: {total} assets"))
            .with_metadata(json!(metadata)))
    }
}

impl AssetfinderTool {
    pub fn new() -> Self {
        Self
    }
}

fn normalize_assetfinder_input(input: &Value) -> Result<AssetfinderInput> {
    if let Ok(params) = serde_json::from_value::<AssetfinderInput>(input.clone()) {
        return Ok(params);
    }
    let domain = super::coerce_host_arg(input, "assetfinder", "domain")?;
    // Remaining options are optional; a payload that was a bare host string has
    // no object to read them from, so an empty map stands in for the defaults.
    let obj = input.as_object().cloned().unwrap_or_default();
    Ok(AssetfinderInput {
        domain: domain.to_string(),
        subs_only: obj
            .get("subs_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        silent: obj.get("silent").and_then(|v| v.as_bool()).unwrap_or(false),
    })
}

fn build_args(params: &AssetfinderInput) -> Result<Vec<String>> {
    let mut args = Vec::new();
    let domain = super::recon_common::validate_hostname(&params.domain)?;
    args.push(domain);

    if params.subs_only {
        args.push("--subs-only".to_string());
    }

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
            let params = normalize_assetfinder_input(&payload).expect("normalize");
            assert_eq!(params.domain, "example.com");
        }
    }
}
