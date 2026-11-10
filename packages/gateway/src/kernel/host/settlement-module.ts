import type { ModuleDescriptor } from "./module-host.js";

export const settlementModule: ModuleDescriptor = {
  name: "tron-invocation-settlement",
  purpose: "Keeps each chat's completion receipts in order before the next message",
  tools: [],
  commands: [],
  start: () => ({
    extension: (session) => (pi) => {
      pi.on("turn_start", async () => {
        await session.joinTerminalReceiptWrites();
      });
      pi.on("message_end", async (event) => {
        if (event.message.role === "user") await session.joinTerminalReceiptWrites();
      });
    },
  }),
};
