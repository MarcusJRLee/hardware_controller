use std::fs;

use crate::model_package_test_support::{TemporaryPackage, fixture_path, limits};
use crate::{ModelPackageError, validate_model_package};

#[test]
fn tampered_and_undeclared_payloads_fail_closed() {
    let tampered = TemporaryPackage::copy_fixture();
    let model_path = tampered.path().join("model.bin");
    let mut bytes = fs::read(&model_path).expect("The test model must be readable.");
    bytes[0] ^= 1;
    fs::write(model_path, bytes).expect("The test package must be writable.");
    assert_eq!(
        validate_model_package(tampered.path(), limits(), None),
        Err(ModelPackageError::DigestMismatch {
            path: "model.bin".into()
        })
    );

    let truncated = TemporaryPackage::copy_fixture();
    fs::write(truncated.path().join("model.bin"), b"short")
        .expect("The test package must be writable.");
    assert_eq!(
        validate_model_package(truncated.path(), limits(), None),
        Err(ModelPackageError::FileSizeMismatch {
            path: "model.bin".into()
        })
    );

    let extra_file = TemporaryPackage::copy_fixture();
    fs::write(extra_file.path().join("surprise.bin"), b"undeclared\n")
        .expect("The test package must be writable.");
    assert_eq!(
        validate_model_package(extra_file.path(), limits(), None),
        Err(ModelPackageError::UndeclaredFile {
            path: "surprise.bin".into()
        })
    );

    let extra_directory = TemporaryPackage::copy_fixture();
    fs::create_dir(extra_directory.path().join("surprise_directory"))
        .expect("The test directory must be creatable.");
    assert_eq!(
        validate_model_package(extra_directory.path(), limits(), None),
        Err(ModelPackageError::UndeclaredDirectory {
            path: "surprise_directory".into()
        })
    );
}

#[test]
fn declared_nested_directories_are_accepted() {
    let nested = TemporaryPackage::copy_fixture();
    fs::create_dir(nested.path().join("models")).expect("The model directory must be creatable.");
    fs::rename(
        nested.path().join("model.bin"),
        nested.path().join("models/model.bin"),
    )
    .expect("The model fixture must be movable.");
    nested.replace_manifest("model.bin", "models/model.bin");

    let package = validate_model_package(nested.path(), limits(), None)
        .expect("Declared package directories must validate.");
    assert_eq!(package.file_count, 2);
    assert_eq!(package.verified_bytes, 73);
}

#[cfg(unix)]
#[test]
fn symbolic_links_are_rejected() {
    use std::os::unix::fs::symlink;

    let temporary = TemporaryPackage::copy_fixture();
    fs::remove_file(temporary.path().join("model.bin")).expect("The fixture model must exist.");
    symlink(
        fixture_path().join("model.bin"),
        temporary.path().join("model.bin"),
    )
    .expect("The test symlink must be creatable.");

    assert_eq!(
        validate_model_package(temporary.path(), limits(), None),
        Err(ModelPackageError::SymbolicLink {
            path: "model.bin".into()
        })
    );
}
