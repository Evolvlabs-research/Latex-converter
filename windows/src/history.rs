// Historique des versions : copies datées de chaque fichier, rangées hors du projet
// dans %APPDATA%\Nabla\Historique\<projet>\<fichier>\. Pendant de History.swift.
use std::{
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

/// Dossier de Nabla : %APPDATA% (données gardées) ou %LOCALAPPDATA% (cache) sous Windows.
pub fn app_dir(cache: bool) -> PathBuf {
    let var = if cfg!(windows) {
        if cache { "LOCALAPPDATA" } else { "APPDATA" }
    } else {
        "HOME"
    };
    let base = std::env::var_os(var).map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    if cfg!(windows) {
        base.join("Nabla")
    } else {
        base.join(if cache { ".cache/nabla" } else { ".local/share/nabla" })
    }
}

/// Un chemin en un seul nom de dossier : « C:\Users\a » -> « C__Users_a ».
pub fn flat(path: &str) -> String {
    path.replace(['/', '\\', ':'], "_")
}

#[derive(Clone, PartialEq, Debug)]
pub struct Snapshot {
    pub path: PathBuf,
    pub date: SystemTime,
}

impl Snapshot {
    pub fn text(&self) -> String {
        std::fs::read_to_string(&self.path).unwrap_or_default()
    }
}

pub fn history_dir(root: &Path, file: &str) -> PathBuf {
    app_dir(false)
        .join("Historique")
        .join(flat(&root.to_string_lossy()))
        .join(flat(file))
}

/// Versions d'un fichier, la plus récente d'abord. Le nom de chaque copie est sa date en nanosecondes.
pub fn snapshots(root: &Path, file: &str) -> Vec<Snapshot> {
    let mut list: Vec<(u128, Snapshot)> = std::fs::read_dir(history_dir(root, file))
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|e| {
            let nanos: u128 = e.path().file_stem()?.to_str()?.parse().ok()?;
            let date = UNIX_EPOCH + Duration::from_nanos(u64::try_from(nanos).ok()?);
            Some((nanos, Snapshot { path: e.path(), date }))
        })
        .collect();
    list.sort_by(|a, b| b.0.cmp(&a.0));
    list.into_iter().map(|(_, s)| s).collect()
}

/// Enregistre une version si elle diffère de la dernière et que celle-ci date d'au moins `min_interval`.
/// Garde les 200 plus récentes.
pub fn save_snapshot(text: &str, root: &Path, file: &str, min_interval: Duration, now: SystemTime) -> bool {
    let existing = snapshots(root, file);
    if let Some(last) = existing.first() {
        // Le délai d'abord : il évite de relire la dernière version à chaque frappe.
        if now.duration_since(last.date).unwrap_or_default() < min_interval || last.text() == text {
            return false;
        }
    }
    let dir = history_dir(root, file);
    let mut nanos = now.duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
    if let Some(last) = existing.first() {
        // deux versions dans la même nanoseconde (horloge grossière) : la nouvelle passe après
        let last_nanos = last.date.duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
        nanos = nanos.max(last_nanos + 1);
    }
    if std::fs::create_dir_all(&dir).is_err() || std::fs::write(dir.join(format!("{nanos:020}.txt")), text).is_err() {
        return false;
    }
    for old in existing.iter().skip(199) {
        let _ = std::fs::remove_file(&old.path);
    }
    true
}
