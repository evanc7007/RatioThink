//! Control-plane handlers.
//!
//! Only touches `inferlet::runtime` (models, version, instance-id) and
//! `pie:core/model` (load). No chat-templating, sampling, or
//! generator surface lives here — those belong under [`crate::chat`].

pub mod health;
pub mod load;
pub mod models;
