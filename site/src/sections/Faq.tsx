import { Collapsible, CollapsibleGroup } from '@astryxdesign/core/Collapsible';
import { Heading } from '@astryxdesign/core/Heading';
import { Text } from '@astryxdesign/core/Text';
import { INSTALL } from '../install';

const questions = [
  {
    q: 'Will a reset always be there when I need one?',
    a: 'No. Second Wind doesn’t give or buy resets. It only uses ones your account already has, and that depends on your plan and app versions.',
  },
  {
    q: 'Can it promise I never run out?',
    a: 'No. It checks Codex every minute and Claude every 5 minutes, and only while the app is open and your Mac is awake and online. Auto-redeem waits until 3%, so up to 3% of a week can go unused.',
  },
  {
    q: 'Will it sign me out of Codex or Claude Code?',
    a: 'No. Every account it watches has its own folder, separate from your normal sign-in.',
  },
  {
    q: 'I use Codex Weekly Reset Guard. What happens?',
    a:
      INSTALL.kind === 'app'
        ? 'That was this app’s old name. Quit it and move it to the Trash, then install Second Wind as above. Your accounts and any pending reset move over the first time Second Wind opens.'
        : 'That was this app’s old name. Quit it, then install Second Wind. The installer moves the old app aside, and your accounts and any pending reset move over the first time Second Wind opens.',
  },
  ...(INSTALL.kind === 'app'
    ? [
        {
          q: 'Why does macOS warn me the first time I open it?',
          a: 'Apple hasn’t notarized Second Wind, so macOS may ask you to approve it in System Settings under Privacy & Security. The checksum and GitHub’s build record let you confirm the download came from the public source.',
        },
      ]
    : []),
  {
    q: 'Which Codex versions work?',
    a: 'It was tested with Codex CLI 0.145.0 and 0.153.4. If a version is missing something it needs, it won’t redeem.',
  },
];

export function Faq() {
  return (
    <section className="section" id="faq" aria-labelledby="faq-title">
      <div className="container faq">
        <Heading level={2} className="section__title">
          <span id="faq-title">Questions</span>
        </Heading>
        <CollapsibleGroup type="multiple" hasDividers className="faq__list">
          {questions.map((item) => (
            <Collapsible
              key={item.q}
              value={item.q}
              trigger={<span className="faq__q">{item.q}</span>}
            >
              <Text as="p" color="secondary" className="faq__a">
                {item.a}
              </Text>
            </Collapsible>
          ))}
        </CollapsibleGroup>
      </div>
    </section>
  );
}
