import { createRequire } from "node:module";

export type DirectoryPublisher = (source: number, sourceLeaf: string, destination: number, destinationLeaf: string) => Promise<boolean>;
export type ManifestReplacer = (source: number, destination: number) => Promise<void>;
/** Moves only staged app.json into a pinned entry directory; never replaces a
 * directory or follows the destination manifest's symlink. */
export function manifestReplacer(binary = "/Applications/Tron.app/Contents/Library/Native/tron-native-capture.node"): ManifestReplacer {
  return (source, destination) => new Promise((resolve, reject) => {
    try {
      const binding = createRequire(import.meta.url)(binary) as { replaceAppManifest?: (source: number, destination: number, done: (error: Error | null) => void) => void };
      if (typeof binding.replaceAppManifest !== "function") throw new Error("Metadata editing requires a manual Mac build with the native manifest export");
      binding.replaceAppManifest(source, destination, error => error ? reject(error) : resolve());
    } catch (error) { reject(error); }
  });
}
type Binding = { publishDirectoryExclusive(source: number, leaf: string, destination: number, name: string, done: (error: Error | null, published: boolean) => void): void };
/** Import/construction is inert. Composition chooses the binary; production uses
 * only the installed Mac resource, never an environment-based fallback. */
export function directoryPublisher(binary = "/Applications/Tron.app/Contents/Library/Native/tron-native-capture.node"): DirectoryPublisher {
  return (source, leaf, destination, name) => new Promise((resolve, reject) => {
    let binding: Binding;
    try {
      const loaded = createRequire(import.meta.url)(binary) as Partial<Binding>;
      if (typeof loaded.publishDirectoryExclusive !== "function") throw new Error("Missing directory publication export");
      binding = loaded as Binding;
    } catch (cause) {
      reject(new Error("Directory publication requires a manual Mac build with the native publication export; source-only Gateway updates cannot install it", { cause })); return;
    }
    // No timeout may release staging/descriptors while a native rename is still
    // accepted. The index joins the actual callback before retiring its scope.
    binding.publishDirectoryExclusive(source, leaf, destination, name, (error, published) => error ? reject(error) : resolve(published));
  });
}
