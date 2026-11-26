import { parseReleaseManifest, planInstall } from './release';

// vite.config.ts injects the release manifest at build time and validates it first.
declare const __SECOND_WIND_RELEASE__: unknown;

export const INSTALL = planInstall(parseReleaseManifest(__SECOND_WIND_RELEASE__));
