export interface AdaptToolConfig {
  /** Path to git repo (from TRON_REPO_ROOT env var) */
  repoRoot: string;
  /** Path to ~/.tron data directory */
  tronHome: string;
  /** Override path to scripts/tron (for testing) */
  tronScript?: string;
}

export interface AdaptParams {
  action: 'deploy' | 'status' | 'rollback';
}

export interface DeploymentRecord {
  status: 'success' | 'failed' | 'rolled_back';
  timestamp: string;
  commit: string;
  previousCommit: string;
  error: string | null;
}
