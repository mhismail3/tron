import type { ModuleDescriptor } from "./module-host.js";

/** Keeps the first ordinary extension position; Home does not register it. */
export const settlementModule: ModuleDescriptor = {
  name: "tron-invocation-settlement",
  purpose: "Keeps each chat's completion receipts in order before the next message",
  tools: [],
  commands: [],
  start: () => ({
    extension: (session) => (pi) => {
      // Pi awaits these public hooks before the next run/input can append.
      // Join receipt I/O only: attention must not hold up accepted continuations.
      pi.on("turn_start", async () => {
        await session.joinTerminalReceiptWrites();
      });
      pi.on("message_end", async (event) => {
        if (event.message.role === "user") await session.joinTerminalReceiptWrites();
      });
    },
  }),
};
