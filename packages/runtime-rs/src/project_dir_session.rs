use std::collections::{BTreeMap, BTreeSet};

pub type DirSessionMap = BTreeMap<String, Vec<String>>;

pub fn build_dir_session_map(
    sessions: impl IntoIterator<Item = (String, String)>,
) -> DirSessionMap {
    let mut map = BTreeMap::new();
    for (name, dir) in sessions {
        if dir.is_empty() {
            continue;
        }
        let names: &mut Vec<String> = map.entry(dir).or_default();
        if !names.contains(&name) {
            names.push(name);
        }
    }
    map
}

pub fn resolve_session_for_project_dir(
    project_dir: &str,
    dir_session_map: &DirSessionMap,
) -> Option<String> {
    let exact_matches = dir_session_map
        .get(project_dir)
        .map(|sessions| sessions.iter().cloned().collect::<BTreeSet<_>>())
        .unwrap_or_default();
    if !exact_matches.is_empty() {
        return unique_match(exact_matches);
    }

    let mut related_matches = BTreeSet::new();
    for (dir, sessions) in dir_session_map {
        if !project_dir.starts_with(&format!("{dir}/"))
            && !dir.starts_with(&format!("{project_dir}/"))
        {
            continue;
        }
        related_matches.extend(sessions.iter().cloned());
    }
    if !related_matches.is_empty() {
        return unique_match(related_matches);
    }

    let encoded = project_dir.strip_prefix("__encoded__:")?;

    let mut encoded_matches = BTreeSet::new();
    for (dir, sessions) in dir_session_map {
        if encode_project_dir(dir) != encoded {
            continue;
        }
        encoded_matches.extend(sessions.iter().cloned());
    }
    unique_match(encoded_matches)
}

/// All sessions whose directories are related to `project_dir` - either an
/// exact match or one directory containing the other. Callers can use this to
/// disambiguate when `resolve_session_for_project_dir` found more than one
/// candidate, for example when two live tmux sessions share the same start
/// directory and a project lives below it.
pub fn related_session_candidates(
    project_dir: &str,
    dir_session_map: &DirSessionMap,
) -> BTreeSet<String> {
    let mut candidates = BTreeSet::new();
    if let Some(sessions) = dir_session_map.get(project_dir) {
        candidates.extend(sessions.iter().cloned());
    }
    for (dir, sessions) in dir_session_map {
        if !project_dir.starts_with(&format!("{dir}/"))
            && !dir.starts_with(&format!("{project_dir}/"))
        {
            continue;
        }
        candidates.extend(sessions.iter().cloned());
    }
    candidates
}

fn unique_match(matches: BTreeSet<String>) -> Option<String> {
    if matches.len() == 1 {
        matches.into_iter().next()
    } else {
        None
    }
}

fn encode_project_dir(dir: &str) -> String {
    dir.chars()
        .map(|ch| {
            if matches!(ch, '/' | '.' | '_') {
                '-'
            } else {
                ch
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session_map(pairs: &[(&str, &str)]) -> DirSessionMap {
        build_dir_session_map(pairs.iter().map(|(name, dir)| (name.to_string(), dir.to_string())))
    }

    #[test]
    fn resolve_refuses_ambiguous_shared_parent_dirs() {
        let map = session_map(&[
            ("opencode-tolejarczuk", "/home/u"),
            ("test-db01", "/home/u"),
        ]);
        assert_eq!(
            resolve_session_for_project_dir("/home/u/.local/share/opencode", &map),
            None
        );
    }

    #[test]
    fn related_candidates_cover_every_session_sharing_the_parent_dir() {
        let map = session_map(&[
            ("opencode-tolejarczuk", "/home/u"),
            ("test-db01", "/home/u"),
            ("brportal", "/repos/brportal"),
        ]);
        let candidates = related_session_candidates("/home/u/.local/share/opencode", &map);
        assert_eq!(
            candidates,
            BTreeSet::from([
                "opencode-tolejarczuk".to_string(),
                "test-db01".to_string(),
            ])
        );
    }

    #[test]
    fn related_candidates_include_exact_dir_matches() {
        let map = session_map(&[("a", "/repo/x"), ("b", "/repo/x/sub")]);
        let candidates = related_session_candidates("/repo/x", &map);
        assert_eq!(
            candidates,
            BTreeSet::from(["a".to_string(), "b".to_string()])
        );
    }

    #[test]
    fn unique_dir_still_resolves_directly() {
        let map = session_map(&[("only", "/home/u"), ("other", "/repos/other")]);
        assert_eq!(
            resolve_session_for_project_dir("/home/u/.local/share/opencode", &map),
            Some("only".to_string())
        );
    }
}
