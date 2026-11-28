import { Button } from '@astryxdesign/core/Button';
import { CodeBlock } from '@astryxdesign/core/CodeBlock';
import { Collapsible } from '@astryxdesign/core/Collapsible';
import { Heading } from '@astryxdesign/core/Heading';
import { Link } from '@astryxdesign/core/Link';
import { Text } from '@astryxdesign/core/Text';
import { Download } from '../components/icons';
import { SCREEN_HEIGHT, SCREEN_WIDTH, onboardingScreen } from '../components/screens';
import {
  ANTIGRAVITY_CLI_SETUP_URL,
  APPLE_OPEN_APPS_URL,
  CLAUDE_CODE_SETUP_URL,
  CODEX_SETUP_URL,
  README_INSTALL_URL,
} from '../config';
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
      The official tool for each service you use: the{' '}
      <Link href={CODEX_SETUP_URL} isExternalLink>
        Codex CLI or app
      </Link>
      ,{' '}
      <Link href={CLAUDE_CODE_SETUP_URL} isExternalLink>
        Claude Code
      </Link>
      , or the{' '}
      <Link href={ANTIGRAVITY_CLI_SETUP_URL} isExternalLink>
        Antigravity CLI
      </Link>
      .
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
        {opening} Pick Codex or Claude and sign in through your browser. Pick Antigravity to
        follow the account signed in to its CLI; open <code>agy</code> and sign in once first.
        Launch at login is in the &bull;&bull;&bull; menu.
      </Text>
    </li>
  );
}

function CheckDownload({ download, isApp }: { download: VerifiedDownload; isApp: boolean }) {
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
          CLI and confirms GitHub built this file from the project&rsquo;s public source.
          {isApp &&
            ' Together they show you have the right file. They aren’t a review by Apple, which hasn’t notarized Second Wind.'}
        </Text>
        <CodeBlock code={checkCommands(download)} language="bash" title="Terminal" hasCopyButton isWrapped />
        {isApp && (
          <Text as="p" color="secondary" className="prose">
            If Safari unzipped it for you, the ZIP may be in the Trash. Drag it back to Downloads
            first.
          </Text>
        )}
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
          ? `There’s no ready-made app for version ${release.version}. Download its source and your Mac builds the app with one command.`
          : 'There’s no ready-made download yet. You get the source and your Mac builds the app with one command.'}
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

      {release && <CheckDownload download={release.source} isApp={false} />}

      <Text as="p" color="secondary" size="sm" className="install__foot">
        The app goes in the Applications folder inside your home folder. It isn&rsquo;t
        notarized by Apple. Prefer <code>git clone</code>? The{' '}
        <Link href={README_INSTALL_URL} isExternalLink size="sm">
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
        Version {release.version}. Apple hasn&rsquo;t notarized Second Wind, so macOS may ask
        you to approve it the first time you open it.
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
            <Button href={app.url} label="Download for Mac (.zip)" variant="primary" icon={<Download />} />
            <Button href={release.source.url} label="Source code (.zip)" variant="secondary" />
          </div>
          <Text as="p" color="secondary" className="prose">
            If Safari doesn&rsquo;t unzip it, double-click the ZIP in Finder.
          </Text>
        </li>
        <li className="flow__step">
          <Heading level={3} className="flow__title">
            Move it to Applications
          </Heading>
          <Text as="p" color="secondary" className="prose">
            In Finder, drag Second Wind from Downloads onto the Applications folder.
          </Text>
          <Text as="p" color="secondary" className="prose">
            Updating? Choose Quit Second Wind from the &bull;&bull;&bull; menu, then drag the new
            copy into the folder holding your existing app and choose Replace. If you built it
            from source, that folder is usually Applications inside your home folder. Your accounts stay.
          </Text>
        </li>
        <li className="flow__step">
          <Heading level={3} className="flow__title">
            Open it
          </Heading>
          <Text as="p" color="secondary" className="prose">
            Double-click Second Wind in Applications. If macOS says it can&rsquo;t verify the
            developer or check the app for malware, close that message and follow these steps.
          </Text>
          <ol className="substeps">
            <li>Open System Settings and click Privacy &amp; Security.</li>
            <li>Scroll down and click Open Anyway next to the note about Second Wind.</li>
            <li>Click Open. Your Mac may ask for your password.</li>
          </ol>
          <Text as="p" color="secondary" className="prose">
            This is{' '}
            <Link href={APPLE_OPEN_APPS_URL} isExternalLink>
              Apple&rsquo;s own way
            </Link>{' '}
            to open one app you trust. On a Mac managed by a school or company, Open Anyway may be
            blocked.
          </Text>
          <Text as="p" className="prose install__warning">
            If macOS says Second Wind is damaged, will damage your computer or contains malware,
            don&rsquo;t open it. Move that copy to the Trash.
          </Text>
        </li>
        <AccountStep opening="A wind symbol appears in your menu bar." />
      </ol>

      <CheckDownload download={app} isApp />

      <Text as="p" color="secondary" size="sm" className="install__foot">
        Prefer to build it yourself? Open Terminal in the source folder and run{' '}
        <code>./scripts/install_app.sh --launch</code>. You need Swift 6. The{' '}
        <Link href={README_INSTALL_URL} isExternalLink size="sm">
          README
        </Link>{' '}
        has the full steps.
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
