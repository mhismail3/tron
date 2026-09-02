import { describe, expect, it, vi } from "vitest";
import { durableAtomicWriteJson, durableRemove, type DurableJsonFileSystem } from "./durable-json.js";

function fileSystem(overrides: Partial<DurableJsonFileSystem> = {}): DurableJsonFileSystem {
  const fileHandle = {
    writeFile: vi.fn(async () => {}),
    sync: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
  };
  const directoryHandle = {
    sync: vi.fn(async () => {}),
    close: vi.fn(async () => {}),
  };
  let opens = 0;
  return {
    mkdir: vi.fn(async () => undefined) as unknown as DurableJsonFileSystem["mkdir"],
    open: vi.fn(async () => opens++ === 0 ? fileHandle : directoryHandle) as unknown as DurableJsonFileSystem["open"],
    rename: vi.fn(async () => undefined) as unknown as DurableJsonFileSystem["rename"],
    rm: vi.fn(async () => undefined) as unknown as DurableJsonFileSystem["rm"],
    ...overrides,
  };
}

describe("durable JSON publication", () => {
  it("syncs the file before rename and the directory before acknowledgement", async () => {
    const order: string[] = [];
    const temporaryHandle = {
      writeFile: vi.fn(async () => { order.push("write"); }),
      sync: vi.fn(async () => { order.push("file-sync"); }),
      close: vi.fn(async () => { order.push("file-close"); }),
    };
    const directoryHandle = {
      sync: vi.fn(async () => { order.push("directory-sync"); }),
      close: vi.fn(async () => { order.push("directory-close"); }),
    };
    let opens = 0;
    const fs = fileSystem({
      open: vi.fn(async () => opens++ === 0 ? temporaryHandle : directoryHandle) as unknown as DurableJsonFileSystem["open"],
      rename: vi.fn(async () => { order.push("rename"); }) as unknown as DurableJsonFileSystem["rename"],
    });

    await durableAtomicWriteJson("/state/record.json", { value: 1 }, 0o600, fs);

    expect(order).toEqual(["write", "file-sync", "file-close", "rename", "directory-sync", "directory-close"]);
    expect(fs.open).toHaveBeenNthCalledWith(1, expect.stringMatching(/record\.json\.\d+\.[0-9a-f]{12}\.tmp$/), "wx", 0o600);
    expect(fs.open).toHaveBeenNthCalledWith(2, "/state", "r");
  });

  it("removes only its owned temporary after a failed publication", async () => {
    const fs = fileSystem({
      rename: vi.fn(async () => { throw new Error("rename failed"); }) as unknown as DurableJsonFileSystem["rename"],
    });

    await expect(durableAtomicWriteJson("/state/record.json", {}, 0o600, fs)).rejects.toThrow("rename failed");
    expect(fs.rm).toHaveBeenCalledWith(expect.stringMatching(/record\.json\.\d+\.[0-9a-f]{12}\.tmp$/), { force: true });
    expect(fs.rm).not.toHaveBeenCalledWith("/state/record.json", expect.anything());
  });

  it("syncs the parent directory after removal", async () => {
    const directoryHandle = { sync: vi.fn(async () => {}), close: vi.fn(async () => {}) };
    const fs = {
      rm: vi.fn(async () => undefined),
      open: vi.fn(async () => directoryHandle),
    };

    await durableRemove("/state/record.json", fs as never);

    expect(fs.rm).toHaveBeenCalledWith("/state/record.json");
    expect(directoryHandle.sync).toHaveBeenCalledOnce();
  });
});
