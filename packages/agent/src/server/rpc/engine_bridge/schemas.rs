use serde_json::{Value, json};

pub(super) fn request_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "required": ["protocolVersion"],
            "additionalProperties": false,
            "properties": {
                "protocolVersion": {"type": "integer"},
                "clientVersion": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "workingDirectory": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.getHistory" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "limit": {"type": "integer"},
                "types": {"type": "array", "items": {"type": "string"}},
                "beforeEventId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "events.getSince" => json!({
            "type": "object",
            "required": ["sessionId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "afterEventId": {"type": "string"},
                "afterSequence": {"type": "integer"},
                "limit": {"type": "integer"},
                "workspaceId": {"type": "string"}
            }
        }),
        "filesystem.getHome" | "promptSnippet.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings.get" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {}
        }),
        "settings.update" => json!({
            "type": "object",
            "required": ["settings"],
            "additionalProperties": false,
            "properties": {
                "settings": {"type": "object", "additionalProperties": true},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "settings.resetToDefaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "model.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__rpcContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "authPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.list" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "limit": {"type": "integer"},
                "cursor": {"type": "string"},
                "query": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptHistory.clear" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.get" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.create" => json!({
            "type": "object",
            "required": ["name", "text"],
            "additionalProperties": false,
            "properties": {
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.update" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "name": {"type": "string"},
                "text": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "promptSnippet.delete" => json!({
            "type": "object",
            "required": ["id"],
            "additionalProperties": false,
            "properties": {
                "id": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        "system.getInfo" => json!({
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "__rpcContext": {
                    "type": "object",
                    "additionalProperties": false,
                    "properties": {
                        "onboardedMarkerPath": {"type": "string"}
                    }
                },
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }),
        _ => return None,
    })
}

pub(super) fn response_schema_for_method(method: &str) -> Option<Value> {
    Some(match method {
        "system.ping" => json!({
            "type": "object",
            "required": [
                "pong",
                "timestamp",
                "serverVersion",
                "serverProtocolVersion",
                "minClientProtocolVersion",
                "compatible"
            ],
            "additionalProperties": false,
            "properties": {
                "pong": {"type": "boolean"},
                "timestamp": {"type": "string"},
                "serverVersion": {"type": "string"},
                "serverProtocolVersion": {"type": "integer"},
                "minClientProtocolVersion": {"type": "integer"},
                "compatible": {"type": "boolean"}
            }
        }),
        "system.getInfo" => json!({
            "type": "object",
            "required": [
                "version",
                "uptime",
                "activeSessions",
                "platform",
                "arch",
                "runtime",
                "port",
                "tailscaleIp",
                "paired"
            ],
            "additionalProperties": false,
            "properties": {
                "version": {"type": "string"},
                "uptime": {"type": "integer"},
                "activeSessions": {"type": "integer"},
                "platform": {"type": "string"},
                "arch": {"type": "string"},
                "runtime": {"type": "string"},
                "port": {"type": "integer"},
                "tailscaleIp": {"type": ["string", "null"]},
                "paired": {"type": "boolean"}
            }
        }),
        "settings.get" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "settings.update" => json!({
            "type": "object",
            "required": ["success"],
            "additionalProperties": false,
            "properties": {
                "success": {"type": "boolean"}
            }
        }),
        "settings.resetToDefaults" => json!({
            "type": "object",
            "additionalProperties": true
        }),
        "model.list" => json!({
            "type": "object",
            "required": ["models"],
            "additionalProperties": false,
            "properties": {
                "models": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "skill.list" => json!({
            "type": "object",
            "required": ["skills"],
            "additionalProperties": false,
            "properties": {
                "skills": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                }
            }
        }),
        "logs.recent" => json!({
            "type": "object",
            "required": ["entries", "count"],
            "additionalProperties": false,
            "properties": {
                "entries": {
                    "type": "array",
                    "items": {"type": "object", "additionalProperties": true}
                },
                "count": {"type": "integer"}
            }
        }),
        "events.getHistory" => json!({
            "type": "object",
            "required": ["sessionId", "events", "hasMore", "oldestEventId"],
            "additionalProperties": false,
            "properties": {
                "sessionId": {"type": "string"},
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "oldestEventId": {"type": ["string", "null"]}
            }
        }),
        "events.getSince" => json!({
            "type": "object",
            "required": ["events", "hasMore", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "events": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "hasMore": {"type": "boolean"},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "filesystem.getHome" => json!({
            "type": "object",
            "required": ["homePath", "suggestedPaths"],
            "additionalProperties": false,
            "properties": {
                "homePath": {"type": "string"},
                "suggestedPaths": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "required": ["name", "path", "exists"],
                        "additionalProperties": false,
                        "properties": {
                            "name": {"type": "string"},
                            "path": {"type": "string"},
                            "exists": {"type": "boolean"}
                        }
                    }
                }
            }
        }),
        "promptHistory.list" => json!({
            "type": "object",
            "required": ["items", "nextCursor"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
                "nextCursor": {"type": ["string", "null"]}
            }
        }),
        "promptHistory.delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        "promptHistory.clear" => json!({
            "type": "object",
            "required": ["deletedCount"],
            "additionalProperties": false,
            "properties": {
                "deletedCount": {"type": "integer"}
            }
        }),
        "promptSnippet.list" => json!({
            "type": "object",
            "required": ["items"],
            "additionalProperties": false,
            "properties": {
                "items": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
            }
        }),
        "promptSnippet.get" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "promptSnippet.create" | "promptSnippet.update" => json!({
            "type": "object",
            "required": ["snippet"],
            "additionalProperties": false,
            "properties": {
                "snippet": {"type": "object", "additionalProperties": true}
            }
        }),
        "promptSnippet.delete" => json!({
            "type": "object",
            "required": ["deleted"],
            "additionalProperties": false,
            "properties": {
                "deleted": {"type": "boolean"}
            }
        }),
        _ => return None,
    })
}
