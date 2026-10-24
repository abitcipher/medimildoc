//! HTTP/JSON API. Read-only; called by the Phoenix app only, never by
//! browsers (the compose file does not publish the port).

use std::sync::Arc;

use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::dataset::{Catalog, Dataset, FALLBACK_LANG};
use crate::learned::{self, Learned};

const DEFAULT_LIMIT: usize = 20;
const MAX_LIMIT: usize = 100;
/// Datasets bigger than this (places) are only searched, never listed.
const MAX_LIST: usize = 10_000;

#[derive(Deserialize)]
pub struct Params {
    lang: Option<String>,
    q: Option<String>,
    limit: Option<usize>,
    /// Search only: restrict to entries of this ISO alpha-2 country.
    country: Option<String>,
}

impl Params {
    fn lang(&self) -> &str {
        self.lang
            .as_deref()
            .filter(|l| !l.is_empty())
            .unwrap_or(FALLBACK_LANG)
    }
}

pub struct AppState {
    pub catalog: Catalog,
    pub learned: Learned,
}

pub fn router(state: Arc<AppState>) -> Router {
    Router::new()
        .route("/health", get(health))
        .route("/v1/datasets", get(datasets))
        .route("/v1/learned/{category}", post(learn))
        .route("/v1/learned/{category}/search", get(learned_search))
        .route("/v1/{dataset}", get(list))
        .route("/v1/{dataset}/search", get(search))
        .route("/v1/{dataset}/entries/{code}", get(entry))
        .with_state(state)
}

#[derive(Deserialize)]
pub struct LearnBody {
    value: String,
}

/// Records one use of a value (the app calls this after a save).
async fn learn(
    State(app): State<Arc<AppState>>,
    Path(category): Path<String>,
    Json(body): Json<LearnBody>,
) -> Result<StatusCode, ApiError> {
    if !learned::valid_category(&category) {
        return Err(ApiError(StatusCode::BAD_REQUEST, "invalid category"));
    }
    let Some(value) = learned::clean_value(&body.value) else {
        return Err(ApiError(StatusCode::BAD_REQUEST, "empty or too long value"));
    };
    app.learned.add(&category, &value).map_err(|_| {
        ApiError(
            StatusCode::INTERNAL_SERVER_ERROR,
            "could not store the value",
        )
    })?;
    Ok(StatusCode::NO_CONTENT)
}

async fn learned_search(
    State(app): State<Arc<AppState>>,
    Path(category): Path<String>,
    Query(params): Query<Params>,
) -> Json<Value> {
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let entries = app
        .learned
        .search(&category, params.q.as_deref().unwrap_or_default(), limit);
    Json(json!({"entries": entries}))
}

async fn health(State(app): State<Arc<AppState>>) -> Json<Value> {
    let catalog = &app.catalog;
    Json(json!({"status": "ok", "version": catalog.version}))
}

async fn datasets(State(app): State<Arc<AppState>>) -> Json<Value> {
    let catalog = &app.catalog;
    let all: Vec<Value> = catalog
        .datasets
        .values()
        .map(|d| json!({"dataset": d.name, "description": d.description, "count": d.len(), "version": d.version}))
        .collect();
    Json(json!({"version": catalog.version, "datasets": all}))
}

fn dataset<'a>(catalog: &'a Catalog, name: &str) -> Result<&'a Dataset, ApiError> {
    catalog
        .datasets
        .get(name)
        .ok_or(not_found("unknown dataset"))
}

pub struct ApiError(StatusCode, &'static str);

fn not_found(message: &'static str) -> ApiError {
    ApiError(StatusCode::NOT_FOUND, message)
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, Json(json!({"error": self.1}))).into_response()
    }
}

async fn list(
    State(app): State<Arc<AppState>>,
    Path(name): Path<String>,
    Query(params): Query<Params>,
) -> Result<Json<Value>, ApiError> {
    let catalog = &app.catalog;
    let d = dataset(catalog, &name)?;
    if d.len() > MAX_LIST {
        return Err(ApiError(
            StatusCode::BAD_REQUEST,
            "dataset too large to list; use search",
        ));
    }
    let entries: Vec<Value> = d
        .list(params.lang())
        .into_iter()
        .map(|e| catalog.with_context(e, params.lang()))
        .collect();
    Ok(Json(json!({"version": d.version, "entries": entries})))
}

async fn search(
    State(app): State<Arc<AppState>>,
    Path(name): Path<String>,
    Query(params): Query<Params>,
) -> Result<Json<Value>, ApiError> {
    let catalog = &app.catalog;
    let d = dataset(catalog, &name)?;
    let limit = params.limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT);
    let entries: Vec<Value> = d
        .search(
            params.q.as_deref().unwrap_or_default(),
            params.lang(),
            limit,
            params.country.as_deref(),
        )
        .into_iter()
        .map(|e| catalog.with_context(e, params.lang()))
        .collect();
    Ok(Json(json!({"version": d.version, "entries": entries})))
}

async fn entry(
    State(app): State<Arc<AppState>>,
    Path((name, code)): Path<(String, String)>,
    Query(params): Query<Params>,
) -> Result<Json<Value>, ApiError> {
    let catalog = &app.catalog;
    let d = dataset(catalog, &name)?;
    d.get(&code, params.lang())
        .map(|e| Json(catalog.with_context(e, params.lang())))
        .ok_or(not_found("unknown code"))
}
