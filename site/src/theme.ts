import { defineTheme } from '@astryxdesign/core/theme';

// Brand tokens shared with the native app. Tuples are [light, dark].
// Amber and coral are status colours only (near limit, attention).
export const secondWindTheme = defineTheme({
  name: 'second-wind',
  typography: {
    scale: { base: 16, ratio: 1.2 },
    body: {
      family: 'Schibsted Grotesk Variable',
      fallbacks: '-apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif',
      weight: 'normal',
    },
    heading: { weight: 'bold' },
    code: {
      family: 'ui-monospace',
      fallbacks: '"SF Mono", Menlo, monospace',
    },
  },
  tokens: {
    '--color-background-body': ['#FAFAF9', '#1B1B1B'],
    '--color-background-surface': ['#FFFFFF', '#262626'],
    '--color-background-card': ['#FFFFFF', '#262626'],
    '--color-background-muted': ['#F1F1EF', '#222222'],
    '--color-background-popover': ['#FFFFFF', '#2B2B2B'],
    '--color-text-primary': ['#161616', '#FAFAFA'],
    '--color-text-secondary': ['#4B4B4B', '#D4D4D4'],
    '--color-text-accent': ['#0A7568', '#3FD9C3'],
    '--color-icon-primary': ['#161616', '#FAFAFA'],
    '--color-icon-secondary': ['#4B4B4B', '#D4D4D4'],
    '--color-icon-accent': ['#0A7568', '#3FD9C3'],
    '--color-accent': ['#0E9F8E', '#3FD9C3'],
    '--color-accent-muted': ['#DDF3EF', '#173A35'],
    '--color-on-accent': ['#04201C', '#0B2622'],
    '--color-border': ['#E3E3E0', '#333333'],
    '--color-border-emphasized': ['#CFCFCB', '#474747'],
    '--color-warning': '#E0A53B',
    '--color-error': '#F0715F',
    '--radius-element': '10px',
    '--radius-container': '16px',
  },
  components: {
    button: {
      base: { fontWeight: '600', letterSpacing: '-0.005em' },
    },
  },
});
