import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdir, mkdtemp, readFile, readdir, realpath, rm, stat, writeFile, copyFile, open } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const repo = fileURLToPath(new URL('../../../', import.meta.url));
const helper = join(repo, 'packages/gateway/test-support/native-publication-fixture.py');
const headers = resolve(dirname(process.execPath), '../include/node');
function owner(source, cache, compilerHeaders = headers, environment = {}) {
  const child = spawn('python3', [helper, source, cache, compilerHeaders], { stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, ...environment } });
  const exited = new Promise((resolve, reject) => { child.once('exit', resolve); child.once('error', reject); });
  const lines = createInterface({ input: child.stdout });
  const ready = Promise.race([
    new Promise((resolve, reject) => lines.once('line', value => { try { resolve(JSON.parse(value)); } catch (error) { reject(error); } })),
    exited.then(code => { throw new Error(`Fixture owner exited before readiness (${code})`); }),
  ]);
  return { ready, close: async () => { child.stdin.end(); assert.equal(await exited, 0); lines.close(); },
    stop: async () => { child.stdin.end(); child.kill('SIGTERM'); await exited; lines.close(); } };
}
function execute(binary, destination, refuses = false) {
  execFileSync(process.execPath, ['-e', `const fs=require('node:fs'),addon=require(process.argv[1]),root=process.argv[2];
fs.mkdirSync(root);fs.mkdirSync(root+'/stage',{mode:0o700});fs.writeFileSync(root+'/stage/bytes','retained');const parent=fs.openSync(root,'r');addon.publishDirectoryExclusive(parent,'stage',parent,'entry',(error,published)=>{if(process.argv[3]==='refuse'){if(!error||fs.readFileSync(root+'/stage/bytes','utf8')!=='retained')throw Error('source mutation not executed');}else{if(error)throw error;if(!published||fs.readFileSync(root+'/entry/bytes','utf8')!=='retained')throw Error('invalid publication');}fs.closeSync(parent);});`, binary, destination, refuses ? 'refuse' : 'publish'], { stdio: 'inherit' });
}

