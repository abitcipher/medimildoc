use std::path::Path;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

async fn get(uri: &str) -> (StatusCode, Value) {
    let catalog =
        ihds::Catalog::load_dir(Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/seed"))).unwrap();
    let state = ihds::http::AppState {
        catalog,
        learned: ihds::learned::Learned::open(None).unwrap(),
    };
    let response = ihds::http::router(Arc::new(state))
        .oneshot(Request::get(uri).body(Body::empty()).unwrap())
        .await
        .unwrap();
    let status = response.status();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    (status, serde_json::from_slice(&bytes).unwrap())
}

#[tokio::test]
async fn health_and_datasets() {
    let (status, body) = get("/health").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["status"], "ok");

    let (_, body) = get("/v1/datasets").await;
    assert_eq!(body["datasets"][0]["dataset"], "countries");
}

#[tokio::test]
async fn search_lookup_and_list() {
    let (_, body) = get("/v1/countries/search?q=%D0%BD%D1%96%D0%BC&lang=uk&limit=3").await;
    assert_eq!(body["entries"][0]["code"], "DE");
    assert_eq!(body["entries"][0]["label"], "Німеччина");

    let (status, body) = get("/v1/countries/entries/ua?lang=fr").await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(body["label"], "Ukraine");

    let (_, body) = get("/v1/countries?lang=en").await;
    assert!(body["entries"].as_array().unwrap().len() > 240);
}

#[tokio::test]
async fn places_are_searched_not_listed() {
    let (status, _) = get("/v1/places").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    let (_, body) = get("/v1/places/search?q=lviv&lang=uk&country=UA&limit=1").await;
    assert_eq!(body["entries"][0]["label"], "Львів");
    assert!(
        body["entries"][0]["context_label"]
            .as_str()
            .unwrap()
            .contains("Львівська")
    );
}

#[tokio::test]
async fn learned_values_round_trip() {
    let catalog =
        ihds::Catalog::load_dir(Path::new(concat!(env!("CARGO_MANIFEST_DIR"), "/seed"))).unwrap();
    let state = ihds::http::AppState {
        catalog,
        learned: ihds::learned::Learned::open(None).unwrap(),
    };
    let router = ihds::http::router(Arc::new(state));

    let post = |value: &str| {
        Request::post("/v1/learned/issuing_authority")
            .header("content-type", "application/json")
            .body(Body::from(
                serde_json::json!({ "value": value }).to_string(),
            ))
            .unwrap()
    };
    let response = router
        .clone()
        .oneshot(post(" State  Migration Service "))
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let response = router.clone().oneshot(post("")).await.unwrap();
    assert_eq!(response.status(), StatusCode::BAD_REQUEST);

    let response = router
        .oneshot(
            Request::get("/v1/learned/issuing_authority/search?q=migr")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(body["entries"][0]["value"], "State Migration Service");
}

#[tokio::test]
async fn unknown_things_are_404() {
    assert_eq!(get("/v1/nope").await.0, StatusCode::NOT_FOUND);
    assert_eq!(
        get("/v1/countries/entries/XX").await.0,
        StatusCode::NOT_FOUND
    );
}
