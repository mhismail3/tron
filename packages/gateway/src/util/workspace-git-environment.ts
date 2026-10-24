/** Explicit workspace operations select Git state through cwd, never through a
 * surrounding hook's repository/index/object paths. Keep ordinary user config
 * and each subprocess owner's separate execution/retirement policy intact. */
export function workspaceGitEnvironment(): NodeJS.ProcessEnv {
  const environment = { ...process.env };
  for (const key of [
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_COMMON_DIR",
    "GIT_INDEX_FILE",
    "GIT_OBJECT_DIRECTORY",
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  ]) delete environment[key];
  return environment;
}
