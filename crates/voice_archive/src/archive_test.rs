use std::{fmt::Write as _, fs, path::PathBuf};

use sha2::{Digest, Sha256};

use crate::{HistoryArchiveError, HistoryArchiveLimits, validate_history_archive};

#[test]
fn shared_swift_fixture_validates_portably() {
    let archive = validate_history_archive(&fixture_path(), HistoryArchiveLimits::default())
        .expect("The shared fixture must validate.");

    assert_eq!(
        archive.session_id,
        [0, 0, 0, 0, 0, 0, 64, 0, 128, 0, 0, 0, 0, 0, 0, 1]
    );
    assert_eq!(archive.result_count, 4);
    assert!(!archive.has_audio);
    assert_ne!(archive.manifest_sha256, [0; 32]);
}

#[test]
fn altered_manifest_fails_closed() {
    let temporary = temporary_archive();
    fs::write(temporary.join("manifest.json"), b"{}").expect("Manifest must be writable.");

    assert_eq!(
        validate_history_archive(&temporary, HistoryArchiveLimits::default()),
        Err(HistoryArchiveError::InvalidManifest)
    );
    fs::remove_dir_all(temporary).expect("Exact temporary archive must be removable.");
}

#[test]
fn undeclared_file_and_tight_cap_fail_closed() {
    let temporary = temporary_archive();
    fs::write(temporary.join("extra.txt"), b"extra").expect("Extra file must be writable.");
    assert_eq!(
        validate_history_archive(&temporary, HistoryArchiveLimits::default()),
        Err(HistoryArchiveError::InvalidInventory)
    );
    fs::remove_file(temporary.join("extra.txt")).expect("Extra file must be removable.");
    assert_eq!(
        validate_history_archive(
            &temporary,
            HistoryArchiveLimits {
                maximum_manifest_bytes: 1,
                ..HistoryArchiveLimits::default()
            }
        ),
        Err(HistoryArchiveError::LimitExceeded)
    );
    fs::remove_dir_all(temporary).expect("Exact temporary archive must be removable.");
}

#[test]
fn result_count_cap_is_a_typed_limit_failure() {
    assert_eq!(
        validate_history_archive(
            &fixture_path(),
            HistoryArchiveLimits {
                maximum_result_count: 1,
                ..HistoryArchiveLimits::default()
            }
        ),
        Err(HistoryArchiveError::LimitExceeded)
    );
}

#[cfg(unix)]
#[test]
fn symbolic_link_fails_closed() {
    use std::os::unix::fs::symlink;

    let temporary = temporary_archive();
    fs::remove_file(temporary.join("manifest.json")).expect("Manifest must be removable.");
    symlink(
        fixture_path().join("manifest.json"),
        temporary.join("manifest.json"),
    )
    .expect("Fixture link must be creatable.");

    assert_eq!(
        validate_history_archive(&temporary, HistoryArchiveLimits::default()),
        Err(HistoryArchiveError::InvalidInventory)
    );
    fs::remove_dir_all(temporary).expect("Exact temporary archive must be removable.");
}

#[test]
fn expired_audio_duration_without_payload_remains_valid_evidence() {
    let temporary = temporary_archive();
    let manifest_path = temporary.join("manifest.json");
    let mut manifest: serde_json::Value =
        serde_json::from_slice(&fs::read(&manifest_path).expect("Manifest must be readable."))
            .expect("Manifest fixture must be JSON.");
    manifest["audioDurationMilliseconds"] = serde_json::json!(100);
    manifest["audioExpiredAt"] = serde_json::json!("1970-01-01T00:33:21Z");
    manifest["audioExpirationReason"] = serde_json::json!("age_limit");
    let manifest_bytes = serde_json::to_vec(&manifest).expect("Manifest must encode.");
    fs::write(&manifest_path, &manifest_bytes).expect("Manifest must be writable.");
    let digest = Sha256::digest(&manifest_bytes);
    let mut digest_hex = String::with_capacity(64);
    for byte in digest {
        write!(digest_hex, "{byte:02x}").expect("String writes cannot fail.");
    }
    let checksum_path = temporary.join("checksums.json");
    let mut checksums: serde_json::Value =
        serde_json::from_slice(&fs::read(&checksum_path).expect("Checksums must be readable."))
            .expect("Checksum fixture must be JSON.");
    checksums["files"]["manifest.json"] = serde_json::json!(digest_hex);
    fs::write(
        &checksum_path,
        serde_json::to_vec(&checksums).expect("Checksums must encode."),
    )
    .expect("Checksums must be writable.");

    assert!(validate_history_archive(&temporary, HistoryArchiveLimits::default()).is_ok());
    fs::remove_dir_all(temporary).expect("Exact temporary archive must be removable.");
}

fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/cuj/voice_history_archive_v1/valid")
}

fn temporary_archive() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "hardware_controller_voice_archive_{}_{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    fs::create_dir(&path).expect("Temporary archive must be creatable.");
    for name in ["manifest.json", "checksums.json"] {
        fs::copy(fixture_path().join(name), path.join(name))
            .expect("Fixture file must be copyable.");
    }
    path
}
