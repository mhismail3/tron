import { execFile } from "node:child_process";
import { realpath } from "node:fs/promises";
import { join } from "node:path";

export interface IOSBuildRecord {
  id: string; title: string; notes: string; commit: string; branch: string; mode: string;
  time: string; sha256: string; bytes: number; bundle_id: string; manifestURL: string; installURL: string;
}
export interface IOSBuildsFeed {
  status: "ready" | "empty" | "unavailable";
  builds: IOSBuildRecord[];
  message?: string;
}

// The publisher already owns POSIX flock. Use the system Python reader for that
// same lock, rather than an unrelated JS lock or another publication/index service.
// All opens are descriptor-relative, bounded and link-free; no network is used.
const snapshot = String.raw`
import os, sys, stat, json, fcntl, re, plistlib, datetime, urllib.parse

def read(directory, name, limit):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, 'rb') as file:
        info = os.fstat(file.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > limit: raise ValueError('record bounds')
        value = file.read(limit + 1)
        if len(value) > limit: raise ValueError('record bounds')
        return value

def directory(name, parent=None):
    return os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)

def label(record, name, limit, empty=False):
    text = record[name]
    if not isinstance(text, str) or len(text.encode('utf-8')) > limit or (not empty and not text.strip()): raise ValueError('text bounds')
    return text

rootpath = sys.argv[1]
if os.path.realpath(rootpath) != os.path.abspath(rootpath): raise ValueError('linked publisher root')
root = directory(rootpath)
try:
    lock = os.open('.publish.lock', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
    try:
        if not stat.S_ISREG(os.fstat(lock).st_mode): raise ValueError('lock is not a file')
        fcntl.flock(lock, fcntl.LOCK_SH)
        builds = directory('builds', root)
        try:
            names = []
            with os.scandir(builds) as entries:
                for entry in entries:
                    if entry.name.startswith('.'): continue
                    if len(names) == 20: raise ValueError('too many published builds')
                    # Retained timestamp/commit releases coexist with UUID publications.
                    # Neither shape grants access outside the descriptor-relative tree.
                    if not re.fullmatch(r'[0-9]{8}T[0-9]{6}Z-(?:[a-f0-9]{32}-)?[a-f0-9]{7,9}', entry.name): raise ValueError('build identity')
                    names.append(entry.name)
            records = []
            for name in names:
                child = directory(name, builds)
                try:
                    record = json.loads(read(child, 'build.json', 16384))
                    if not isinstance(record, dict) or set(record) != {'id','title','notes','commit','branch','mode','time','sha256','bytes','bundle_id'} or record['id'] != name: raise ValueError('record identity')
                    for field, limit, empty in [('title',256,False),('notes',4096,True),('branch',256,False),('time',64,False),('bundle_id',256,False)]: label(record, field, limit, empty)
                    if not re.fullmatch(r'[a-f0-9]{7,64}', record['commit']) or not re.fullmatch(r'[a-f0-9]{64}', record['sha256']) or record['mode'] not in ['optimized','fast-debug']: raise ValueError('record metadata')
                    timestamp = datetime.datetime.fromisoformat(record['time'])
                    if timestamp.tzinfo is None: raise ValueError('publication timezone')
                    size = os.stat('TronMobile.ipa', dir_fd=child, follow_symlinks=False)
                    if not stat.S_ISREG(size.st_mode) or type(record['bytes']) is not int or not 0 < record['bytes'] <= 10 * 1024**3 or size.st_size != record['bytes']: raise ValueError('IPA bounds')
                    manifest = plistlib.loads(read(child, 'manifest.plist', 65536))
                    items = manifest['items']
                    if len(items) != 1 or items[0]['metadata']['bundle-identifier'] != record['bundle_id']: raise ValueError('manifest identity')
                    assets = [a for a in items[0]['assets'] if a['kind'] == 'software-package']
                    if len(assets) != 1: raise ValueError('manifest assets')
                    url = urllib.parse.urlsplit(assets[0]['url'])
                    if url.scheme != 'https' or not url.hostname or url.username is not None or url.password is not None or url.query or url.fragment or url.path != '/builds/' + name + '/TronMobile.ipa': raise ValueError('manifest authority')
                    if url.port is not None and not 1 <= url.port <= 65535: raise ValueError('manifest port')
                    record['manifestURL'] = urllib.parse.urlunsplit(('https',url.netloc,'/builds/' + name + '/manifest.plist','',''))
                    record['installURL'] = 'itms-services://?action=download-manifest&url=' + urllib.parse.quote(record['manifestURL'], safe='')
                    records.append((timestamp, name, record))
                finally: os.close(child)
            records.sort(key=lambda item: (item[0], item[1]), reverse=True)
            print(json.dumps({'status':'ready' if records else 'empty','builds':[item[2] for item in records]}))
        finally: os.close(builds)
    finally: os.close(lock)
finally: os.close(root)
`;

/** Each open reads a fresh locked cut of the publisher's existing files. Failed,
 * missing or contended input is explicit, never a successful empty feed. */
export async function readIOSBuildsFeed(tronHome: string): Promise<IOSBuildsFeed> {
  let home: string;
  try { home = await realpath(tronHome); }
  catch { return { status: "unavailable", builds: [], message: "The configured Gateway home is unavailable." }; }
  return new Promise(resolve => {
    execFile("/usr/bin/python3", ["-c", snapshot, join(home, "ios-builds")],
      { timeout: 5_000, maxBuffer: 256_000, encoding: "utf8", env: { PATH: "/usr/bin:/bin", PYTHONNOUSERSITE: "1" } }, (error, stdout) => {
        if (error) { resolve({ status: "unavailable", builds: [], message: "Published builds could not be read safely. Refresh after publication finishes." }); return; }
        try { resolve(JSON.parse(stdout) as IOSBuildsFeed); }
        catch { resolve({ status: "unavailable", builds: [], message: "The published builds snapshot was incomplete. Refresh to try again." }); }
      });
  });
}
