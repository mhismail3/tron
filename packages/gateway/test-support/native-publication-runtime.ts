import { inject } from "vitest";

// Only the selected native project prepares this resource. Child fixtures
// inherit its explicit candidate binary; no installed Mac binary is replaced.
process.env.TRON_TEST_DIRECTORY_PUBLICATION_BINARY = inject("nativePublicationBinary");
