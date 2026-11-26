import { REPO_URL, REPOSITORY, SOURCE_FOLDER, SOURCE_ZIP_URL } from './config.ts';

// src/release.json is written only by scripts/verify_release.sh --published --write-site-manifest,
// after the public files pass their checksum, provenance and (for the app) Apple checks.
// It holds the facts that script observed; names and URLs are derived and must agree.

export type Sha256 = string & { readonly __brand: 'Sha256' };
export type Architecture = 'arm64' | 'x86_64';

export interface VerifiedDownload {
  readonly file: string;
  readonly url: string;
  readonly sha256: Sha256;
}

export interface VerifiedSource extends VerifiedDownload {
  readonly folder: string;
}

export interface VerifiedApp extends VerifiedDownload {
  readonly architectures: readonly Architecture[];
  readonly minimumSystemVersion: string;
  readonly teamId: string;
}

export interface VerifiedRelease {
  readonly version: string;
  readonly tag: string;
  readonly source: VerifiedSource;
  readonly app: VerifiedApp | null;
}

export type InstallPlan =
  | { readonly kind: 'main'; readonly sourceUrl: string; readonly folder: string }
  | { readonly kind: 'source'; readonly release: VerifiedRelease }
  | { readonly kind: 'app'; readonly release: VerifiedRelease; readonly app: VerifiedApp };

const TAG = /^v(\d+\.\d+\.\d+)$/;
const SHA256 = /^[0-9a-f]{64}$/;
const SYSTEM_VERSION = /^\d+(\.\d+){0,2}$/;
const TEAM_ID = /^[A-Z0-9]{10}$/;
const ARCHITECTURES: readonly Architecture[] = ['arm64', 'x86_64'];

function invalid(path: string, problem: string): Error {
  return new Error(`site/src/release.json: ${path} ${problem}`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isSha256(value: unknown): value is Sha256 {
  return typeof value === 'string' && SHA256.test(value);
}

function isArchitecture(value: unknown): value is Architecture {
  return ARCHITECTURES.some((architecture) => architecture === value);
}

function fields(value: unknown, path: string, keys: readonly string[]): Record<string, unknown> {
  if (!isRecord(value)) throw invalid(path, 'must be an object');
  const actual = Object.keys(value).sort().join(', ');
  const expected = [...keys].sort().join(', ');
  if (actual !== expected) throw invalid(path, `must have exactly these fields: ${expected}`);
  return value;
}

function matching(value: unknown, path: string, pattern: RegExp): string {
  if (typeof value !== 'string' || !pattern.test(value)) throw invalid(path, `must match ${pattern}`);
  return value;
}

function exactly(value: unknown, path: string, expected: string): string {
  if (value !== expected) throw invalid(path, `must be "${expected}"`);
  return expected;
}

function digest(value: unknown, path: string): Sha256 {
  if (!isSha256(value)) throw invalid(path, 'must be 64 lowercase hexadecimal characters');
  return value;
}

function architectures(value: unknown, path: string): readonly Architecture[] {
  if (!Array.isArray(value) || value.length === 0) throw invalid(path, 'must list at least one architecture');
  const found = new Set<Architecture>();
  for (const item of value) {
    if (!isArchitecture(item) || found.has(item)) throw invalid(path, 'must list arm64 and/or x86_64 once each');
    found.add(item);
  }
  return ARCHITECTURES.filter((architecture) => found.has(architecture));
}

export function parseReleaseManifest(raw: unknown): VerifiedRelease | null {
  const root = fields(raw, 'the file', ['release']);
  if (root.release === null) return null;
  const release = fields(root.release, 'release', ['repository', 'tag', 'source', 'app']);
  exactly(release.repository, 'release.repository', REPOSITORY);
  const tag = matching(release.tag, 'release.tag', TAG);
  const version = tag.slice(1);
  const downloads = `${REPO_URL}/releases/download/${tag}`;

  const source = fields(release.source, 'release.source', ['file', 'folder', 'sha256']);
  const sourceFile = exactly(source.file, 'release.source.file', `Second-Wind-${version}-source.zip`);

  let app: VerifiedApp | null = null;
  if (release.app !== null) {
    const fieldsOfApp = fields(release.app, 'release.app', [
      'file', 'sha256', 'architectures', 'minimumSystemVersion', 'teamId',
    ]);
    const appFile = exactly(fieldsOfApp.file, 'release.app.file', `Second-Wind-${version}.dmg`);
    app = {
      file: appFile,
      url: `${downloads}/${appFile}`,
      sha256: digest(fieldsOfApp.sha256, 'release.app.sha256'),
      architectures: architectures(fieldsOfApp.architectures, 'release.app.architectures'),
      minimumSystemVersion: matching(fieldsOfApp.minimumSystemVersion, 'release.app.minimumSystemVersion', SYSTEM_VERSION),
      teamId: matching(fieldsOfApp.teamId, 'release.app.teamId', TEAM_ID),
    };
  }

  return {
    version,
    tag,
    source: {
      file: sourceFile,
      url: `${downloads}/${sourceFile}`,
      folder: exactly(source.folder, 'release.source.folder', `Second-Wind-${version}`),
      sha256: digest(source.sha256, 'release.source.sha256'),
    },
    app,
  };
}

export function planInstall(release: VerifiedRelease | null): InstallPlan {
  if (release === null) return { kind: 'main', sourceUrl: SOURCE_ZIP_URL, folder: SOURCE_FOLDER };
  if (release.app === null) return { kind: 'source', release };
  return { kind: 'app', release, app: release.app };
}


// What a visitor needs, as a phrase: "any Mac with macOS 14 or later".
export function macRequirement(app: VerifiedApp): string {
  const system = `macOS ${app.minimumSystemVersion.replace(/(\.0)+$/, '')} or later`;
  const arm = app.architectures.includes('arm64');
  const intel = app.architectures.includes('x86_64');
  if (arm && intel) return `any Mac with ${system}`;
  return arm ? `a Mac with Apple silicon and ${system}` : `an Intel Mac with ${system}`;
}

export function checkCommands(download: VerifiedDownload): string {
  const path = `~/Downloads/${download.file}`;
  return [`shasum -a 256 ${path}`, `gh attestation verify ${path} --repo ${REPOSITORY}`].join('\n');
}

function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (character) => `&#${character.charCodeAt(0)};`);
}

