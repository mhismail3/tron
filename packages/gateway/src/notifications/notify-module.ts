import type { ModuleDescriptor } from "../kernel/host/module-host.js";
import type { NotificationService } from "./notification-service.js";
import { createTronNotifyExtension } from "./tron-notify-extension.js";

export interface NotifyModuleServices { notifications: NotificationService | undefined; machineId: string | undefined }

export function createNotifyModule(services: () => NotifyModuleServices): ModuleDescriptor {
  return {
    name: "tron-notify", purpose: "Sends notifications to your Tron iPhones.",
    tools: ["notify"], commands: [],
    start: () => ({ extension: session => {
      const { notifications, machineId } = services();
      if (!notifications) return undefined;
      return createTronNotifyExtension({
        sessionId: session.sessionId, sessionTitle: session.title, observed: session.presented,
        ...(machineId ? { machineId } : {}), enqueue: input => notifications.enqueue(input),
      });
    } }),
  };
}
