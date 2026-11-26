import { Button } from '@astryxdesign/core/Button';
import { CodeBlock } from '@astryxdesign/core/CodeBlock';
import { Heading } from '@astryxdesign/core/Heading';
import { Link } from '@astryxdesign/core/Link';
import { Text } from '@astryxdesign/core/Text';
import { Download } from '../components/icons';
import { SCREEN_HEIGHT, SCREEN_WIDTH, onboardingScreen } from '../components/screens';
import {
  CLAUDE_CODE_SETUP_URL,
  CODEX_SETUP_URL,
  README_INSTALL_URL,
  SOURCE_FOLDER,
  SOURCE_ZIP_URL,
} from '../config';

// install_app.sh builds and packages the app itself, and --launch opens it only
// after the new copy is installed and its signature checks out.
const commands = [`cd ~/Downloads/${SOURCE_FOLDER}`, './scripts/install_app.sh --launch'].join('\n');

export function Install() {
  return (
    <section className="section" id="install" aria-labelledby="install-title">
      <div className="container install">
        <div className="install__main">
          <Heading level={2} className="section__title">
            <span id="install-title">Install from source</span>
          </Heading>
          <Text as="p" color="secondary" className="prose">
            There&rsquo;s no signed, ready-made download yet. You get the source and your Mac
            builds the app with one command.
          </Text>

          <Heading level={3} className="install__subtitle">
            You need
          </Heading>
          <ul className="needs">
            <li>macOS 14 or later.</li>
            <li>
              Swift 6 or later, from Xcode or Apple&rsquo;s Command Line Tools. Run{' '}
              <code>swift --version</code> to check.
            </li>
            <li>
              The official{' '}
              <Link href={CODEX_SETUP_URL} isExternalLink>
                Codex CLI or app
              </Link>
              ,{' '}
              <Link href={CLAUDE_CODE_SETUP_URL} isExternalLink>
                Claude Code
              </Link>
              , or both.
            </li>
          </ul>

          <ol className="flow">
            <li className="flow__step">
              <Heading level={3} className="flow__title">
                Download the source
              </Heading>
              <div className="flow__action">
                <Button
                  href={SOURCE_ZIP_URL}
                  label="Download source (.zip)"
                  variant="primary"
                  icon={<Download />}
                />
              </div>
              <Text as="p" color="secondary" className="prose">
                Open the ZIP. You get a folder named <code>{SOURCE_FOLDER}</code>.
              </Text>
            </li>
            <li className="flow__step">
              <Heading level={3} className="flow__title">
                Build and install
              </Heading>
              <Text as="p" color="secondary" className="prose">
                Open Terminal and paste these two lines:
              </Text>
              <div className="flow__code">
                <CodeBlock code={commands} language="bash" title="Terminal" hasCopyButton isWrapped />
              </div>
              <Text as="p" color="secondary" className="prose">
                If the folder isn&rsquo;t in Downloads, type <code>cd</code> and a space, drag the
                folder into Terminal and press Return, then run the second line. Quit Second Wind or
                Codex Weekly Reset Guard first if either is running.
              </Text>
            </li>
            <li className="flow__step">
              <Heading level={3} className="flow__title">
                Add an account
              </Heading>
              <Text as="p" color="secondary" className="prose">
                The app opens as a wind symbol in your menu bar. Pick Codex or Claude, enter the
                account&rsquo;s email and sign in through your browser. Launch at login is in the
                &bull;&bull;&bull; menu.
              </Text>
            </li>
          </ol>

          <Text as="p" color="secondary" size="sm" className="install__foot">
            The app goes in the Applications folder inside your home folder. It isn&rsquo;t
            notarized by Apple. Prefer <code>git clone</code>? The{' '}
            <Link href={README_INSTALL_URL} isExternalLink>
              README
            </Link>{' '}
            has the full steps.
          </Text>
        </div>
        <figure className="install__shot">
          <div className="shot">
            <img
              src={onboardingScreen.src}
              width={SCREEN_WIDTH}
              height={SCREEN_HEIGHT}
              alt={onboardingScreen.alt}
              loading="lazy"
              decoding="async"
            />
          </div>
          <figcaption className="showcase__caption">The first thing you see after install.</figcaption>
        </figure>
      </div>
    </section>
  );
}
