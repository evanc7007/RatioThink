//! `POST /v1/models/load` + `DELETE /v1/models/load` — explicit
//! model pre-warm endpoints.
//!
//! V1 caveat: pie registers all models at engine boot
//! (`pie serve --config ...`); the WIT `model::load` import is a
//! registry lookup, not a download. There is therefore no in-process
//! load to drive progress for, and no in-flight load to cancel.
//!
//! The endpoints are kept so the GUI's `EngineClient.loadModel` and
//! `Cancel` buttons have stable Swift-side wiring against `chat-apc`:
//!
//! * `POST   /v1/models/load`: validates that the requested model id
//!   is registered, then emits a single `data: {"event":"model_ready"}`
//!   SSE frame and the `[DONE]` terminator. Unknown model → 404 JSON.
//! * `DELETE /v1/models/load`: returns 204 unconditionally (idempotent
//!   no-op).
//!
//! When pie surfaces real load progress (tracked in the follow-up
//! work called out in the engine's description), the POST handler will
//! emit `model_loading` meta-frames before `model_ready`; the DELETE
//! handler will cancel an in-flight load and emit a synthetic
//! `model_ready` with a `cancelled: true` annotation.

use serde::Deserialize;
use inferlet::runtime;
use wstd::http::body::IncomingBody;
use wstd::http::server::{Finished, Responder};
use wstd::http::Request;

use crate::sse::{self, EmitError, Emitter, SseError};

#[derive(Deserialize)]
struct LoadRequest {
    model: String,
}

pub async fn handle_post(req: Request<IncomingBody>, res: Responder) -> Finished {
    let (_parts, mut body) = req.into_parts();
    let mut body_bytes = Vec::new();
    if let Err(e) = sse::read_body(&mut body, &mut body_bytes, sse::LOAD_MAX_BODY).await {
        return res.respond(sse::body_error_response(e)).await;
    }
    let request: LoadRequest = match serde_json::from_slice(&body_bytes) {
        Ok(r) => r,
        Err(e) => {
            return res
                .respond(sse::json_error(
                    400,
                    "invalid_request",
                    &format!("Invalid JSON: {e}"),
                ))
                .await;
        }
    };

    let registered = runtime::models();
    if !registered.iter().any(|m| m == &request.model) {
        return res
            .respond(sse::json_error(
                404,
                "model_not_found",
                &format!("Model '{}' not registered with this engine", request.model),
            ))
            .await;
    }

    // Registered ⇒ model is already loaded into the pie engine at
    // boot. Skip directly to `model_ready`; no `model_loading` prefix
    // until pie-side progress is wired. SSE wrapper used so the GUI
    // doesn't need a second code path for the not-yet-loading case.
    let mut em = Emitter::start(res);
    // F10b: model_ready is a non-terminal emit. Disconnect = silent
    // exit (peer gone). Serialize-bug = host-visible diagnostic
    // (stderr) + inline `serialize_bug` meta-frame so any client
    // still attached gets a signal before [DONE].
    match sse::emit_model_ready(&mut em).await {
        Ok(()) => {}
        Err(EmitError::Disconnected) => return em.finish(),
        Err(EmitError::Serialize(e)) => {
            eprintln!("[chat-apc] load model_ready serialize bug: {e}");
            let msg = e.to_string();
            let _ = em
                .emit_json(&SseError::new("serialize_bug", &msg))
                .await;
            sse::emit_done_logged(&mut em, "load_serialize_recover").await;
            return em.finish();
        }
    }
    sse::emit_done_logged(&mut em, "load_exit").await;
    em.finish()
}

pub async fn handle_delete(res: Responder) -> Finished {
    // 204 with no body. Idempotent: repeated DELETEs on the same
    // endpoint behave identically (the design doc's "cancel an
    // in-flight load" semantics are a no-op until pie exposes a
    // cancellation hook).
    sse::respond_no_content(res).await
}
