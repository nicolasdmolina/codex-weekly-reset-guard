import { defineConfig, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import manifest from './src/release.json' with { type: 'json' };
import qaApp from './scripts/qa-release-app.json' with { type: 'json' };
import qaSource from './scripts/qa-release-source.json' with { type: 'json' };
import { installNoscriptHtml, parseReleaseManifest, planInstall, type InstallPlan } from './src/release.ts';

// `vite build --mode qa-source` or `--mode qa-app` renders a synthetic verified
// release so QA covers every install state. Other modes use src/release.json.
const QA_MANIFESTS = new Map<string, unknown>([
  ['qa-source', qaSource],
  ['qa-app', qaApp],
]);
const PLACEHOLDER = '<!-- install-steps -->';

function noscriptInstall(plan: InstallPlan): Plugin {
  return {
    name: 'second-wind-noscript-install',
    transformIndexHtml(html) {
      if (!html.includes(PLACEHOLDER)) throw new Error(`index.html is missing ${PLACEHOLDER}`);
      return html.replace(PLACEHOLDER, installNoscriptHtml(plan));
    },
  };
}

// Relative base so the build works at a GitHub Pages project path
// (https://<user>.github.io/<repo>/) and at a custom domain root.
export default defineConfig(({ mode }) => {
  const release = QA_MANIFESTS.get(mode) ?? manifest;
  const plan = planInstall(parseReleaseManifest(release));
  return {
    base: './',
    build: { license: { fileName: 'dependency-licenses.txt' } },
    define: { __SECOND_WIND_RELEASE__: JSON.stringify(release) },
    plugins: [react(), noscriptInstall(plan)],
  };
});
