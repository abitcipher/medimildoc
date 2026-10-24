//! FSDC rules engine (docs/design/data-consistency.md): GoRules ZEN
//! evaluating JSON Decision Model graphs, called from Elixir as a NIF
//! (`App.Rules.Engine`). Graphs and contexts cross the boundary as JSON
//! strings; both functions run on a dirty CPU scheduler so a long
//! evaluation never blocks the BEAM's normal schedulers.

use std::sync::LazyLock;

use rustler::{Atom, NifResult};
use zen_engine::model::GraphContent;
use zen_engine::{Decision, EvaluationSerializedOptions, EvaluationTraceKind};

mod atoms {
    rustler::atoms! { ok, error }
}

// ZEN's evaluation is async; one small shared runtime drives it.
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("tokio runtime for the rules engine")
});

fn decision(graph: &str) -> Result<Decision, String> {
    let mut content: GraphContent =
        serde_json::from_str(graph).map_err(|e| format!("invalid graph: {e}"))?;
    content.compile();
    Ok(Decision::from(content))
}

/// Evaluates `graph` (JDM JSON) with `context` (JSON). Returns
/// `{:ok, response_json}` (`result`, `performance`, and `trace` when asked)
/// or `{:error, error_json}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_evaluate(graph: String, context: String, trace: bool) -> NifResult<(Atom, String)> {
    let decision = match decision(&graph) {
        Ok(decision) => decision,
        Err(message) => {
            return Ok((
                atoms::error(),
                serde_json::json!({ "message": message }).to_string(),
            ))
        }
    };

    let context: serde_json::Value = match serde_json::from_str(&context) {
        Ok(value) => value,
        Err(e) => {
            return Ok((
                atoms::error(),
                serde_json::json!({ "message": format!("invalid context: {e}") }).to_string(),
            ))
        }
    };

    let options = EvaluationSerializedOptions {
        trace: if trace {
            EvaluationTraceKind::Default
        } else {
            EvaluationTraceKind::None
        },
        ..Default::default()
    };

    match RUNTIME.block_on(decision.evaluate_serialized(context.into(), options)) {
        Ok(value) => Ok((atoms::ok(), value.to_string())),
        Err(value) => Ok((atoms::error(), value.to_string())),
    }
}

/// Checks that `graph` is a well-formed decision graph (nodes, edges, one
/// input and output). `{:ok, ""}` or `{:error, message}`.
#[rustler::nif(schedule = "DirtyCpu")]
fn nif_validate(graph: String) -> NifResult<(Atom, String)> {
    match decision(&graph).and_then(|d| d.validate().map_err(|e| e.to_string())) {
        Ok(()) => Ok((atoms::ok(), String::new())),
        Err(message) => Ok((atoms::error(), message)),
    }
}

rustler::init!("Elixir.App.Rules.Engine");
