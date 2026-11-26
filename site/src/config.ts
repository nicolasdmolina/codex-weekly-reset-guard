// The one place the repository lives. Update it here if the repo is renamed.
export const REPOSITORY = 'nicolasdmolina/codex-weekly-reset-guard';
export const REPO_URL = `https://github.com/${REPOSITORY}`;

// Until src/release.json records a verified release, the site offers GitHub's archive
// of main, which unpacks to a folder named after the repo plus "-main".
export const SOURCE_ZIP_URL = `${REPO_URL}/archive/refs/heads/main.zip`;
export const SOURCE_FOLDER = 'codex-weekly-reset-guard-main';

export const README_INSTALL_URL = `${REPO_URL}#build-and-install`;
export const PRIVACY_URL = `${REPO_URL}/blob/main/docs/PRIVACY.md`;
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`;

export const CODEX_SETUP_URL = 'https://developers.openai.com/codex/quickstart';
export const CLAUDE_CODE_SETUP_URL = 'https://code.claude.com/docs/en/setup';

// Apple's guide to opening apps that aren't notarized (System Settings > Privacy & Security).
export const APPLE_OPEN_APPS_URL = 'https://support.apple.com/en-us/102445';
