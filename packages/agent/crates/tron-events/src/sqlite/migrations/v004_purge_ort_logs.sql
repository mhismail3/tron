-- One-time cleanup: remove ONNX Runtime log spam from the logs table.
-- The ort crate's tracing events are now filtered at the subscriber level
-- via module_overrides in LoggingSettings (default: ort=warn).
DELETE FROM logs WHERE component = 'ort::logging';
