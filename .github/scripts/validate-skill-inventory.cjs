#!/usr/bin/env node

const { createHash } = require('node:crypto');
const { readFileSync, readdirSync } = require('node:fs');
const { join, relative, resolve } = require('node:path');

const SHA256_RE = /^[0-9a-f]{64}$/;

function readJson(filePath, label) {
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    throw new Error(`${label} ${filePath} is not valid JSON: ${error.message}`);
  }
}

function collectSkillFiles(baseDir, currentDir, files) {
  const entries = readdirSync(currentDir, { withFileTypes: true });
  for (const entry of entries) collectSkillEntry(baseDir, currentDir, entry, files);
}

function collectSkillEntry(baseDir, currentDir, entry, files) {
  const fullPath = join(currentDir, entry.name);
  if (entry.isDirectory()) return collectSkillDirectory(baseDir, fullPath, entry.name, files);
  if (entry.isFile()) files.push(readSkillFile(baseDir, fullPath));
}

function collectSkillDirectory(baseDir, fullPath, name, files) {
  if (isIgnoredDirectory(name)) return;
  collectSkillFiles(baseDir, fullPath, files);
}

function isIgnoredDirectory(name) {
  return name === '.git' || name === 'node_modules';
}

function readSkillFile(baseDir, filePath) {
  return {
    relativePath: relative(baseDir, filePath).split('\\').join('/'),
    content: readFileSync(filePath),
  };
}

function computeSkillFolderHash(skillDir) {
  const files = [];
  collectSkillFiles(skillDir, skillDir, files);
  files.sort((left, right) => left.relativePath.localeCompare(right.relativePath));

  const hash = createHash('sha256');
  for (const file of files) {
    hash.update(file.relativePath);
    hash.update(file.content);
  }
  return hash.digest('hex');
}

function validateInventoryShape(inventory, inventoryPath) {
  if (!Array.isArray(inventory)) {
    throw new Error(`${inventoryPath}: expected a JSON array`);
  }
}

function validateLockShape(lock, lockPath) {
  if (lock.version !== 1 || !lock.skills || Array.isArray(lock.skills)) {
    throw new Error(`${lockPath}: expected version 1 with a skills object`);
  }
}

function indexInventory(inventory, inventoryPath) {
  const inventoryByName = new Map();
  for (const item of inventory) addInventoryItem(inventoryByName, item, inventoryPath);
  return inventoryByName;
}

function addInventoryItem(inventoryByName, item, inventoryPath) {
  requireInventoryName(item, inventoryPath);
  requireProjectScope(item, inventoryPath);
  requireUniqueInventoryName(inventoryByName, item, inventoryPath);
  inventoryByName.set(item.name, item);
}

function requireInventoryName(item, inventoryPath) {
  if (!item || typeof item.name !== 'string') {
    throw new Error(`${inventoryPath}: every entry must name a project skill`);
  }
}

function requireProjectScope(item, inventoryPath) {
  if (item.scope !== 'project') {
    throw new Error(`${inventoryPath}: every entry must name a project skill`);
  }
}

function requireUniqueInventoryName(inventoryByName, item, inventoryPath) {
  if (inventoryByName.has(item.name)) {
    throw new Error(`${inventoryPath}: duplicate skill ${item.name}`);
  }
}

function validateLockEntry(name, entry, context) {
  const { inventoryByName, inventoryPath, lockPath, skillsRoot } = context;
  validateComputedHash(name, entry, lockPath);
  validateSkillName(name, lockPath);

  const expectedDir = resolve(skillsRoot, '.agents', 'skills', name);
  const item = requireInventoryItem(inventoryByName, name, inventoryPath);
  validateCanonicalPath(item, expectedDir, name, inventoryPath);
  validateContentHash(entry, expectedDir, name);
}

function validateComputedHash(name, entry, lockPath) {
  if (!entry || typeof entry.computedHash !== 'string') {
    throw new Error(`${lockPath}: ${name} has an invalid computedHash`);
  }
  if (!SHA256_RE.test(entry.computedHash)) {
    throw new Error(`${lockPath}: ${name} has an invalid computedHash`);
  }
}

function validateSkillName(name, lockPath) {
  if (!/^[a-z0-9][a-z0-9._-]*$/i.test(name)) {
    throw new Error(`${lockPath}: unsafe skill name ${name}`);
  }
}

function requireInventoryItem(inventoryByName, name, inventoryPath) {
  const item = inventoryByName.get(name);
  if (!item) {
    throw new Error(`${inventoryPath}: lock-managed skill ${name} is missing`);
  }
  return item;
}

function validateCanonicalPath(item, expectedDir, name, inventoryPath) {
  if (typeof item.path !== 'string') {
    throw new Error(`${inventoryPath}: ${name} has an unexpected canonical path`);
  }
  if (resolve(item.path) !== expectedDir) {
    throw new Error(`${inventoryPath}: ${name} has an unexpected canonical path`);
  }
}

function validateContentHash(entry, expectedDir, name) {
  const actualHash = computeSkillFolderHash(expectedDir);
  if (actualHash !== entry.computedHash) {
    throw new Error(
      `${name}: content hash ${actualHash} does not match lock ${entry.computedHash}`,
    );
  }
}

function validateSkillInventory(inventoryPath, options = {}) {
  const repositoryRoot = resolve(options.root || process.cwd());
  const skillsRoot = resolve(repositoryRoot, options.skillsRoot || '.');
  const lockPath = resolve(skillsRoot, 'skills-lock.json');
  const inventory = readJson(inventoryPath, 'Inventory');
  const lock = readJson(lockPath, 'Lock file');

  validateInventoryShape(inventory, inventoryPath);
  validateLockShape(lock, lockPath);
  const inventoryByName = indexInventory(inventory, inventoryPath);
  const context = { inventoryByName, inventoryPath, lockPath, skillsRoot };
  const lockEntries = Object.entries(lock.skills);
  for (const [name, entry] of lockEntries) validateLockEntry(name, entry, context);

  console.log(
    `Validated ${lockEntries.length} lock-managed skills against inventory and content hashes.`,
  );
  return lockEntries.length;
}

if (require.main === module) {
  const [inventoryPath] = process.argv.slice(2);
  if (!inventoryPath) {
    console.error(
      'Usage: node .github/scripts/validate-skill-inventory.cjs <inventory-json>',
    );
    process.exit(2);
  }

  try {
    validateSkillInventory(inventoryPath, {
      skillsRoot: process.env.SKILLS_ROOT || '.',
    });
  } catch (error) {
    console.error(error.message);
    process.exit(1);
  }
}

module.exports = { computeSkillFolderHash, validateSkillInventory };
