//! Bounded, language-neutral Voice History archive verification.

mod archive;

pub use archive::{
    HistoryArchiveError, HistoryArchiveLimits, ValidatedHistoryArchive, validate_history_archive,
};

#[cfg(test)]
mod archive_test;
