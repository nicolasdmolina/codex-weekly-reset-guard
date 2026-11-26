import { Button } from '@astryxdesign/core/Button';
import { Link } from '@astryxdesign/core/Link';
import { Wordmark } from '../components/Mark';
import { ArrowUpRight } from '../components/icons';
import { REPO_URL } from '../config';

const links = [
  { href: '#what-it-does', label: 'What it does' },
  { href: '#privacy', label: 'Privacy' },
  { href: '#install', label: 'Install' },
  { href: '#faq', label: 'FAQ' },
];

export function SiteHeader() {
  return (
    <header className="site-header">
      <div className="container site-header__inner">
        <a className="site-header__home" href="#top" aria-label="Second Wind, back to top">
          <Wordmark />
        </a>
        <nav aria-label="Sections" className="site-header__nav">
          {links.map((link) => (
            <Link key={link.href} href={link.href} color="secondary" size="sm" weight="medium">
              {link.label}
            </Link>
          ))}
        </nav>
        <Button
          href={REPO_URL}
          label="GitHub"
          variant="secondary"
          size="sm"
          endContent={<ArrowUpRight />}
        />
      </div>
    </header>
  );
}
