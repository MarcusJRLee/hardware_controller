//! Portable Voice domain policy shared by platform applications.

mod retention;

pub use retention::{
    AudioExpirationReason, RetentionCandidate, RetentionDecision, RetentionError, RetentionPlan,
    RetentionSettings, SessionId, plan_retention,
};

#[cfg(test)]
mod retention_test;
