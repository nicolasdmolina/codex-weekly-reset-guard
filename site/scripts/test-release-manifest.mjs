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
const downloads = 'https://github.com/nicolasdmolina/codex-weekly-reset-guard/releases/download/v0.3.0';
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
  assert.equal(source.release.source.url, `${downloads}/Second-Wind-0.3.0-source.zip`);
  assert.equal(source.release.source.folder, 'Second-Wind-0.3.0');
});
check('an app release offers the disk image', () => {
  const app = plan(appFixture);
  assert.equal(app.kind, 'app');
  assert.equal(app.app.url, `${downloads}/Second-Wind-0.3.0.dmg`);
  assert.equal(release.macRequirement(app.app), 'any Mac with macOS 14 or later');
  assert.equal(
    release.checkCommands(app.app),
    'shasum -a 256 ~/Downloads/Second-Wind-0.3.0.dmg\n' +
      'gh attestation verify ~/Downloads/Second-Wind-0.3.0.dmg --repo nicolasdmolina/codex-weekly-reset-guard',
  );
});
check('an Apple silicon build is labelled as such', () => {
  const manifest = structuredClone(appFixture);
  manifest.release.app.architectures = ['arm64'];
  assert.equal(release.macRequirement(plan(manifest).app), 'a Mac with Apple silicon and macOS 14 or later');
});
check('the fallback page follows each state', () => {
  assert.match(release.installNoscriptHtml(plan({ release: null })), /main\.zip/);
  assert.match(release.installNoscriptHtml(plan(sourceFixture)), /Second-Wind-0\.3\.0-source\.zip.*\n[\s\S]*1{64}/);
  assert.match(release.installNoscriptHtml(plan(appFixture)), /Second-Wind-0\.3\.0\.dmg[\s\S]*2{64}/);
});

const mutations = {
  'a missing release key': (m) => delete m.release,
  'an extra field': (m) => (m.release.notes = 'unexpected'),
  'another repository': (m) => (m.release.repository = 'someone/else'),
  'a malformed tag': (m) => (m.release.tag = '0.2.0'),
  'a source file for another version': (m) => (m.release.source.file = 'Second-Wind-0.2.1-source.zip'),
  'a source folder for another version': (m) => (m.release.source.folder = 'second-wind-main'),
  'an uppercase checksum': (m) => (m.release.source.sha256 = 'A'.repeat(64)),
  'a short checksum': (m) => (m.release.app.sha256 = 'a'.repeat(63)),
  'an app file for another version': (m) => (m.release.app.file = 'Second-Wind-0.1.0.dmg'),
  'no architectures': (m) => (m.release.app.architectures = []),
  'a repeated architecture': (m) => (m.release.app.architectures = ['arm64', 'arm64']),
  'an unknown architecture': (m) => (m.release.app.architectures = ['ppc']),
  'a malformed minimum macOS': (m) => (m.release.app.minimumSystemVersion = 'Sonoma'),
  'a malformed team ID': (m) => (m.release.app.teamId = 'abcde12345'),
  'a missing app field': (m) => delete m.release.app.teamId,
};
for (const [label, mutate] of Object.entries(mutations)) {
  check(`rejects ${label}`, () => {
    const manifest = structuredClone(appFixture);
    mutate(manifest);
    assert.throws(() => release.parseReleaseManifest(manifest), /site\/src\/release\.json: /);
  });
}
console.log(`All ${count} release manifest checks passed.`);
