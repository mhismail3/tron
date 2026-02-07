/**
 * @fileoverview Persistent container registry
 *
 * Tracks all containers created by the agent in a JSON file at
 * ~/.tron/artifacts/containers.json. Ensures containers are never
 * orphaned across sessions.
 *
 * Writes are atomic (write to tmp file, then rename) to prevent
 * corruption from crashes.
 */

import * as fs from 'fs';
import * as path from 'path';
import { randomUUID } from 'crypto';
import type { ContainerRecord, ContainerRegistryFile } from './types.js';

export class ContainerRegistry {
  private filePath: string;
  private data: ContainerRegistryFile;

  constructor(filePath: string) {
    this.filePath = filePath;
    this.data = this.load();
  }

  getAll(): ContainerRecord[] {
    return this.data.containers;
  }

  add(record: ContainerRecord): void {
    this.data.containers.push(record);
    this.save();
  }

  remove(name: string): void {
    const before = this.data.containers.length;
    this.data.containers = this.data.containers.filter(c => c.name !== name);
    if (this.data.containers.length !== before) {
      this.save();
    }
  }

  reconcile(liveNames: string[]): void {
    const liveSet = new Set(liveNames);
    const before = this.data.containers.length;
    this.data.containers = this.data.containers.filter(c => liveSet.has(c.name));
    if (this.data.containers.length !== before) {
      this.save();
    }
  }

  private load(): ContainerRegistryFile {
    try {
      const content = fs.readFileSync(this.filePath, 'utf-8');
      const parsed = JSON.parse(content);
      if (Array.isArray(parsed.containers)) {
        return parsed as ContainerRegistryFile;
      }
      // Missing or invalid containers field
      const empty: ContainerRegistryFile = { containers: [] };
      this.data = empty;
      this.save();
      return empty;
    } catch {
      // File missing or corrupt JSON — initialize empty
      const empty: ContainerRegistryFile = { containers: [] };
      this.data = empty;
      this.save();
      return empty;
    }
  }

  private save(): void {
    const dir = path.dirname(this.filePath);
    fs.mkdirSync(dir, { recursive: true });

    const tmpPath = `${this.filePath}.${randomUUID()}.tmp`;
    fs.writeFileSync(tmpPath, JSON.stringify(this.data, null, 2));
    fs.renameSync(tmpPath, this.filePath);
  }
}
