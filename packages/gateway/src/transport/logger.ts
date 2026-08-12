export interface LogRecord {
  timestamp: string;
  level: "info" | "warning" | "error";
  message: string;
}

export class GatewayLogger {
  private readonly records: LogRecord[] = [];

  log(level: LogRecord["level"], message: string): void {
    const record = { timestamp: new Date().toISOString(), level, message: message.slice(0, 2_000) };
    this.records.push(record);
    if (this.records.length > 1_000) this.records.splice(0, this.records.length - 1_000);
    const output = `[${record.timestamp}] ${level.toUpperCase()} ${record.message}\n`;
    if (level === "error") process.stderr.write(output);
    else process.stdout.write(output);
  }

  recent(limit = 200): LogRecord[] {
    return this.records.slice(-Math.max(1, Math.min(limit, 1_000)));
  }
}
