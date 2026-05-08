//! Cron operation implementations.
//!
//! The cron worker owns automation reads/writes, explicit runs, scheduled
//! trigger projection, and cron run stream records. Operation modules should
//! treat the scheduler handle and engine trigger runtime as cron-owned deps.
