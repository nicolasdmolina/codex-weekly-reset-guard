// Checks the website's release-manifest parser against the QA fixtures and against
// malformed manifests. Usage: node scripts/test-release-manifest.mjs
import { readFile } from 'node:fs/promises';
import { strict as assert } from 'node:assert';
import { fileURLToPath } from 'node:url';
import { runnerImport } from 'vite';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));
const { module: release } = await runnerImport(here('../src/release.ts'));
const fixture = async (name) => JSON.parse(await readFile(here(`./${name}`), 'utf8'));
const appFixture = await fixture('qa-release-app.json');
const sourceFixture = await fixture('qa-release-source.json');
const shipped = JSON.parse(await readFile(here('../src/release.json'), 'utf8'));

const plan = (manifest) => release.planInstall(release.parseReleaseManifest(manifest));
const downloads = (manifest) =>
  `https://github.com/nicolasdmolina/second-wind/releases/download/${manifest.release.tag}`;
let count = 0;
const check = (label, run) => {
  run();
  count += 1;
  console.log(`PASS ${label}`);
};

check('the shipped manifest parses', () => assert.ok(['main', 'source', 'app'].includes(plan(shipped).kind)));
check('no release keeps the main source flow', () => {
  const main = plan({ release: null });
  assert.equal(main.kind, 'main');
  assert.match(main.sourceUrl, /\/archive\/refs\/heads\/main\.zip$/);
});
check('a source-only release offers the verified archive', () => {
  const source = plan(sourceFixture);
  assert.equal(source.kind, 'source');
  assert.equal(source.release.source.url, `${downloads(sourceFixture)}/Second-Wind-0.3.0-source.zip`);
  assert.equal(source.release.source.folder, 'Second-Wind-0.3.0');
});
check('an app release offers the universal ZIP', () => {
  const app = plan(appFixture);
  assert.equal(app.kind, 'app');
  assert.equal(app.app.url, `${downloads(appFixture)}/Second-Wind-0.3.1-mac.zip`);
  assert.equal(app.app.signing, 'ad-hoc');
  assert.deepEqual(app.app.architectures, ['arm64', 'x86_64']);
  assert.equal(release.macRequirement(app.app), 'any Mac with macOS 14 or later');
  assert.equal(
    release.checkCommands(app.app),
    'shasum -a 256 ~/Downloads/Second-Wind-0.3.1-mac.zip\n' +
      'gh attestation verify ~/Downloads/Second-Wind-0.3.1-mac.zip --repo nicolasdmolina/codex-weekly-reset-guard',
  );
});
check('attestations follow the repo name at signing time', () => {
  const at = (file) => release.checkCommands({ file, url: '', sha256: '' }).split('\n')[1];
  assert.match(at('Second-Wind-0.4.4-mac.zip'), /--repo nicolasdmolina\/codex-weekly-reset-guard$/);
  assert.match(at('Second-Wind-0.4.5-mac.zip'), /--repo nicolasdmolina\/second-wind$/);
  assert.match(at('Second-Wind-0.10.0-mac.zip'), /--repo nicolasdmolina\/second-wind$/);
});
check('the fallback page follows each state', () => {
  assert.match(release.installNoscriptHtml(plan({ release: null })), /main\.zip/);
  assert.match(release.installNoscriptHtml(plan(sourceFixture)), /Second-Wind-0\.3\.0-source\.zip.*\n[\s\S]*1{64}/);
  const appHtml = release.installNoscriptHtml(plan(appFixture));
  assert.match(appHtml, /Second-Wind-0\.3\.1-mac\.zip[\s\S]*Open Anyway[\s\S]*2{64}/);
  assert.match(appHtml, /damaged[\s\S]*don’t open it/);
  assert.doesNotMatch(appHtml, /Apple has checked|notarized by Apple\./);
});
check('a source-only release never links an app', () => {
  for (const manifest of [{ release: null }, sourceFixture]) {
    assert.doesNotMatch(release.installNoscriptHtml(plan(manifest)), /-mac\.zip|\.dmg/);
  }
});

const mutations = {
  'a missing release key': (m) => delete m.release,
  'an extra field': (m) => (m.release.notes = 'unexpected'),
  'another repository': (m) => (m.release.repository = 'someone/else'),
  'a malformed tag': (m) => (m.release.tag = '0.2.0'),
  'a source file for another version': (m) => (m.release.source.file = 'Second-Wind-0.3.0-source.zip'),
  'a source folder for another version': (m) => (m.release.source.folder = 'second-wind-main'),
  'an uppercase checksum': (m) => (m.release.source.sha256 = 'A'.repeat(64)),
  'a short checksum': (m) => (m.release.app.sha256 = 'a'.repeat(63)),
  'an app file for another version': (m) => (m.release.app.file = 'Second-Wind-0.3.0-mac.zip'),
  'a disk image': (m) => (m.release.app.file = 'Second-Wind-0.3.1.dmg'),
  'no architectures': (m) => (m.release.app.architectures = []),
  'a single architecture': (m) => (m.release.app.architectures = ['arm64']),
  'a repeated architecture': (m) => (m.release.app.architectures = ['arm64', 'arm64']),
  'an unknown architecture': (m) => (m.release.app.architectures = ['arm64', 'ppc']),
  'a malformed minimum macOS': (m) => (m.release.app.minimumSystemVersion = 'Sonoma'),
  'another minimum macOS': (m) => (m.release.app.minimumSystemVersion = '13.0'),
  'Developer ID signing': (m) => (m.release.app.signing = 'developer-id'),
  'a team ID': (m) => (m.release.app.teamId = 'ABCDE12345'),
  'a missing app field': (m) => delete m.release.app.signing,
};
for (const [label, mutate] of Object.entries(mutations)) {
  check(`rejects ${label}`, () => {
    const manifest = structuredClone(appFixture);
    mutate(manifest);
    assert.throws(() => release.parseReleaseManifest(manifest), /site\/src\/release\.json: /);
  });
}
console.log(`All ${count} release manifest checks passed.`);
