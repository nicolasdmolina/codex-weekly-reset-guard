// Real native renders of the 380 x 560 pt popover at 2x.
export const SCREEN_WIDTH = 760;
export const SCREEN_HEIGHT = 1120;

export type Screen = {
  id: string;
  src: string;
  tab: string;
  caption: string;
  alt: string;
};

export const screens: Screen[] = [
  {
    id: 'overview',
    src: './screens/overview.png',
    tab: 'All clear',
    caption: 'A Codex and a Claude account, both healthy.',
    alt: 'Second Wind popover: a Codex account with 61% of its week left and auto-redeem on, and a Claude Max account at 42% of its 5-hour limit with reset times.',
  },
  {
    id: 'near',
    src: './screens/near.png',
    tab: 'Codex low',
    caption: 'Codex at 2%. It checks twice before it redeems.',
    alt: 'Second Wind popover: a Codex account at 2% weekly, confirming the limit with reading 1 of 2, checking again in 5 seconds. A second account is at 58%.',
  },
  {
    id: 'claude-low',
    src: './screens/claude-low.png',
    tab: 'Claude low',
    caption: 'Claude at 7%. One click opens your reset in Claude.',
    alt: 'Second Wind popover: a Claude Max account at 7% of its weekly limit with a Use a reset button, and a healthy Codex account at 58%.',
  },
];

export const onboardingScreen = {
  src: './screens/onboarding.png',
  alt: 'Second Wind first-run screen: choose Codex or Claude, enter the account email and an optional name, then add the account.',
};
