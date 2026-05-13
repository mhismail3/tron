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
        primitive: WorkerToolPrimitive,
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

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum WorkerToolPrimitive {
    Search,
    Inspect,
    Execute,
}

impl From<super::runtime::ProgramToolPrimitive> for WorkerToolPrimitive {
    fn from(value: super::runtime::ProgramToolPrimitive) -> Self {
        match value {
            super::runtime::ProgramToolPrimitive::Search => Self::Search,
            super::runtime::ProgramToolPrimitive::Inspect => Self::Inspect,
            super::runtime::ProgramToolPrimitive::Execute => Self::Execute,
        }
    }
}

impl From<WorkerToolPrimitive> for super::runtime::ProgramToolPrimitive {
    fn from(value: WorkerToolPrimitive) -> Self {
        match value {
            WorkerToolPrimitive::Search => Self::Search,
            WorkerToolPrimitive::Inspect => Self::Inspect,
            WorkerToolPrimitive::Execute => Self::Execute,
        }
    }
}
