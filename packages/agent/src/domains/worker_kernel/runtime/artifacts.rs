//! Authenticated native Artifact Inbox operations.

use super::*;
use crate::domains::worker_kernel::artifacts::{
    ArtifactDeliveriesRequest, ArtifactIdentityRequest,
};

impl WorkerRuntime {
    pub(in crate::domains::worker_kernel) fn artifact_deliveries(
        &self,
        request: ArtifactDeliveriesRequest,
    ) -> Result<Value, String> {
        self.store
            .artifact_deliveries(request.limit, request.offset)
    }

    pub(in crate::domains::worker_kernel) fn artifact_content(
        &self,
        request: ArtifactIdentityRequest,
    ) -> Result<Value, String> {
        self.store
            .artifact_content(&request.worker_id, &request.artifact_id)
    }

    pub(in crate::domains::worker_kernel) fn artifact_delete(
        &self,
        request: ArtifactIdentityRequest,
    ) -> Result<Value, String> {
        self.store
            .delete_artifact(&request.worker_id, &request.artifact_id)
    }
}
