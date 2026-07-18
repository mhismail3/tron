//! Shared bundled A2UI definitions.

use super::model::NativeUIDefinition;

const SETTINGS: &str = include_str!("../../../../native-ui-definitions/settings.engine.json");
const COMPACTION: &str =
    include_str!("../../../../native-ui-definitions/session.compaction_detail.json");
const LAB: &str = include_str!("../../../../native-ui-definitions/lab.catalog.json");

pub(crate) fn definition(definition_id: &str) -> Option<NativeUIDefinition> {
    let source = match definition_id {
        "settings.engine" => SETTINGS,
        "session.compaction_detail" => COMPACTION,
        "lab.catalog" => LAB,
        _ => return None,
    };
    serde_json::from_str(source).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn all_bundled_definitions_decode() {
        for id in [
            "settings.engine",
            "session.compaction_detail",
            "lab.catalog",
        ] {
            let definition = definition(id).expect("bundled definition");
            assert_eq!(definition.definition_id, id);
        }
    }
}
