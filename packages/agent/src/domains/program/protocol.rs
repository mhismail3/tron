//! JSON-line protocol between the parent engine process and program worker.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::runtime::{ProgramRunRequest, ProgramRunResult};

pub(super) const PROGRAM_WORKER_PROTOCOL_VERSION: u16 = 1;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum ParentToProgramWorker {
    Run {
        request: Box<ProgramRunRequest>,
    },
    HostResult {
        id: String,
        value: Value,
    },
    HostError {
        id: String,
        code: String,
        message: String,
        details: Option<Value>,
    },
    Cancel {
        reason: String,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub(super) enum ProgramWorkerToParent {
    Ready {
        protocol_version: u16,
    },
    HostCall {
        id: String,
        payload: Value,
    },
    Result {
        result: Box<ProgramRunResult>,
    },
    WorkerError {
        code: String,
        message: String,
        details: Option<Value>,
    },
}
