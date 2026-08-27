use std::fs;

use crate::model_package_test_support::{TemporaryPackage, fixture_path, limits};
use crate::{
    ModelCapability, ModelPackageError, ModelPackageLimits, ModelRuntime, ModelStage,
    validate_model_package,
};

#[test]
fn valid_package_verifies_identity_capabilities_license_and_every_file() {
    let package = validate_model_package(&fixture_path(), limits(), None)
        .expect("The complete digest-pinned fixture must validate.");

    assert_eq!(package.package_id, "com.longdevity.fixture.streaming_asr");
    assert_eq!(package.version, "1.0.0");
    assert_eq!(package.display_name, "Fixture Streaming ASR");
    assert_eq!(package.runtime, ModelRuntime::SherpaOnnx);
    assert_eq!(package.stage, ModelStage::Asr);
    assert_eq!(
        package.capabilities,
        [ModelCapability::StreamingAsr, ModelCapability::FileAsr]
    );
    assert_eq!(package.languages, ["en-US"]);
    assert_eq!(package.license.spdx_expression, "Apache-2.0");
    assert_eq!(package.license.notice_file, "NOTICE.txt");
    assert_eq!(package.file_count, 2);
    assert_eq!(package.verified_bytes, 73);
    assert_ne!(package.manifest_sha256, [0; 32]);
    assert_eq!(
        validate_model_package(&fixture_path(), limits(), Some(package.manifest_sha256)),
        Ok(package)
    );
    assert_eq!(
        validate_model_package(&fixture_path(), limits(), Some([0; 32])),
        Err(ModelPackageError::ManifestDigestMismatch)
    );
}

#[test]
fn installed_byte_and_file_count_limits_are_independent() {
    assert_eq!(
        ModelPackageLimits::default(),
        ModelPackageLimits {
            maximum_manifest_bytes: 1_048_576,
            maximum_installed_bytes: 8 * 1_024 * 1_024 * 1_024,
            maximum_file_count: 4_096,
        }
    );
    assert_eq!(
        validate_model_package(
            &fixture_path(),
            ModelPackageLimits {
                maximum_manifest_bytes: 1,
                maximum_installed_bytes: 1_048_576,
                maximum_file_count: 16,
            },
            None,
        ),
        Err(ModelPackageError::ManifestBytesExceeded)
    );
    assert_eq!(
        validate_model_package(
            &fixture_path(),
            ModelPackageLimits {
                maximum_manifest_bytes: 1_048_576,
                maximum_installed_bytes: 72,
                maximum_file_count: 16,
            },
            None,
        ),
        Err(ModelPackageError::InstalledBytesExceeded)
    );
    assert_eq!(
        validate_model_package(
            &fixture_path(),
            ModelPackageLimits {
                maximum_manifest_bytes: 1_048_576,
                maximum_installed_bytes: 1_048_576,
                maximum_file_count: 1,
            },
            None,
        ),
        Err(ModelPackageError::FileCountExceeded)
    );
}

#[test]
fn traversal_duplicate_capability_and_stage_mismatch_are_rejected() {
    let cases = [
        (
            "../model.bin",
            ModelPackageError::InvalidFilePath {
                path: "../model.bin".into(),
            },
        ),
        (
            "model.bin",
            ModelPackageError::DuplicateFilePath {
                path: "model.bin".into(),
            },
        ),
    ];

    for (replacement, expected) in cases {
        let temporary = TemporaryPackage::copy_fixture();
        let manifest_path = temporary.path().join("manifest.json");
        let manifest = fs::read_to_string(&manifest_path).expect("The manifest must be readable.");
        let marker = "\"path\": \"NOTICE.txt\"";
        fs::write(
            &manifest_path,
            manifest.replacen(marker, &format!("\"path\": \"{replacement}\""), 1),
        )
        .expect("The manifest must be writable.");
        assert_eq!(
            validate_model_package(temporary.path(), limits(), None),
            Err(expected)
        );
    }

    let duplicate_capability = TemporaryPackage::copy_fixture();
    duplicate_capability.replace_manifest("\"file_asr\"", "\"streaming_asr\"");
    assert_eq!(
        validate_model_package(duplicate_capability.path(), limits(), None),
        Err(ModelPackageError::DuplicateCapability)
    );

    let mismatched_stage = TemporaryPackage::copy_fixture();
    mismatched_stage.replace_manifest("\"stage\": \"asr\"", "\"stage\": \"formatting\"");
    assert_eq!(
        validate_model_package(mismatched_stage.path(), limits(), None),
        Err(ModelPackageError::CapabilityStageMismatch)
    );

    let nonportable_path = TemporaryPackage::copy_fixture();
    nonportable_path.replace_manifest("NOTICE.txt", "assets//NOTICE.txt");
    assert_eq!(
        validate_model_package(nonportable_path.path(), limits(), None),
        Err(ModelPackageError::InvalidFilePath {
            path: "assets//NOTICE.txt".into()
        })
    );

    let duplicate_language = TemporaryPackage::copy_fixture();
    duplicate_language.replace_manifest("[\"en-US\"]", "[\"en-US\", \"EN-us\"]");
    assert_eq!(
        validate_model_package(duplicate_language.path(), limits(), None),
        Err(ModelPackageError::DuplicateLanguage)
    );

    let empty_payload = TemporaryPackage::copy_fixture();
    empty_payload.replace_manifest("\"bytes\": 23", "\"bytes\": 0");
    assert_eq!(
        validate_model_package(empty_payload.path(), limits(), None),
        Err(ModelPackageError::InvalidFileSize {
            path: "model.bin".into()
        })
    );

    let invalid_source = TemporaryPackage::copy_fixture();
    invalid_source.replace_manifest("https://example.invalid/voice-model-fixture", "https://");
    assert_eq!(
        validate_model_package(invalid_source.path(), limits(), None),
        Err(ModelPackageError::InvalidLicense)
    );
}
