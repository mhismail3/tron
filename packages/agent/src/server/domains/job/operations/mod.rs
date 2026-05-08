//! Job operation implementations.
//!
//! The job worker owns queue-backed background job start/cancel commands plus
//! hidden apply functions. Operation modules keep process/job-manager calls
//! behind engine idempotency, queue, stream, and ledger boundaries.
