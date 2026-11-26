import { Heading } from '@astryxdesign/core/Heading';
import { Text } from '@astryxdesign/core/Text';
import { Link } from '@astryxdesign/core/Link';
import { PRIVACY_URL } from '../config';

const facts = [
  {
    title: 'It signs in through the official tools.',
    body: 'Each account runs Codex or Claude Code in its own private folder, so your everyday sign-in stays as it is. It never calls private endpoints.',
  },
  {
    title: 'It never touches your tokens.',
    body: 'Second Wind never reads or copies your login tokens or the Keychain items that hold them. API keys in your shell are removed before it starts Codex or Claude Code.',
  },
  {
    title: 'No analytics and no server.',
    body: 'No tracking, no crash uploads, no backend of ours. Accounts and readings stay on your Mac. Codex and Claude Code still talk to OpenAI and Anthropic as they always do.',
  },
  {
    title: 'Nothing is on until you turn it on.',
    body: 'Auto-redeem starts off for every account, and so does launch at login.',
  },
];

export function Privacy() {
  return (
    <section className="section section--tinted" id="privacy" aria-labelledby="privacy-title">
      <div className="container">
        <header className="section__head">
          <Heading level={2} className="section__title" textWrap="balance">
            <span id="privacy-title">Your accounts stay yours</span>
          </Heading>
        </header>
        <dl className="facts">
          {facts.map((fact) => (
            <div key={fact.title} className="facts__item">
              <dt className="facts__title">{fact.title}</dt>
              <dd className="facts__body">{fact.body}</dd>
            </div>
          ))}
        </dl>
        <Text as="p" color="secondary" size="sm" className="section__foot">
          Where files live and how to remove them is in the{' '}
          <Link href={PRIVACY_URL} isExternalLink>
            privacy notes
          </Link>
          .
        </Text>
      </div>
    </section>
  );
}
