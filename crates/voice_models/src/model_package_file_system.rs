use std::{
    collections::BTreeSet,
    fmt,
    fs::{self, File},
    io::{BufReader, Read},
    path::{Component, Path},
};

use sha2::{Digest, Sha256};

use crate::model_package::{ManifestFile, ModelPackageError};

const MANIFEST_FILE: &str = "manifest.json";

pub(crate) fn read_manifest(root: &Path, maximum_bytes: u64) -> Result<Vec<u8>, ModelPackageError> {
    let root_metadata =
        fs::symlink_metadata(root).map_err(|_| ModelPackageError::InvalidPackageRoot)?;
    if root_metadata.file_type().is_symlink() || !root_metadata.is_dir() {
        return Err(ModelPackageError::InvalidPackageRoot);
    }

    let path = root.join(MANIFEST_FILE);
    let metadata =
        fs::symlink_metadata(&path).map_err(|_| ModelPackageError::InvalidManifestFile)?;
    if metadata.file_type().is_symlink() || !metadata.is_file() {
        return Err(ModelPackageError::InvalidManifestFile);
    }
    if metadata.len() > maximum_bytes {
        return Err(ModelPackageError::ManifestBytesExceeded);
    }

    let file = File::open(path).map_err(|_| ModelPackageError::Io)?;
    let mut bytes = Vec::new();
    file.take(maximum_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| ModelPackageError::Io)?;
    let actual_bytes =
        u64::try_from(bytes.len()).map_err(|_| ModelPackageError::ManifestBytesExceeded)?;
    if actual_bytes > maximum_bytes {
        return Err(ModelPackageError::ManifestBytesExceeded);
    }
    Ok(bytes)
}

pub(crate) fn validate_relative_path(value: &str) -> Result<(), ModelPackageError> {
    let invalid = value.is_empty()
        || value.len() > 1_024
        || value == MANIFEST_FILE
        || value.contains('\\')
        || value.contains(':')
        || value.chars().any(char::is_control)
        || value.split('/').any(|segment| {
            segment.is_empty() || segment == "." || segment == ".." || segment.len() > 255
        })
        || Path::new(value)
            .components()
            .any(|component| !matches!(component, Component::Normal(_)));
    if invalid {
        return Err(ModelPackageError::InvalidFilePath {
            path: value.to_owned(),
        });
    }
    Ok(())
}

pub(crate) fn is_lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub(crate) fn declared_directories(paths: &BTreeSet<String>) -> BTreeSet<String> {
    let mut directories = BTreeSet::new();
    for path in paths {
        let segments: Vec<_> = path.split('/').collect();
        for length in 1..segments.len() {
            directories.insert(segments[..length].join("/"));
        }
    }
    directories
}

pub(crate) fn verify_inventory(
    root: &Path,
    declared_paths: &BTreeSet<String>,
    declared_directories: &BTreeSet<String>,
) -> Result<(), ModelPackageError> {
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        let entries = fs::read_dir(&directory).map_err(|_| ModelPackageError::Io)?;
        for entry in entries {
            let entry = entry.map_err(|_| ModelPackageError::Io)?;
            let path = entry.path();
            let relative = portable_relative_path(root, &path)?;
            let file_type = entry.file_type().map_err(|_| ModelPackageError::Io)?;
            if file_type.is_symlink() {
                return Err(ModelPackageError::SymbolicLink { path: relative });
            }
            if file_type.is_dir() {
                if !declared_directories.contains(&relative) {
                    return Err(ModelPackageError::UndeclaredDirectory { path: relative });
                }
                pending.push(path);
            } else if file_type.is_file()
                && relative != MANIFEST_FILE
                && !declared_paths.contains(&relative)
            {
                return Err(ModelPackageError::UndeclaredFile { path: relative });
            } else if !file_type.is_file() {
                return Err(ModelPackageError::MissingFile { path: relative });
            }
        }
    }
    Ok(())
}

pub(crate) fn verify_file(root: &Path, file: &ManifestFile) -> Result<(), ModelPackageError> {
    let path = root.join(&file.path);
    let metadata = fs::symlink_metadata(&path).map_err(|_| ModelPackageError::MissingFile {
        path: file.path.clone(),
    })?;
    if metadata.file_type().is_symlink() {
        return Err(ModelPackageError::SymbolicLink {
            path: file.path.clone(),
        });
    }
    if !metadata.is_file() {
        return Err(ModelPackageError::MissingFile {
            path: file.path.clone(),
        });
    }
    if metadata.len() != file.bytes {
        return Err(ModelPackageError::FileSizeMismatch {
            path: file.path.clone(),
        });
    }

    let actual = sha256(&path)?;
    if actual != file.sha256 {
        return Err(ModelPackageError::DigestMismatch {
            path: file.path.clone(),
        });
    }
    Ok(())
}

pub(crate) fn sha256_bytes(bytes: &[u8]) -> [u8; 32] {
    let digest = Sha256::digest(bytes);
    let mut result = [0_u8; 32];
    result.copy_from_slice(&digest);
    result
}

fn portable_relative_path(root: &Path, path: &Path) -> Result<String, ModelPackageError> {
    let relative = path.strip_prefix(root).map_err(|_| ModelPackageError::Io)?;
    let mut components = Vec::new();
    for component in relative.components() {
        let Component::Normal(value) = component else {
            return Err(ModelPackageError::Io);
        };
        components.push(value.to_str().ok_or(ModelPackageError::Io)?);
    }
    Ok(components.join("/"))
}

fn sha256(path: &Path) -> Result<String, ModelPackageError> {
    let file = File::open(path).map_err(|_| ModelPackageError::Io)?;
    let mut reader = BufReader::new(file);
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 8 * 1_024];
    loop {
        let count = reader
            .read(&mut buffer)
            .map_err(|_| ModelPackageError::Io)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    let digest = hasher.finalize();
    let mut encoded = String::with_capacity(64);
    for byte in digest {
        use fmt::Write;
        write!(encoded, "{byte:02x}").map_err(|_| ModelPackageError::Io)?;
    }
    Ok(encoded)
}
