use super::{Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

const DEFAULT_TIMING: &str = "T4";

pub struct NmapTool;

#[derive(Deserialize)]
struct NmapInput {
    /// Target host(s) or IP(s)
    target: String,
    /// Ports to scan
    #[serde(default)]
    ports: Option<String>,
    /// Scan type: syn, connect, udp, ack, window, maimon, null, fin, xmas, ipproto
    #[serde(default)]
    scan_type: Option<String>,
    /// Service version detection
    #[serde(default)]
    service_version: bool,
    /// OS detection
    #[serde(default)]
    os_detection: bool,
    /// Script scan
    #[serde(default)]
    script: Option<String>,
    /// Timing template (T0-T5)
    #[serde(default)]
    timing: Option<String>,
    /// Top ports
    #[serde(default)]
    top_ports: Option<u32>,
    /// All ports
    #[serde(default)]
    all_ports: bool,
    /// No ping
    #[serde(default)]
    no_ping: bool,
    /// Treat all hosts as online
    #[serde(default)]
    treat_all_online: bool,
    /// Output format
    #[serde(default)]
    #[allow(dead_code)]
    output_format: Option<String>,
    /// Verbose
    #[serde(default)]
    verbose: bool,
    /// Fragment packets
    #[serde(default)]
    fragment: bool,
    /// Source port
    #[serde(default)]
    source_port: Option<u16>,
    /// Max retries
    #[serde(default)]
    max_retries: Option<u8>,
    /// Host timeout
    #[serde(default)]
    host_timeout: Option<String>,
    /// Min rate
    #[serde(default)]
    min_rate: Option<u32>,
    /// Max rate
    #[serde(default)]
    max_rate: Option<u32>,
}

#[async_trait]
impl Tool for NmapTool {
    fn name(&self) -> &str {
        "nmap"
    }

    fn description(&self) -> &str {
        "Network mapper for port scanning and service detection. Use for comprehensive network reconnaissance when you need detailed service and OS information."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["target"],
            "properties": {
                "intent": super::intent_schema_property(),
                "target": {
                    "type": "string",
                    "description": "Target host or IP (e.g., 'example.com' or '192.168.1.1')."
                },
                "ports": {
                    "type": "string",
                    "description": "Ports to scan (e.g., '80,443,8080' or '1-65535')."
                },
                "service_version": {
                    "type": "boolean",
                    "description": "Service version detection. Default: false."
                },
                "os_detection": {
                    "type": "boolean",
                    "description": "OS detection. Default: false."
                },
                "script": {
                    "type": "string",
                    "description": "NSE script to run (e.g., 'vuln', 'safe')."
                },
                "timing": {
                    "type": "string",
                    "description": "Timing template (T0-T5). Default: T4."
                },
                "top_ports": {
                    "type": "integer",
                    "description": "Scan top N ports."
                },
                "all_ports": {
                    "type": "boolean",
                    "description": "Scan all 65535 ports. Default: false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, _ctx: ToolContext) -> Result<ToolOutput> {
        let params: NmapInput = normalize_nmap_input(&input)?;
        let args = build_args(&params)?;

        let output = super::recon_common::run_bounded(
            "nmap",
            &args,
            super::recon_common::DEFAULT_TOOL_TIMEOUT,
        )
        .await
        .map_err(|e| {
            if e.starts_with("failed to run") {
                anyhow::anyhow!("{e}. {}", super::recon_common::install_hint("nmap"))
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
            return Err(anyhow::anyhow!("nmap exited with error: {detail}"));
        }

        let (lines, total, truncated) = super::recon_common::parse_lines(&output.stdout);

        let mut result = format!("nmap found {} results:\n\n", total);
        for line in &lines {
            result.push_str(line);
            result.push('\n');
        }
        result.push_str(&super::recon_common::truncation_notice(lines.len(), total));

        let mut metadata = HashMap::new();
        metadata.insert("target".to_string(), json!(params.target));
        metadata.insert("count".to_string(), json!(lines.len()));
        metadata.insert("total_found".to_string(), json!(total));
        metadata.insert("truncated".to_string(), json!(truncated));

        Ok(ToolOutput::new(result)
            .with_title(format!("nmap: {total} results"))
            .with_metadata(json!(metadata)))
    }
}

impl NmapTool {
    pub fn new() -> Self {
        Self
    }
}

fn normalize_nmap_input(input: &Value) -> Result<NmapInput> {
    if let Ok(params) = serde_json::from_value::<NmapInput>(input.clone()) {
        return Ok(params);
    }
    // Aliases, bare-host strings and truncated payloads all resolve through the
    // shared coercion ladder.
    let target = super::coerce_host_arg(input, "nmap", "target")?;
    // Remaining options are optional; a payload that was a bare host string has
    // no object to read them from, so an empty map stands in for the defaults.
    let obj = input.as_object().cloned().unwrap_or_default();
    Ok(NmapInput {
        target: target.to_string(),
        ports: obj.get("ports").and_then(|v| v.as_str()).map(String::from),
        scan_type: obj
            .get("scan_type")
            .and_then(|v| v.as_str())
            .map(String::from),
        service_version: obj
            .get("service_version")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        os_detection: obj
            .get("os_detection")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        script: obj.get("script").and_then(|v| v.as_str()).map(String::from),
        timing: obj.get("timing").and_then(|v| v.as_str()).map(String::from),
        top_ports: obj
            .get("top_ports")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
        all_ports: obj
            .get("all_ports")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        no_ping: obj
            .get("no_ping")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        treat_all_online: obj
            .get("treat_all_online")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        output_format: obj
            .get("output_format")
            .and_then(|v| v.as_str())
            .map(String::from),
        verbose: obj
            .get("verbose")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        fragment: obj
            .get("fragment")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
        source_port: obj
            .get("source_port")
            .and_then(|v| v.as_u64())
            .map(|n| n as u16),
        max_retries: obj
            .get("max_retries")
            .and_then(|v| v.as_u64())
            .map(|n| n as u8),
        host_timeout: obj
            .get("host_timeout")
            .and_then(|v| v.as_str())
            .map(String::from),
        min_rate: obj
            .get("min_rate")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
        max_rate: obj
            .get("max_rate")
            .and_then(|v| v.as_u64())
            .map(|n| n as u32),
    })
}

fn build_args(params: &NmapInput) -> Result<Vec<String>> {
    let mut args = Vec::new();

    let target = super::recon_common::validate_target(&params.target)?;
    args.push(target);

    if let Some(ref ports) = params.ports {
        args.push("-p".to_string());
        args.push(ports.clone());
    }
    if let Some(ref scan_type) = params.scan_type {
        args.push(format!("-{scan_type}"));
    }
    if params.service_version {
        args.push("-sV".to_string());
    }
    if params.os_detection {
        args.push("-O".to_string());
    }
    if let Some(ref script) = params.script {
        args.push("--script".to_string());
        args.push(script.clone());
    }
    if let Some(ref timing) = params.timing {
        args.push(format!("-{timing}"));
    } else {
        args.push(format!("-{DEFAULT_TIMING}"));
    }
    if let Some(top) = params.top_ports {
        args.push("--top-ports".to_string());
        args.push(top.to_string());
    }
    if params.all_ports {
        args.push("-p-".to_string());
    }
    if params.no_ping {
        args.push("-Pn".to_string());
    }
    if params.treat_all_online {
        args.push("--open".to_string());
    }
    if params.verbose {
        args.push("-v".to_string());
    }
    if params.fragment {
        args.push("-f".to_string());
    }
    if let Some(port) = params.source_port {
        args.push("--source-port".to_string());
        args.push(port.to_string());
    }
    if let Some(retries) = params.max_retries {
        args.push("--max-retries".to_string());
        args.push(retries.to_string());
    }
    if let Some(ref timeout) = params.host_timeout {
        args.push("--host-timeout".to_string());
        args.push(timeout.clone());
    }
    if let Some(rate) = params.min_rate {
        args.push("--min-rate".to_string());
        args.push(rate.to_string());
    }
    if let Some(rate) = params.max_rate {
        args.push("--max-rate".to_string());
        args.push(rate.to_string());
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
            let params = normalize_nmap_input(&payload).expect("normalize");
            assert_eq!(params.target, "example.com");
        }
    }
}
