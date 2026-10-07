export function resolveTronHomePath(environment?: NodeJS.ProcessEnv): string;
export function isTronHomePath(value: string, homes: readonly string[]): boolean;
export function tronHomeEnvironmentLeaks(environment: NodeJS.ProcessEnv, homes: readonly string[]): string[];
export function environmentTronHomes(environment?: NodeJS.ProcessEnv): string[];
