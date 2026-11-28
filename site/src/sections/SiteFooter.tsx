import { Link } from '@astryxdesign/core/Link';
import { Text } from '@astryxdesign/core/Text';
import { Wordmark } from '../components/Mark';
import { LICENSE_URL, PRIVACY_URL, REPO_URL } from '../config';

export function SiteFooter() {
  return (
    <footer className="site-footer">
      <div className="container site-footer__inner">
        <div className="site-footer__top">
          <Wordmark />
          <nav aria-label="Project" className="site-footer__links">
            <Link href={REPO_URL} color="secondary" size="sm">
              GitHub
            </Link>
            <Link href={PRIVACY_URL} color="secondary" size="sm">
              Privacy
            </Link>
            <Link href={LICENSE_URL} color="secondary" size="sm">
              MIT license
            </Link>
          </nav>
        </div>
        <Text as="p" size="sm" color="secondary" className="site-footer__legal">
          Second Wind is independent, open-source software. It is not made by, affiliated with or
          endorsed by OpenAI, Anthropic or Google. Codex and ChatGPT are OpenAI products. Claude and
          Claude Code are Anthropic products. Antigravity is a Google product. Copyright 2026 Nicky Molina, released under the MIT license.
        </Text>
      </div>
    </footer>
  );
}
