// emit-fixtures-for-parity — hidden subcommand for cross-encoder NDJSON parity.
//
// Reads each `*.json` file in --inputs as a single JSON object, reorders
// the keys to canonical order (start, end, title, url, then any extras
// in original order), and writes a one-line NDJSON file under --output.
//
// The contract MUST match `scripts/build_ndjson_golden.py`
// byte-for-byte. The parity bats test (Wave D) runs both this binary
// and the Python oracle over the same inputs and `diff`s the outputs.

use anyhow::{anyhow, bail, Context, Result};
use serde_json::{Map, Value};
use std::fs;
use std::path::Path;

const CANONICAL_KEYS: [&str; 4] = ["start", "end", "title", "url"];

pub fn emit(inputs_dir: &Path, output_dir: &Path) -> Result<()> {
    if !inputs_dir.is_dir() {
        bail!("--inputs not a directory: {}", inputs_dir.display());
    }
    fs::create_dir_all(output_dir)
        .with_context(|| format!("--output mkdir: {}", output_dir.display()))?;

    let mut entries: Vec<_> = fs::read_dir(inputs_dir)
        .with_context(|| format!("read_dir {}", inputs_dir.display()))?
        .filter_map(|e| e.ok())
        .filter(|e| {
            e.path()
                .extension()
                .map(|ext| ext == "json")
                .unwrap_or(false)
        })
        .collect();
    entries.sort_by_key(|e| e.file_name());

    if entries.is_empty() {
        bail!("no *.json fixtures in {}", inputs_dir.display());
    }

    for entry in entries {
        let in_path = entry.path();
        let raw = fs::read_to_string(&in_path)
            .with_context(|| format!("read {}", in_path.display()))?;
        let parsed: Value = serde_json::from_str(&raw)
            .with_context(|| format!("parse {}", in_path.display()))?;
        let obj = parsed
            .as_object()
            .ok_or_else(|| anyhow!("{}: top-level must be a JSON object", in_path.display()))?;

        let reordered = reorder(obj);
        // serde_json with `preserve_order` keeps Map insertion order.
        let line = serde_json::to_string(&Value::Object(reordered))
            .with_context(|| format!("serialise {}", in_path.display()))?;

        let stem = in_path
            .file_stem()
            .ok_or_else(|| anyhow!("{}: no stem", in_path.display()))?
            .to_string_lossy()
            .into_owned();
        let out_path = output_dir.join(format!("{stem}.ndjson"));
        fs::write(&out_path, format!("{line}\n"))
            .with_context(|| format!("write {}", out_path.display()))?;
    }
    Ok(())
}

/// Mirror of the Python oracle's `_reorder`: canonical keys first
/// (with `null` for missing), then any extras in original order.
fn reorder(obj: &Map<String, Value>) -> Map<String, Value> {
    let mut out = Map::new();
    for k in CANONICAL_KEYS {
        let v = obj.get(k).cloned().unwrap_or(Value::Null);
        out.insert(k.to_string(), v);
    }
    for (k, v) in obj {
        if !CANONICAL_KEYS.contains(&k.as_str()) {
            out.insert(k.clone(), v.clone());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn canonical_order_with_nulls_for_missing() {
        let obj = json!({"title": "T", "start": "S"});
        let m = obj.as_object().unwrap();
        let r = reorder(m);
        let serialized = serde_json::to_string(&Value::Object(r)).unwrap();
        assert_eq!(serialized, r#"{"start":"S","end":null,"title":"T","url":null}"#);
    }

    #[test]
    fn extras_preserved_after_canonical() {
        let obj = json!({"start":"S","end":"E","title":"T","url":"U","extra":42});
        let m = obj.as_object().unwrap();
        let r = reorder(m);
        let serialized = serde_json::to_string(&Value::Object(r)).unwrap();
        assert_eq!(
            serialized,
            r#"{"start":"S","end":"E","title":"T","url":"U","extra":42}"#
        );
    }
}
