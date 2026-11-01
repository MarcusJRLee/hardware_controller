use std::fs;

use crate::model_package_test_support::{TemporaryPackage, limits};
use crate::{ASRModelError, ModelPackageError, resolve_file_asr_model, validate_model_package};

#[test]
fn file_package_is_revalidated_and_resolved_to_its_model_payload() {
    let package = transcribe_package();
    let validated = validate_model_package(package.path(), limits(), None).expect("valid package");

    let resolved = resolve_file_asr_model(package.path(), limits(), validated.manifest_sha256)
        .expect("compatible package");

    assert_eq!(resolved.package_id, validated.package_id);
    assert_eq!(resolved.version, validated.version);
    assert_eq!(resolved.manifest_sha256, validated.manifest_sha256);
    assert_eq!(resolved.model_path, package.path().join("model.bin"));
    assert_eq!(resolved.speech_detection_path, None);
}

#[test]
fn optional_speech_detection_payload_resolves_and_must_be_unique() {
    let package = transcribe_package();
    add_model_copy(&package, "speech.bin", "speech_detection");
    let resolved = resolve_file_asr_model(package.path(), limits(), validated_digest(&package))
        .expect("compatible package");
    assert_eq!(
        resolved.speech_detection_path,
        Some(package.path().join("speech.bin"))
    );

    add_model_copy(&package, "speech_2.bin", "speech_detection");
    assert_eq!(
        resolve_file_asr_model(package.path(), limits(), validated_digest(&package)),
        Err(ASRModelError::AmbiguousSpeechDetectionPayload)
    );
}

#[test]
fn retired_whisper_cpp_packages_fail_closed() {
    let package = TemporaryPackage::copy_fixture();
    package.replace_manifest(
        "\"runtime\": \"sherpa_onnx\"",
        "\"runtime\": \"whisper_cpp\"",
    );
    assert_eq!(
        resolve_file_asr_model(package.path(), limits(), validated_digest(&package)),
        Err(ASRModelError::UnsupportedRuntime)
    );
}

#[test]
fn wrong_runtime_stage_capability_and_ambiguous_payload_fail_closed() {
    let sherpa = TemporaryPackage::copy_fixture();
    let sherpa_digest = validated_digest(&sherpa);
    assert_eq!(
        resolve_file_asr_model(sherpa.path(), limits(), sherpa_digest),
        Err(ASRModelError::UnsupportedRuntime)
    );

    let formatting = transcribe_package();
    formatting.replace_manifest("\"stage\": \"asr\"", "\"stage\": \"formatting\"");
    formatting.replace_manifest("\"streaming_asr\", \"file_asr\"", "\"formatting\"");
    formatting.replace_manifest("[\"en-US\"]", "[]");
    let formatting_digest = validated_digest(&formatting);
    assert_eq!(
        resolve_file_asr_model(formatting.path(), limits(), formatting_digest),
        Err(ASRModelError::UnsupportedStage)
    );

    let streaming_only = transcribe_package();
    streaming_only.replace_manifest(", \"file_asr\"", "");
    let streaming_digest = validated_digest(&streaming_only);
    assert_eq!(
        resolve_file_asr_model(streaming_only.path(), limits(), streaming_digest),
        Err(ASRModelError::MissingFileCapability)
    );

    let ambiguous = transcribe_package();
    add_model_copy(&ambiguous, "second.bin", "model");
    let ambiguous_digest = validated_digest(&ambiguous);
    assert_eq!(
        resolve_file_asr_model(ambiguous.path(), limits(), ambiguous_digest),
        Err(ASRModelError::AmbiguousModelPayload)
    );
}

#[test]
fn digest_or_payload_tampering_is_rejected_before_runtime_load() {
    let package = transcribe_package();
    let digest = validated_digest(&package);
    assert_eq!(
        resolve_file_asr_model(package.path(), limits(), [0; 32]),
        Err(ASRModelError::Package(
            ModelPackageError::ManifestDigestMismatch
        ))
    );

    fs::write(package.path().join("model.bin"), b"tampered").expect("tamper model");
    assert!(matches!(
        resolve_file_asr_model(package.path(), limits(), digest),
        Err(ASRModelError::Package(
            ModelPackageError::FileSizeMismatch { .. } | ModelPackageError::DigestMismatch { .. }
        ))
    ));
}

fn transcribe_package() -> TemporaryPackage {
    let package = TemporaryPackage::copy_fixture();
    package.replace_manifest(
        "\"runtime\": \"sherpa_onnx\"",
        "\"runtime\": \"transcribe_cpp\"",
    );
    package
}

/// Adds a byte-identical copy of the fixture model under `role`.
fn add_model_copy(package: &TemporaryPackage, path: &str, role: &str) {
    let model_bytes = fs::read(package.path().join("model.bin")).expect("model bytes");
    fs::write(package.path().join(path), model_bytes).expect("model copy");
    package.replace_manifest(
        "    {\n      \"path\": \"NOTICE.txt\"",
        &format!(
            concat!(
                "    {{\n",
                "      \"path\": \"{}\",\n",
                "      \"role\": \"{}\",\n",
                "      \"bytes\": 23,\n",
                "      \"sha256\": \"74bf05e43882d7e6927225973333f3cdd0acbb27d9bfed3f64a2a14512825904\"\n",
                "    }},\n",
                "    {{\n",
                "      \"path\": \"NOTICE.txt\""
            ),
            path, role
        ),
    );
}

fn validated_digest(package: &TemporaryPackage) -> [u8; 32] {
    let validated = validate_model_package(package.path(), limits(), None).expect("valid package");
    validated.manifest_sha256
}
