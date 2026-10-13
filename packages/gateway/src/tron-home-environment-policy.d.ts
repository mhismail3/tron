export function resolveTronHomePath(environment?: NodeJS.ProcessEnv): string;
export function removableTronHomeVariables(environment: NodeJS.ProcessEnv, homes: readonly string[]): string[];
export function refusedTronHomeEnvironmentLeaks(environment: NodeJS.ProcessEnv, homes: readonly string[]): string[];
export function environmentTronHomes(environment?: NodeJS.ProcessEnv): string[];
