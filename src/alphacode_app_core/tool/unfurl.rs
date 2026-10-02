use super::{Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

pub struct UnfurlTool;

#[derive(Deserialize)]
struct UnfurlInput {
    /// Input: URL or file path
    input: String,
    /// Mode: keys, values, domains, paths, format
    #[serde(default = "default_mode")]
    mode: String,
    /// Unique only
    #[serde(default)]
    unique: bool,
    /// Sort
    #[serde(default)]
    sort: bool,
}

fn default_mode() -> String {
    "format".to_string()
}

#[async_trait]
impl Tool for UnfurlTool {
    fn name(&self) -> &str {
        "unfurl"
    }

    fn description(&self) -> &str {
        "URL parsing and normalization tool. Extract domains, paths, query parameters from URLs. Use to analyze and normalize large URL lists from gau/waybackurls."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["input"],
            "properties": {
                "intent": super::intent_schema_property(),
                "input": {
                    "type": "string",
                    "description": "URL or file path with URLs (one per line)."
                },
                "mode": {
                    "type": "string",
                    "enum": ["format", "keys", "values", "domains", "paths"],
                    "description": "Output mode. Default: 'format'."
                },
                "unique": {
                    "type": "boolean",
                    "description": "Only unique results. Default: false."
                },
                "sort": {
                    "type": "boolean",
                    "description": "Sort output. Default: false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, _ctx: ToolContext) -> Result<ToolOutput> {
        let params: UnfurlInput = normalize_unfurl_input(&input)?;
        let args = build_args(&params)?;

        let output = super::recon_common::run_bounded(
            "unfurl",
            &args,
            super::recon_common::DEFAULT_TOOL_TIMEOUT,
        )
        .await
        .map_err(|e| {
            if e.starts_with("failed to run") {
                anyhow::anyhow!("{e}. {}", super::recon_common::install_hint("unfurl"))
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
            return Err(anyhow::anyhow!("unfurl exited with error: {detail}"));
        }

        let (lines, total, truncated) = super::recon_common::parse_lines(&output.stdout);

        let mut result = format!("unfurl found {} results:\n\n", total);
        for line in &lines {
            result.push_str(line);
            result.push('\n');
        }
        result.push_str(&super::recon_common::truncation_notice(lines.len(), total));

        let mut metadata = HashMap::new();
        metadata.insert("input".to_string(), json!(params.input));
        metadata.insert("mode".to_string(), json!(params.mode));
        metadata.insert("count".to_string(), json!(lines.len()));
        metadata.insert("total_found".to_string(), json!(total));
        metadata.insert("truncated".to_string(), json!(truncated));

        Ok(ToolOutput::new(result)
            .with_title(format!("unfurl: {total} results"))
            .with_metadata(json!(metadata)))
    }
}

impl UnfurlTool {
    pub fn new() -> Self {
        Self
    }
}

fn normalize_unfurl_input(input: &Value) -> Result<UnfurlInput> {
    if let Ok(params) = serde_json::from_value::<UnfurlInput>(input.clone()) {
        return Ok(params);
    }
    // `input` is the documented key, but models send `url`/`target` just as
    // often; both resolve to the same value here.
    let input_val = super::coerce_url_arg(input, "unfurl")?;
    // Remaining options are optional; a payload that was a bare URL string has
    // no object to read them from, so an empty map stands in for the defaults.
    let obj = input.as_object().cloned().unwrap_or_default();
    Ok(UnfurlInput {
        input: input_val.to_string(),
        mode: obj
            .get("mode")
            .and_then(|v| v.as_str())
            .unwrap_or("format")
            .to_string(),
        unique: obj.get("unique").and_then(|v| v.as_bool()).unwrap_or(false),
        sort: obj.get("sort").and_then(|v| v.as_bool()).unwrap_or(false),
    })
}

fn build_args(params: &UnfurlInput) -> Result<Vec<String>> {
    let mut args = vec![
        "-i".to_string(),
        params.input.clone(),
        "-m".to_string(),
        params.mode.clone(),
    ];

    if params.unique {
        args.push("-u".to_string());
    }
    if params.sort {
        args.push("-s".to_string());
    }

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_accepts_aliases() {
        for payload in [
            serde_json::json!({"input": "https://example.com"}),
            serde_json::json!({"url": "https://example.com"}),
        ] {
            let params = normalize_unfurl_input(&payload).expect("normalize");
            assert_eq!(params.input, "https://example.com");
        }
    }
}
