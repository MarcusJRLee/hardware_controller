use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};

use crate::ModelPackageLimits;

static NEXT_TEMPORARY_DIRECTORY: AtomicU64 = AtomicU64::new(0);

pub(crate) fn fixture_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../Tests/cuj/voice_model_package_v1/valid")
}

pub(crate) const fn limits() -> ModelPackageLimits {
    ModelPackageLimits {
        maximum_manifest_bytes: 1_048_576,
        maximum_installed_bytes: 1_048_576,
        maximum_file_count: 16,
    }
}

pub(crate) struct TemporaryPackage {
    path: PathBuf,
}

impl TemporaryPackage {
    pub(crate) fn copy_fixture() -> Self {
        let identifier = NEXT_TEMPORARY_DIRECTORY.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "hardware_controller_voice_model_package_{}_{}",
            std::process::id(),
            identifier
        ));
        fs::create_dir(&path).expect("The temporary package must be creatable.");
        for name in ["manifest.json", "model.bin", "NOTICE.txt"] {
            fs::copy(fixture_path().join(name), path.join(name))
                .expect("The fixture file must be copyable.");
        }
        Self { path }
    }

    pub(crate) fn path(&self) -> &Path {
        &self.path
    }

    pub(crate) fn replace_manifest(&self, from: &str, to: &str) {
        let path = self.path.join("manifest.json");
        let manifest = fs::read_to_string(&path).expect("The manifest must be readable.");
        fs::write(path, manifest.replacen(from, to, 1)).expect("The manifest must be writable.");
    }
}

impl Drop for TemporaryPackage {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