test('native fixture owner reuses exact source, invalidates source edits, and rebuilds corrupt artifacts at a real compiler/binary boundary', { skip: process.platform !== 'darwin' }, async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'tron-native-cache-contract-'))), source = join(root, 'source'), cache = join(root, 'cache');
  let active, blocked;
  try {
    const build = join(repo, 'packages/mac-app/native-gateway-client/build.py');
    const inputs = JSON.parse(execFileSync('python3', ['-c', "import importlib.util,json,sys;s=importlib.util.spec_from_file_location('builder',sys.argv[1]);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(json.dumps(m.INPUTS))", build], { encoding: 'utf8' }));
    for (const file of inputs) { await mkdir(dirname(join(source, file)), { recursive: true }); await copyFile(join(repo, file), join(source, file)); }
    active = owner(source, cache); const cold = await active.ready;
    assert.equal(cold.cacheHit, false); execute(cold.artifact, join(root, 'cold-publication'));
    const before = await stat(cold.artifact); await active.close(); active = undefined;
    active = owner(source, cache); const warm = await active.ready;
    assert.equal(warm.cacheHit, true); assert.equal(warm.artifact, cold.artifact);
    const after = await stat(warm.artifact); assert.equal(after.ino, before.ino); assert.equal(after.mtimeMs, before.mtimeMs);
    await active.close(); active = undefined;
    const implementation = join(source, 'packages/mac-app/native-gateway-client/directory-publish.mm');
    await writeFile(implementation, (await readFile(implementation, 'utf8')).replace('(info.st_mode & 0777) != 0700', '(info.st_mode & 0777) != 0750'));
    active = owner(source, cache); const changed = await active.ready;
    assert.equal(changed.cacheHit, false); assert.notEqual(changed.sourceHash, cold.sourceHash);
    execute(changed.artifact, join(root, 'changed-publication'), true);
    assert.deepEqual((await readdir(cache)).filter(name => name !== '.lock'), [changed.sourceHash]);
    await active.close(); active = undefined;
    await writeFile(changed.artifact, 'corrupt fixture');
    active = owner(source, cache); const repaired = await active.ready;
    assert.equal(repaired.cacheHit, false); assert.equal(repaired.sourceHash, changed.sourceHash);
    execute(repaired.artifact, join(root, 'repaired-publication'), true);
    blocked = owner(source, cache); void blocked.ready.catch(() => {});
    let deadline;
    try { await Promise.race([blocked.close(), new Promise((_, reject) => { deadline = setTimeout(() => reject(Error('waiting fixture caller did not cancel while another reader retained the lock')), 5000); })]); }
    finally { clearTimeout(deadline); }
    await active.close(); active = undefined;
    await blocked.close(); blocked = undefined;
    await rm(repaired.artifact); execFileSync('/usr/bin/mkfifo', [repaired.artifact]);
    active = owner(source, cache); const nonregular = await active.ready;
    assert.equal(nonregular.cacheHit, false); assert.equal((await stat(nonregular.artifact)).isFile(), true);
    execute(nonregular.artifact, join(root, 'fifo-repaired-publication'), true);
    await active.close(); active = undefined;
    const gatedHeaders = join(root, 'gated-headers'); await mkdir(gatedHeaders);
    const pin = JSON.parse(await readFile(join(source, 'packages/mac-app/native-gateway-client/node-headers.json'), 'utf8'));
    for (const name of Object.keys(pin.sha256)) if (name !== 'node_api.h') await copyFile(join(headers, name), join(gatedHeaders, name));
    const gate = join(gatedHeaders, 'node_api.h'); execFileSync('/usr/bin/mkfifo', [gate]);
    active = owner(source, join(root, 'cancel-cache'), gatedHeaders); void active.ready.catch(() => {});
    const writer = await open(gate, 'w'); // Resolves only after the real builder opens its header reader.
    try {
      await active.close(); active = undefined;
      // The named pipe had a real builder reader when open('w') resolved.
      // EPIPE now proves that reader retired before its owner joined.
      await assert.rejects(writer.write('x'), { code: 'EPIPE' });
      assert.deepEqual((await readdir(join(root, 'cancel-cache'))).filter(name => name !== '.lock'), []);
    } finally { await writer.close(); }
    const admission = join(root, 'admission'); await mkdir(admission);
    for (const name of ['ready', 'sent', 'release']) execFileSync('/usr/bin/mkfifo', [join(admission, name)]);
    await writeFile(join(admission, 'sitecustomize.py'), `import os,signal,subprocess
_original_init=subprocess.Popen.__init__
_original_kill=os.kill
def gated_init(self,*args,**kwargs):
    _original_init(self,*args,**kwargs)
    if kwargs.get('start_new_session'):
        root=os.environ['NATIVE_ADMISSION_GATE']
        with open(root+'/ready','w') as ready: ready.write(str(self.pid))
        with open(root+'/release','rb') as release: release.read(1)
def acknowledged_kill(pid,kind):
    _original_kill(pid,kind)
    if pid==os.getpid() and kind==signal.SIGUSR1:
        with open(os.environ['NATIVE_ADMISSION_GATE']+'/sent','w') as sent: sent.write('sent')
subprocess.Popen.__init__=gated_init
os.kill=acknowledged_kill
`);
    const admitted = readFile(join(admission, 'ready'), 'utf8'), sent = readFile(join(admission, 'sent'), 'utf8');
    const release = open(join(admission, 'release'), 'w'), header = open(gate, 'w');
    active = owner(source, join(root, 'admission-cache'), gatedHeaders, { PYTHONPATH: admission, NATIVE_ADMISSION_GATE: admission }); void active.ready.catch(() => {});
    const compiler = Number(await admitted), headerWriter = await header, releaseWriter = await release;
    let retired = false;
    try {
      const ended = active.close(); await sent;
      await releaseWriter.write('x'); await releaseWriter.close();
      await ended; active = undefined;
      try { await headerWriter.write('x'); } catch (error) { if (error.code !== 'EPIPE') throw error; retired = true; }
      assert.equal(retired, true, 'compiler admitted before job assignment escaped cancellation');
    } finally {
      // Only the group whose PID came from this owned real Popen and whose
      // header reader is still held here. Never target unrelated host work.
      if (!retired) {
        try { process.kill(-compiler, 'SIGKILL'); } catch (error) { if (error.code !== 'ESRCH') throw error; }
        await assert.rejects(headerWriter.writeFile(Buffer.alloc(65536)), { code: 'EPIPE' });
      }
      await headerWriter.close();
    }
  } finally { try { if (active) await active.stop(); if (blocked) await blocked.stop(); } finally { await rm(root, { recursive: true, force: true }); } }
});
