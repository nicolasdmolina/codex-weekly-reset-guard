import { Button } from '@astryxdesign/core/Button';
import { CodeBlock } from '@astryxdesign/core/CodeBlock';
import { Collapsible } from '@astryxdesign/core/Collapsible';
import { Heading } from '@astryxdesign/core/Heading';
import { Link } from '@astryxdesign/core/Link';
import { Text } from '@astryxdesign/core/Text';
import { Download } from '../components/icons';
import { SCREEN_HEIGHT, SCREEN_WIDTH, onboardingScreen } from '../components/screens';
import { CLAUDE_CODE_SETUP_URL, CODEX_SETUP_URL, README_INSTALL_URL } from '../config';
import { INSTALL } from '../install';
import { checkCommands, macRequirement, type InstallPlan, type VerifiedDownload } from '../release';

type SourcePlan = Extract<InstallPlan, { kind: 'main' | 'source' }>;
type AppPlan = Extract<InstallPlan, { kind: 'app' }>;

// install_app.sh builds and packages the app itself, and --launch opens it only
// after the new copy is installed and its signature checks out.
function buildCommands(folder: string): string {
  return [`cd ~/Downloads/${folder}`, './scripts/install_app.sh --launch'].join('\n');
}

function sentence(phrase: string): string {
  return `${phrase.charAt(0).toUpperCase()}${phrase.slice(1)}.`;
}

function Services() {
  return (
    <>
      The official{' '}
      <Link href={CODEX_SETUP_URL} isExternalLink>
        Codex CLI or app
      </Link>
      ,{' '}
      <Link href={CLAUDE_CODE_SETUP_URL} isExternalLink>
        Claude Code
      </Link>
      , or both.
    </>
  );
}

function Title({ children }: { children: string }) {
  return (
    <Heading level={2} className="section__title">
      <span id="install-title">{children}</span>
    </Heading>
  );
}

function AccountStep({ opening }: { opening: string }) {
  return (
    <li className="flow__step">
      <Heading level={3} className="flow__title">
        Add an account
      </Heading>
      <Text as="p" color="secondary" className="prose">
        {opening} Pick Codex or Claude, enter the account&rsquo;s email and sign in through your
        browser. Launch at login is in the &bull;&bull;&bull; menu.
      </Text>
    </li>
  );
}

function CheckDownload({ download }: { download: VerifiedDownload }) {
  return (
    <Collapsible
      className="check"
      defaultIsOpen={false}
      trigger={<span className="check__title">Check the download</span>}
    >
      <div className="check__body">
        <CodeBlock
          code={download.sha256}
          language="text"
          title="SHA-256"
          hasLanguageLabel={false}
          size="sm"
          hasCopyButton
          isWrapped
        />
        <Text as="p" color="secondary" className="prose">
          In Terminal, the first line below prints the same checksum. The second needs the GitHub
          CLI and confirms GitHub built this file from the project&rsquo;s source.
        </Text>
        <CodeBlock code={checkCommands(download)} language="bash" title="Terminal" hasCopyButton isWrapped />
      </div>
    </Collapsible>
  );
}

function sourceDownload(plan: SourcePlan) {
  return plan.kind === 'main'
    ? { url: plan.sourceUrl, folder: plan.folder, release: null }
    : { url: plan.release.source.url, folder: plan.release.source.folder, release: plan.release };
}

function SourceInstall({ plan }: { plan: SourcePlan }) {
  const { url, folder, release } = sourceDownload(plan);
  return (
    <>
      <Title>Install from source</Title>
      <Text as="p" color="secondary" className="prose">
        {release
          ? `There’s no ready-made app yet. Download the source for version ${release.version} and your Mac builds the app with one command.`
          : 'There’s no signed, ready-made download yet. You get the source and your Mac builds the app with one command.'}
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
          <Services />
        </li>
      </ul>

      <ol className="flow">
        <li className="flow__step">
          <Heading level={3} className="flow__title">
            Download the source
          </Heading>
          <div className="flow__action">
            <Button href={url} label="Download source (.zip)" variant="primary" icon={<Download />} />
          </div>
          <Text as="p" color="secondary" className="prose">
            Open the ZIP. You get a folder named <code>{folder}</code>.
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
            <CodeBlock code={buildCommands(folder)} language="bash" title="Terminal" hasCopyButton isWrapped />
          </div>
          <Text as="p" color="secondary" className="prose">
            If the folder isn&rsquo;t in Downloads, type <code>cd</code> and a space, drag the
            folder into Terminal and press Return, then run the second line. Quit Second Wind or
            Codex Weekly Reset Guard first if either is running.
          </Text>
        </li>
        <AccountStep opening="The app opens as a wind symbol in your menu bar." />
      </ol>

      {release && <CheckDownload download={release.source} />}

      <Text as="p" color="secondary" size="sm" className="install__foot">
        The app goes in the Applications folder inside your home folder. It isn&rsquo;t
        notarized by Apple. Prefer <code>git clone</code>? The{' '}
        <Link href={README_INSTALL_URL} isExternalLink>
          README
        </Link>{' '}
        has the full steps.
      </Text>
    </>
  );
}

function AppInstall({ plan }: { plan: AppPlan }) {
  const { app, release } = plan;
  return (
    <>
      <Title>Install</Title>
      <Text as="p" color="secondary" className="prose">
        Version {release.version}. Apple has checked it for malware, so it opens like any other
        app.
      </Text>

      <Heading level={3} className="install__subtitle">
        You need
      </Heading>
      <ul className="needs">
        <li>{sentence(macRequirement(app))}</li>
        <li>
          <Services />
        </li>
      </ul>

      <ol className="flow">
        <li className="flow__step">
          <Heading level={3} className="flow__title">
            Download the app
          </Heading>
          <div className="flow__action">
            <Button href={app.url} label="Download for Mac (.dmg)" variant="primary" icon={<Download />} />
          </div>
        </li>
        <li className="flow__step">
          <Heading level={3} className="flow__title">
            Drag it into Applications
          </Heading>
          <Text as="p" color="secondary" className="prose">
            Open the downloaded file and drag Second Wind onto the Applications folder.
          </Text>
          <Text as="p" color="secondary" className="prose">
            Built Second Wind from source before? Quit it, then move that copy from the
            Applications folder inside your home folder to the Trash. Your accounts stay.
          </Text>
        </li>
        <AccountStep opening="Open Second Wind from Applications. A wind symbol appears in your menu bar." />
      </ol>

      <CheckDownload download={app} />

      <Text as="p" color="secondary" size="sm" className="install__foot">
        Prefer to build it yourself?{' '}
        <Link href={release.source.url}>Download the source (.zip)</Link>, open Terminal in its
        folder and run <code>./scripts/install_app.sh --launch</code>. You need Swift 6.
      </Text>
    </>
  );
}

function InstallSteps({ plan }: { plan: InstallPlan }) {
  switch (plan.kind) {
    case 'main':
    case 'source':
      return <SourceInstall plan={plan} />;
    case 'app':
      return <AppInstall plan={plan} />;
    default: {
      const exhaustive: never = plan;
      return exhaustive;
    }
  }
}

export function Install() {
  return (
    <section className="section" id="install" aria-labelledby="install-title">
      <div className="container install">
        <div className="install__main">
          <InstallSteps plan={INSTALL} />
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
