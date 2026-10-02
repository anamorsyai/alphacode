use super::{Tool, ToolContext, ToolOutput};
use anyhow::Result;
use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::HashMap;

const DEFAULT_THREADS: usize = 20;

pub struct SubfinderTool;

#[derive(Deserialize)]
struct SubfinderInput {
    domain: String,
    #[serde(default)]
    all: bool,
    #[serde(default)]
    threads: Option<usize>,
    #[serde(default)]
    verbose: bool,
}

#[async_trait]
impl Tool for SubfinderTool {
    fn name(&self) -> &str {
        "subfinder"
    }

    fn description(&self) -> &str {
        "Passive subdomain enumeration using subfinder. Use ONLY when task is organization/domain-scope enumeration (user gave a base domain/org and asks to discover assets). Do NOT use for single-service work where user gave exactly one URL to test directly — there is nothing to enumerate."
    }

    fn parameters_schema(&self) -> Value {
        json!({
            "type": "object",
            "required": ["domain"],
            "properties": {
                "intent": super::intent_schema_property(),
                "domain": {
                    "type": "string",
                    "description": "Target domain to enumerate subdomains for."
                },
                "all": {
                    "type": "boolean",
                    "description": "Use all sources (slower but more comprehensive). Default: false."
                },
                "threads": {
                    "type": "integer",
                    "description": "Number of concurrent resolver goroutines (subfinder -t). Only affects -active resolution; subfinder's own default is 10."
                },
                "verbose": {
                    "type": "boolean",
                    "description": "Show verbose output. Default: false."
                }
            }
        })
    }

    async fn execute(&self, input: Value, _ctx: ToolContext) -> Result<ToolOutput> {
        let params: SubfinderInput = normalize_subfinder_input(&input)?;
        let args = build_args(&params)?;

        let output = super::recon_common::run_bounded(
            "subfinder",
            &args,
            super::recon_common::DEFAULT_TOOL_TIMEOUT,
        )
        .await
        .map_err(|e| {
            // Name the concrete install command rather than a bare "not found",
            // so the model (or the user) can act on it directly.
            if e.starts_with("failed to run") {
                anyhow::anyhow!("{e}. {}", super::recon_common::install_hint("subfinder"))
            } else {
                anyhow::anyhow!("{e}")
            }
        })?;

        if !output.status.success() {
            let detail = super::recon_common::describe_failure("subfinder", &output);
            return Err(anyhow::anyhow!("{detail}"));
        }

        let (domains, total, truncated) = super::recon_common::parse_lines(&output.stdout);

        let mut result = format!(
            "Subfinder found {} subdomains for {}:\n\n",
            domains.len(),
            params.domain
        );

        for domain in &domains {
            result.push_str(domain);
            result.push('\n');
        }
        result.push_str(&super::recon_common::truncation_notice(
            domains.len(),
            total,
        ));

        let mut metadata = HashMap::new();
        metadata.insert("domain".to_string(), json!(params.domain));
        metadata.insert("count".to_string(), json!(domains.len()));
        metadata.insert("total_found".to_string(), json!(total));
        metadata.insert("truncated".to_string(), json!(truncated));
        metadata.insert("all_sources".to_string(), json!(params.all));

        Ok(ToolOutput::new(result)
            .with_title(format!("subfinder: {} domains found", domains.len()))
            .with_metadata(json!(metadata)))
    }
}

impl SubfinderTool {
    pub fn new() -> Self {
        Self
    }
}

/// Accept the key spellings models actually send (`target`, `host`, `d`)
/// in addition to the canonical `domain`, so a wrong key name becomes a
/// working call instead of a `missing field` failure loop.
fn normalize_subfinder_input(input: &Value) -> Result<SubfinderInput> {
    if let Ok(params) = serde_json::from_value::<SubfinderInput>(input.clone()) {
        return Ok(params);
    }
    let domain = super::coerce_host_arg(input, "subfinder", "domain")?;
    // Remaining options are optional; a payload that was a bare host string has
    // no object to read them from, so an empty map stands in for the defaults.
    let obj = input.as_object().cloned().unwrap_or_default();
    Ok(SubfinderInput {
        domain: domain.to_string(),
        all: obj.get("all").and_then(|v| v.as_bool()).unwrap_or(false),
        threads: obj
            .get("threads")
            .and_then(|v| v.as_u64())
            .map(|n| n as usize),
        verbose: obj
            .get("verbose")
            .and_then(|v| v.as_bool())
            .unwrap_or(false),
    })
}

fn build_args(params: &SubfinderInput) -> Result<Vec<String>> {
    let domain = super::recon_common::validate_hostname(&params.domain)?;

    let mut args = Vec::new();
    args.push("-d".to_string());
    args.push(domain);

    if params.all {
        args.push("-all".to_string());
    }

    // `-t`, NOT `-threads`. subfinder registers the concurrency knob as
    // `flagSet.IntVar(&options.Threads, "t", 10, ...)`; there is no long
    // `-threads` name. Passing it made goflags abort with "flag provided but
    // not defined" and exit 2, which meant *every* subfinder call failed.
    let threads = params.threads.unwrap_or(DEFAULT_THREADS);
    args.push("-t".to_string());
    args.push(threads.to_string());
    args.push("-silent".to_string());

    if params.verbose {
        args.push("-v".to_string());
    }

    Ok(args)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_normalize_accepts_domain_aliases() {
        for payload in [
            serde_json::json!({"target": "example.com"}),
            serde_json::json!({"host": "example.com"}),
        ] {
            let params = normalize_subfinder_input(&payload).expect("normalize");
            assert_eq!(params.domain, "example.com");
        }
        assert!(normalize_subfinder_input(&serde_json::json!({})).is_err());
    }

    #[test]
    fn test_build_args_basic() {
        let input = SubfinderInput {
            domain: "example.com".to_string(),
            all: false,
            threads: None,
            verbose: false,
        };
        let args = build_args(&input).expect("args");
        assert!(args.contains(&"-d".to_string()));
        assert!(args.contains(&"example.com".to_string()));
    }

    #[test]
    fn test_build_args_all() {
        let input = SubfinderInput {
            domain: "example.com".to_string(),
            all: true,
            threads: None,
            verbose: false,
        };
        let args = build_args(&input).expect("args");
        assert!(args.contains(&"-all".to_string()));
    }

    /// Regression: `-threads` is not a subfinder flag. It is registered as
    /// `-t`, so passing the long form made every invocation exit 2 with
    /// "flag provided but not defined" — the tool was 100% broken.
    #[test]
    fn threads_flag_is_the_real_subfinder_flag() {
        let input = SubfinderInput {
            domain: "example.com".to_string(),
            all: false,
            threads: Some(42),
            verbose: false,
        };
        let args = build_args(&input).expect("args");
        assert!(args.contains(&"-t".to_string()), "missing -t: {args:?}");
        assert!(
            !args.contains(&"-threads".to_string()),
            "-threads is not a subfinder flag: {args:?}"
        );
        let idx = args.iter().position(|a| a == "-t").expect("-t present");
        assert_eq!(args[idx + 1], "42", "thread value not passed");
    }

    #[test]
    fn flag_like_domain_is_rejected_before_spawning() {
        // A bare `-o` as a domain would be parsed by goflags as a flag, so the
        // tool would do something other than what was asked with no error.
        for bad in ["-o", "-all", "-silent", "-json"] {
            let input = SubfinderInput {
                domain: bad.to_string(),
                all: false,
                threads: None,
                verbose: false,
            };
            assert!(build_args(&input).is_err(), "accepted {bad} as a domain");
        }
    }
}
