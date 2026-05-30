//! APC (Adaptive Personality/Capability) decoder wrappers.
//!
//! [`super::completions`] runs both decoders alongside `chat::Decoder`
//! on every generation loop iteration: reasoning fires
//! `reasoning_content` SSE deltas, tool-use terminates the loop with
//! a complete `Event::Call` that becomes an OpenAI `tool_calls`
//! delta on the terminal chunk. The wrappers exist so swapping out
//! the SDK surface (or adding APC-specific bookkeeping) is one-edit
//! local rather than scattered across `completions.rs`.
//!
//! TODO(mcp::client): when the chat loop grows server-side tool
//! execution, plumb `inferlet::mcp` here so a single APC turn can
//! pull tool results from an MCP server and feed them back into the
//! generator via [`super::completions`]. Today the wire matches
//! OpenAI's client-side execution model — pie emits the call, the
//! caller runs the tool and resubmits the result on the next turn.

use inferlet::Result;
use inferlet::model::Model;

// =============================================================================
// Tool-use stub — wraps `inferlet::tools::Decoder`.
// =============================================================================

/// Streaming detector for tool-call events inside generated text.
///
/// V1 stub: instantiated but not yet fed by the chat loop. Once the
/// chat handler emits OpenAI-shape `tool_calls` deltas, this is the
/// decoder it will run alongside `chat::Decoder`.
pub struct ToolUseDecoder {
    inner: inferlet::tools::Decoder,
}

impl ToolUseDecoder {
    pub fn new(model: &Model) -> Self {
        Self {
            inner: inferlet::tools::Decoder::new(model),
        }
    }

    pub fn feed(&mut self, tokens: &[u32]) -> Result<inferlet::tools::Event> {
        self.inner.feed(tokens)
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}

// =============================================================================
// Reasoning stub — wraps `inferlet::reasoning::Decoder`.
// =============================================================================

/// Streaming detector for thinking-block events (`<think>...`).
///
/// V1 stub: instantiated but not yet fed by the chat loop. Once the
/// chat handler emits OpenAI-shape `reasoning` deltas, this is the
/// decoder that surfaces them.
pub struct ReasoningDecoder {
    inner: inferlet::reasoning::Decoder,
}

impl ReasoningDecoder {
    pub fn new(model: &Model) -> Self {
        Self {
            inner: inferlet::reasoning::Decoder::new(model),
        }
    }

    pub fn feed(&mut self, tokens: &[u32]) -> Result<inferlet::reasoning::Event> {
        self.inner.feed(tokens)
    }

    #[allow(dead_code)]
    pub fn reset(&mut self) {
        self.inner.reset();
    }
}
