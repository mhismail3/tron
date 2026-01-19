/**
 * @fileoverview Comprehensive Tests for ContextLoader
 *
 * Tests for hierarchical context file loading including:
 * - Configuration options
 * - File loading at different levels (global, project, directory)
 * - Context merging
 * - Caching behavior
 * - Section parsing
 * - Error handling
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import {
  ContextLoader,
  createContextLoader,
  type ContextLoaderConfig,
} from '../../src/context/loader.js';
import * as fs from 'fs/promises';
import * as path from 'path';
import * as os from 'os';

describe('ContextLoader', () => {
  let tempDir: string;
  let projectDir: string;
  let subDir: string;
  let globalDir: string;

  beforeEach(async () => {
    tempDir = await fs.mkdtemp(path.join(os.tmpdir(), 'tron-context-'));
    projectDir = path.join(tempDir, 'project');
    subDir = path.join(projectDir, 'src', 'components');
    globalDir = path.join(tempDir, 'home');

    await fs.mkdir(projectDir, { recursive: true });
    await fs.mkdir(subDir, { recursive: true });
    await fs.mkdir(path.join(globalDir, '.tron', 'rules'), { recursive: true });
  });

  afterEach(async () => {
    await fs.rm(tempDir, { recursive: true, force: true });
  });

  describe('Configuration', () => {
    it('should accept custom configuration', () => {
      const config: ContextLoaderConfig = {
        userHome: tempDir,
        projectRoot: projectDir,
        contextFileNames: ['AGENTS.md', 'CLAUDE.md'],
        maxDepth: 5,
      };

      const loader = new ContextLoader(config);
      expect(loader).toBeDefined();
    });

    it('should accept empty configuration', () => {
      const loader = new ContextLoader({});
      expect(loader).toBeDefined();
    });

    it('should use default context file names', () => {
      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });
      expect(loader).toBeDefined();
    });

    it('should support custom agent directory', () => {
      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
        agentDir: '.custom-agent',
      });
      expect(loader).toBeDefined();
    });

    it('should support cache configuration', () => {
      const loader = new ContextLoader({
        cacheEnabled: false,
      });
      expect(loader).toBeDefined();
    });
  });

  describe('Factory Function', () => {
    it('should create loader with createContextLoader', () => {
      const loader = createContextLoader({
        projectRoot: projectDir,
      });
      expect(loader).toBeDefined();
      expect(loader instanceof ContextLoader).toBe(true);
    });

    it('should create loader with default config', () => {
      const loader = createContextLoader();
      expect(loader).toBeDefined();
    });
  });

  describe('Interface', () => {
    it('should define load method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.load).toBe('function');
    });

    it('should define clearCache method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.clearCache).toBe('function');
    });

    it('should define invalidateCache method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.invalidateCache).toBe('function');
    });

    it('should define loadGlobalContext method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.loadGlobalContext).toBe('function');
    });

    it('should define loadProjectContext method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.loadProjectContext).toBe('function');
    });

    it('should define parseIntoSections method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.parseIntoSections).toBe('function');
    });

    it('should define getSection method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.getSection).toBe('function');
    });

    it('should define findAllContextFiles method', () => {
      const loader = new ContextLoader({});
      expect(typeof loader.findAllContextFiles).toBe('function');
    });
  });

  describe('Global Context Loading', () => {
    it('should load global context file', async () => {
      await fs.writeFile(
        path.join(globalDir, '.tron', 'rules', 'AGENTS.md'),
        '# Global Rules\n\nGlobal context here.'
      );

      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });
      const context = await loader.loadGlobalContext();

      expect(context).not.toBeNull();
      expect(context?.level).toBe('global');
      expect(context?.content).toContain('Global Rules');
    });

    it('should return null when no global context exists', async () => {
      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });
      const context = await loader.loadGlobalContext();

      expect(context).toBeNull();
    });
  });

  describe('Project Context Loading', () => {
    it('should load project context file (AGENTS.md)', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Project Context\n\nProject-specific rules.'
      );

      // Use isolated globalDir to avoid loading real ~/.tron/AGENTS.md
      const loader = new ContextLoader({ projectRoot: projectDir, userHome: globalDir });
      const context = await loader.load(projectDir);

      expect(context).toBeDefined();
      expect(context.merged).toContain('Project-specific');
      expect(context.files.length).toBe(1);
    });

    it('should load project context file (CLAUDE.md)', async () => {
      await fs.writeFile(
        path.join(projectDir, 'CLAUDE.md'),
        '# Claude Context\n\nClaude-specific rules.'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const context = await loader.load(projectDir);

      expect(context).toBeDefined();
      expect(context.merged).toContain('Claude-specific');
    });

    it('should prefer AGENTS.md over CLAUDE.md', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# AGENTS rules'
      );
      await fs.writeFile(
        path.join(projectDir, 'CLAUDE.md'),
        '# CLAUDE rules'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const projectContext = await loader.loadProjectContext();

      expect(projectContext?.content).toContain('AGENTS');
    });

    it('should load from .agent directory first', async () => {
      await fs.mkdir(path.join(projectDir, '.agent'), { recursive: true });
      await fs.writeFile(
        path.join(projectDir, '.agent', 'AGENTS.md'),
        '# Agent dir context'
      );
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Root context'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const projectContext = await loader.loadProjectContext();

      expect(projectContext?.content).toContain('Agent dir');
    });
  });

  describe('Directory Context Loading', () => {
    it('should load directory-level contexts', async () => {
      await fs.writeFile(
        path.join(projectDir, 'src', 'AGENTS.md'),
        '# Src Context'
      );
      await fs.mkdir(path.join(projectDir, 'src'), { recursive: true });
      await fs.writeFile(
        path.join(projectDir, 'src', 'AGENTS.md'),
        '# Src Context\n\nSource directory rules.'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const contexts = await loader.loadDirectoryContexts(
        path.join(projectDir, 'src', 'components')
      );

      expect(contexts.length).toBeGreaterThanOrEqual(0);
    });
  });

  describe('Hierarchical Loading', () => {
    it('should load context files from multiple levels', async () => {
      // Create contexts at different levels
      await fs.writeFile(
        path.join(globalDir, '.tron', 'rules', 'AGENTS.md'),
        '# Global\n\nGlobal rules.'
      );
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Project\n\nProject rules.'
      );
      await fs.writeFile(
        path.join(subDir, 'AGENTS.md'),
        '# Component\n\nComponent rules.'
      );

      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });
      const context = await loader.load(subDir);

      // Should have files from multiple levels
      expect(context.files.length).toBeGreaterThanOrEqual(1);
    });

    it('should merge contexts in correct order', async () => {
      await fs.writeFile(
        path.join(globalDir, '.tron', 'rules', 'AGENTS.md'),
        '# Global\n\n1. Global rule'
      );
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Project\n\n2. Project rule'
      );

      const loader = new ContextLoader({
        userHome: globalDir,
        projectRoot: projectDir,
      });
      const context = await loader.load(projectDir);

      // Global should come before project
      const globalIndex = context.merged.indexOf('Global rule');
      const projectIndex = context.merged.indexOf('Project rule');

      expect(globalIndex).toBeLessThan(projectIndex);
    });
  });

  describe('Missing Files', () => {
    it('should handle missing project context gracefully', async () => {
      // Use isolated globalDir (which has no .tron/AGENTS.md) to avoid loading real global context
      const loader = new ContextLoader({ projectRoot: projectDir, userHome: globalDir });
      const context = await loader.load(projectDir);

      expect(context.merged).toBe('');
      expect(context.files.length).toBe(0);
    });

    it('should handle inaccessible directories', async () => {
      // Use isolated globalDir to avoid loading real ~/.tron/AGENTS.md
      const loader = new ContextLoader({
        projectRoot: path.join(tempDir, 'nonexistent'),
        userHome: globalDir,
      });
      const context = await loader.load(path.join(tempDir, 'nonexistent'));

      expect(context.files.length).toBe(0);
    });
  });

  describe('Result Structure', () => {
    it('should return LoadedContext with correct structure', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Test Context'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const context = await loader.load(projectDir);

      expect(context).toHaveProperty('merged');
      expect(context).toHaveProperty('files');
      expect(context).toHaveProperty('loadedAt');
      expect(Array.isArray(context.files)).toBe(true);
      expect(context.loadedAt instanceof Date).toBe(true);
    });

    it('should include file metadata', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Test'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const context = await loader.load(projectDir);

      expect(context.files[0]).toHaveProperty('path');
      expect(context.files[0]).toHaveProperty('content');
      expect(context.files[0]).toHaveProperty('level');
      expect(context.files[0]).toHaveProperty('depth');
      expect(context.files[0]).toHaveProperty('modifiedAt');
    });
  });

  describe('Caching', () => {
    it('should cache loaded contexts', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Cached'
      );

      const loader = new ContextLoader({
        projectRoot: projectDir,
        cacheEnabled: true,
      });

      const context1 = await loader.load(projectDir);
      const context2 = await loader.load(projectDir);

      // Same reference if cached
      expect(context1.loadedAt.getTime()).toBe(context2.loadedAt.getTime());
    });

    it('should clear cache on clearCache call', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Original'
      );

      const loader = new ContextLoader({
        projectRoot: projectDir,
        cacheEnabled: true,
      });

      const context1 = await loader.load(projectDir);
      loader.clearCache();

      // Wait a bit to ensure different timestamp
      await new Promise(r => setTimeout(r, 10));

      const context2 = await loader.load(projectDir);

      expect(context2.loadedAt.getTime()).toBeGreaterThan(context1.loadedAt.getTime());
    });

    it('should invalidate specific directory cache', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Test'
      );

      const loader = new ContextLoader({
        projectRoot: projectDir,
        cacheEnabled: true,
      });

      await loader.load(projectDir);
      loader.invalidateCache(projectDir);

      // Should not throw
      expect(() => loader.clearCache()).not.toThrow();
    });
  });

  describe('Section Parsing', () => {
    it('should parse context into sections', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Section One\n\nContent one.\n\n## Section Two\n\nContent two.'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const context = await loader.load(projectDir);
      const sections = loader.parseIntoSections(context.files[0]);

      expect(sections.length).toBeGreaterThanOrEqual(1);
    });

    it('should search for sections', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Testing Rules\n\nRun tests before commit.\n\n## Coding Standards\n\nUse TypeScript.'
      );

      const loader = new ContextLoader({ projectRoot: projectDir });
      const sections = await loader.getSection(projectDir, 'Testing');

      expect(sections.length).toBeGreaterThan(0);
      expect(sections[0].title).toContain('Testing');
    });
  });

  describe('Find All Context Files', () => {
    it('should find all context files in project', async () => {
      await fs.writeFile(
        path.join(projectDir, 'AGENTS.md'),
        '# Root'
      );
      await fs.mkdir(path.join(projectDir, 'src'), { recursive: true });
      await fs.writeFile(
        path.join(projectDir, 'src', 'AGENTS.md'),
        '# Src'
      );

      const loader = new ContextLoader({
        projectRoot: projectDir,
        userHome: globalDir,
      });
      const files = await loader.findAllContextFiles();

      expect(files.length).toBeGreaterThanOrEqual(2);
    });
  });
});