const SERVICES = 'the official Codex CLI or app, Claude Code, or both';

// The no-JavaScript fallback in index.html, rendered at build time from the same plan.
export function installNoscriptHtml(plan: InstallPlan): string {
  const e = escapeHtml;
  const account = '<li>The app opens as a wind symbol in your menu bar. Pick Codex or Claude and sign in.</li>';
  switch (plan.kind) {
    case 'main':
    case 'source': {
      const url = plan.kind === 'main' ? plan.sourceUrl : plan.release.source.url;
      const folder = plan.kind === 'main' ? plan.folder : plan.release.source.folder;
      const intro = plan.kind === 'main'
        ? 'There is no signed, ready-made download yet.'
        : `There is no ready-made app yet. This is the source for version ${e(plan.release.version)}.`;
      const checksum = plan.kind === 'main'
        ? ''
        : `<p>SHA-256 of the download: <code>${e(plan.release.source.sha256)}</code></p>`;
      return [
        '<h2>Install from source</h2>',
        `<p>${intro} You need macOS 14 or later, Swift 6 or later (from Xcode or Apple's Command Line Tools), and ${SERVICES}.</p>`,
        '<ol>',
        `<li><a href="${e(url)}">Download the source (.zip)</a> and open it. You get a folder named <code>${e(folder)}</code>.</li>`,
        `<li>Open Terminal and run:<pre><code>cd ~/Downloads/${e(folder)}\n./scripts/install_app.sh --launch</code></pre></li>`,
        account,
        '</ol>',
        checksum,
      ].join('\n');
    }
    case 'app':
      return [
        '<h2>Install</h2>',
        `<p>Version ${e(plan.release.version)}. Apple has checked it for malware. You need ${e(macRequirement(plan.app))} and ${SERVICES}.</p>`,
        '<ol>',
        `<li><a href="${e(plan.app.url)}">Download Second Wind (.dmg)</a>.</li>`,
        '<li>Open it and drag Second Wind into Applications, then open Second Wind from Applications.</li>',
        account,
        '</ol>',
        `<p>SHA-256 of the download: <code>${e(plan.app.sha256)}</code></p>`,
        `<p>Prefer to build it yourself? <a href="${e(plan.release.source.url)}">Download the source (.zip)</a>.</p>`,
      ].join('\n');
    default: {
      const exhaustive: never = plan;
      return exhaustive;
    }
  }
}
