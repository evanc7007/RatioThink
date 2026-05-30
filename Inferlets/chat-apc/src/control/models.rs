//! `GET /v1/models` — OpenAI-shape model list, driven by
//! `inferlet::runtime::models()`.

use serde::Serialize;
use wstd::http::server::{Finished, Responder};
use wstd::http::{IntoBody, Response};

#[derive(Serialize)]
struct ModelObject {
    id: String,
    object: &'static str,
    owned_by: &'static str,
}

#[derive(Serialize)]
struct ModelList {
    object: &'static str,
    data: Vec<ModelObject>,
}

pub async fn handle(res: Responder) -> Finished {
    let data: Vec<ModelObject> = inferlet::runtime::models()
        .into_iter()
        .map(|id| ModelObject {
            id,
            object: "model",
            owned_by: "pie",
        })
        .collect();
    let list = ModelList {
        object: "list",
        data,
    };
    // `ModelList` is `{object: &'static str, data: Vec<ModelObject{String,
    // &'static str, &'static str}>}` — no field can fail to serialize.
    // A silent `"{}"` fallback here would ship 200 with `body.object`
    // undefined, breaking OpenAI-shape clients without any HTTP signal.
    // Surface the invariant violation instead.
    let body = serde_json::to_string(&list).expect("ModelList must serialize");
    let response = Response::builder()
        .header("Content-Type", "application/json")
        .body(body.into_body())
        .unwrap();
    res.respond(response).await
}
