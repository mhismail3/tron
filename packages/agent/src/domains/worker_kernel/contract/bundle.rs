//! Complete model-discoverable schema for atomic worker authoring.
//!
//! Runtime decoding remains owned by `WorkerBundle`; this projection keeps the
//! atomic `worker_upsert` operation self-describing without a proposal,
//! installer, binding, or private source-documentation plane.

use serde_json::{Value, json};

pub(super) fn worker_bundle_schema() -> Value {
    let command = json!({
        "type":"object",
        "additionalProperties":false,
        "required":["command"],
        "properties":{
            "command":{
                "type":"array","minItems":1,"items":{"type":"string"},
                "description":"Exact program-and-argument vector; no shell parsing occurs. Worker source files are published as non-executable text, so invoke scripts through an explicit interpreter such as python3 or bash."
            },
            "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
        }
    });
    json!({
        "type":"object",
        "additionalProperties":false,
        "description":"Complete self-contained persistent worker bundle. No external proposal, installer, binding, or private source documentation is required.",
        "required":[
            "schemaVersion","name","description","inputSchema","outputSchema",
            "runner","provenance"
        ],
        "properties":{
            "schemaVersion":{
                "type":"string",
                "enum":["tron.worker_bundle.v1"],
                "description":"Version of the complete persistent-worker bundle contract."
            },
            "workerId":{
                "type":"string",
                "description":"Optional stable kebab-case identity. An existing id is updated directly; a new suggested id still yields to a near-identical semantic match."
            },
            "name":{"type":"string","minLength":1},
            "description":{
                "type":"string",
                "minLength":1,
                "description":"Explain when the agent should route work to this worker."
            },
            "toolName":{
                "type":"string",
                "description":"Optional stable direct tool name. Plain names are normalized to the worker_<name> namespace automatically; omit to retain the predecessor name or derive it from the worker name."
            },
            "inputSchema":{
                "type":"object",
                "description":"JSON object schema for typed worker input."
            },
            "outputSchema":{
                "type":"object",
                "description":"JSON object schema for typed worker output."
            },
            "runner":{
                "description":"Exactly one durable runner contract.",
                "oneOf":[
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","instructions"],
                        "properties":{
                            "kind":{"type":"string","enum":["agent"]},
                            "instructions":{"type":"string","minLength":1},
                            "model":{"type":"string"}
                        }
                    },
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","command"],
                        "properties":{
                            "kind":{"type":"string","enum":["command"]},
                            "command":{"type":"array","minItems":1,"items":{"type":"string"},"description":"Exact program-and-argument vector executed with files/ as the working directory; no shell parsing occurs. Worker source files are non-executable text, so invoke scripts through an explicit interpreter such as python3 or bash. Refer to a fetched dependency named N through ../dependencies/N."}
                        }
                    },
                    {
                        "type":"object","additionalProperties":false,
                        "required":["kind","command","invokeUrl"],
                        "properties":{
                            "kind":{"type":"string","enum":["service"]},
                            "command":{"type":"array","minItems":1,"items":{"type":"string"}},
                            "invokeUrl":{"type":"string"},
                            "healthUrl":{"type":"string"}
                        }
                    }
                ]
            },
            "files":{
                "type":"object",
                "description":"Relative source-file paths mapped to complete UTF-8 string contents. They are materialized as non-executable text beneath files/, the working directory for runner, smoke-test, and health-check commands. Script commands must name an explicit interpreter.",
                "additionalProperties":{"type":"string"}
            },
            "dependencies":{
                "type":"array",
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["name","source","version"],
                    "properties":{
                        "name":{"type":"string"},
                        "source":{"type":"string","description":"Use file:// for a local source, git+https:// for a repository, or http(s):// for one downloaded file. The acquired source is materialized at ../dependencies/<name> relative to files/."},
                        "version":{"type":"string","description":"Exact version or source revision; never latest or a range."},
                        "checksum":{"type":"string","description":"Optional expected sha256:<64 hex> source-tree digest. Omit it to let worker_upsert fetch the exact version and persist the actual digest automatically."},
                        "install":{
                            "type":"object",
                            "additionalProperties":false,
                            "required":["command"],
                            "description":"Optional isolated setup command executed with this dependency's ../dependencies/<name> directory as its working directory before smoke tests.",
                            "properties":{
                                "command":{"type":"array","minItems":1,"items":{"type":"string"}},
                                "timeoutSeconds":{"type":"integer","minimum":1,"maximum":7200}
                            }
                        }
                    }
                }
            },
            "triggers":{
                "type":"array",
                "items":{
                    "oneOf":[
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id"],
                            "properties":{
                                "kind":{"type":"string","enum":["manual"]},
                                "id":{"type":"string"}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id","everySeconds"],
                            "properties":{
                                "kind":{"type":"string","enum":["schedule"]},
                                "id":{"type":"string"},
                                "everySeconds":{"type":"integer","minimum":1},
                                "input":{}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id","topic"],
                            "properties":{
                                "kind":{"type":"string","enum":["engine_event"]},
                                "id":{"type":"string"},
                                "topic":{"type":"string","minLength":1},
                                "filter":{"type":"object"},
                                "input":{}
                            }
                        },
                        {
                            "type":"object","additionalProperties":false,
                            "required":["kind","id"],
                            "properties":{
                                "kind":{"type":"string","enum":["webhook"]},
                                "id":{"type":"string"},
                                "input":{}
                            }
                        }
                    ]
                }
            },
            "secretBindings":{
                "type":"array",
                "description":"Logical credential names only; use provider-<id> for a provider API key and never include secret values.",
                "items":{
                    "oneOf":[
                        {"type":"string"},
                        {
                            "type":"object","additionalProperties":false,
                            "required":["name"],
                            "properties":{
                                "name":{"type":"string"},
                                "required":{"type":"boolean"}
                            }
                        }
                    ]
                }
            },
            "smokeTests":{"type":"array","description":"Pre-activation commands executed from files/ after dependencies and their install commands are ready.","items":command},
            "healthChecks":{"type":"array","description":"Pre-activation commands executed from files/ after dependencies and their install commands are ready.","items":command},
            "engineHooks":{
                "type":"array",
                "uniqueItems":true,
                "description":"Optional semantic engine roles activated atomically with this version. No separate binding or grant is required. context_summary maps bounded visible messages to {narrative}; inbox_context consumes bounded unseen results into transient context; worker_relevance maps a task query and bounded candidate summaries to typed rankings.",
                "items":{"type":"string","enum":["context_summary","inbox_context","worker_relevance"]}
            },
            "provenance":{
                "type":"array","minItems":1,
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["source"],
                    "properties":{
                        "source":{"type":"string","minLength":1},
                        "revision":{"type":"string"},
                        "checksum":{"type":"string"}
                    }
                }
            },
            "presentation":{
                "type":"object",
                "additionalProperties":false,
                "required":["experienceId","contractVersion"],
                "description":"Optional immutable binding to a supported worker experience. Unknown or unsupported contracts fall back to the generic Worker Console.",
                "properties":{
                    "experienceId":{"type":"string","minLength":1},
                    "contractVersion":{"type":"integer","minimum":1},
                    "suiteId":{"type":"string","minLength":1},
                    "componentRole":{"type":"string","minLength":1},
                    "primary":{"type":"boolean"}
                }
            },
            "routing":{
                "type":"object","additionalProperties":false,
                "properties":{
                    "intents":{"type":"array","items":{"type":"string"}},
                    "examples":{"type":"array","items":{"type":"string"}}
                }
            }
        }
    })
}
