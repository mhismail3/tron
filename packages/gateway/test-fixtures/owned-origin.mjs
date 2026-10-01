// Isolated process graph only. Invoked by native owner tests, never production.
import { spawn, spawnSync } from 'node:child_process';
import { writeFileSync, existsSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const root = process.argv[2];
const executable = process.argv[3];
const mode = process.argv[4];
const moduleRoot = pathToFileURL(resolve('dist') + '/');
const { createProcessLeaseHost } = await import(new URL('lifecycle/process-lease-host.js', moduleRoot));
const { spawnOwnedProcess } = await import(new URL('lifecycle/owned-process.js', moduleRoot));
const { startRestartWatchdog } = await import(new URL('lifecycle/restart-watchdog.js', moduleRoot));
const { GatewayWorkRegistry } = await import(new URL('sessions/gateway-work-registry.js', moduleRoot));
const watchdog = await startRestartWatchdog(executable);
const registry = new GatewayWorkRegistry();
const host = await createProcessLeaseHost(registry, watchdog.leaseCapability, executable);
Object.assign(process.env, host.environment);
const heartbeat = `const fs=require('fs');process.on('SIGTERM',()=>{});fs.writeFileSync(process.argv[1]+'.pid',String(process.pid));setInterval(()=>fs.appendFileSync(process.argv[1],'x'),20);setTimeout(()=>process.exit(),20000);`;
// Independent updater-like helper is deliberately NOT registered as owned work.
const updater = spawn(process.execPath, ['-e', heartbeat, join(root, 'updater')], { detached: true, stdio: 'ignore', env: {} });
writeFileSync(join(root, 'updater-owner.pid'), String(updater.pid));
// A TERM-responsive leader with a TERM-resistant same-session writer.
const leader = `const{spawn}=require('child_process');const child=spawn(process.execPath,['-e',${JSON.stringify(heartbeat)},${JSON.stringify(join(root, 'writer'))}],{stdio:'ignore'});while(true){}`;
const controller = spawnOwnedProcess(process.execPath, ['-e', leader], { cwd: root, env: process.env, stdio: ['ignore', 'ignore', 'ignore'] });
await controller.ready;
// Distinct supported SDK bash session through the production override entrypoint.
const { default: extension } = await import(new URL('lifecycle/owned-bash-extension.js', moduleRoot));
let bash;
extension({ registerTool(tool) { bash = tool; }, on() {} });
void bash.execute('fixture', { command: `${JSON.stringify(process.execPath)} -e ${JSON.stringify(heartbeat)} ${JSON.stringify(join(root, 'bash'))}` }, undefined, undefined, undefined).catch(() => {});
while (!existsSync(join(root, 'writer.pid')) || !existsSync(join(root, 'bash.pid'))) await new Promise(r => setTimeout(r, 20));
writeFileSync(join(root, 'capability.json'), JSON.stringify({ ...watchdog.environment, ...host.environment }));
writeFileSync(join(root, 'ready'), 'ready');
if (mode === 'sync') {
  const cap = watchdog.leaseCapability;
  spawnSync(executable, ['--guardian', cap.guardianSocket, cap.guardianNonce, String(cap.guardianPid), '--sync', process.execPath, '-e', heartbeat, join(root, 'hook')], { detached: true, stdio: 'ignore' });
  while (true) {}
} else if (mode === 'blocked') {
  // Block JS, not OS scheduling. Native leases and guardian remain runnable.
  process.on('SIGTERM', () => {});
  while (true) {}
} else {
  process.on('message', async (message) => {
    if (message === 'freeze') { registry.beginDrain(); host.terminate(); }
    if (message === 'restart') {
      const deadline = await watchdog.arm(Date.now() + 7000);
      writeFileSync(join(root, 'accepted'), String(deadline));
      registry.beginDrain();
      // Stand in for a receipt/cancellation callback that blocks synchronously.
      while (true) {}
    }
  });
  setInterval(() => {}, 1000);
}
