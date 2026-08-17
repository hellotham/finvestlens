/**
 * Single source of truth for everything the site says about itself: the
 * publisher, the current release, and the navigation. Pages import from here
 * so a version bump or a moved link is one edit, not twenty.
 */

export const site = {
  name: 'FinvestLens',
  tagline: 'Double-entry accounting that belongs on a Mac.',
  description:
    'A native Apple double-entry accounting app for macOS, iPadOS and iOS — ' +
    'the rigour of GnuCash, rebuilt in Swift, with your book kept in a single ' +
    'file you own.',
  repo: 'https://github.com/hellotham/finvestlens',
  publisher: {
    name: 'Hello Tham',
    legalName: 'Hello Tham Pty Ltd',
    url: 'https://hellotham.com',
    tagline: 'Visualise Your Future',
  },
  contact: {
    // Support and privacy contact. App Store review requires a reachable one.
    email: 'finvestlens@hellotham.com',
    issues: 'https://github.com/hellotham/finvestlens/issues',
  },
} as const;

export const release = {
  version: '1.1',
  /** Signed with Developer ID and notarized by Apple. */
  file: 'FinvestLens-1.1.dmg',
  sizeLabel: '15 MB',
  sha256: '477d4ccd7bf024f463f083835496f8fd1744ba6eee7793fd788befde069d92d9',
  /** Release assets live on GitHub, not in this repository. */
  url: 'https://github.com/hellotham/finvestlens/releases/latest',
  requirements: 'macOS 26 or later · Apple silicon and Intel',
  signedBy: 'Developer ID Application: Hello Tham Pty. Ltd. (RPL5R637DS)',
} as const;

export const nav = [
  { label: 'Features', href: '/features/' },
  { label: 'Manual', href: '/manual/' },
  { label: 'Download', href: '/download/' },
  { label: 'About', href: '/about/' },
] as const;

export const footerNav = [
  {
    heading: 'Product',
    links: [
      { label: 'Features', href: '/features/' },
      { label: 'Download', href: '/download/' },
      { label: 'Release notes', href: '/download/#whats-new' },
    ],
  },
  {
    heading: 'Learn',
    links: [
      { label: 'User manual', href: '/manual/' },
      { label: 'Command line', href: '/manual/interchange/' },
      { label: 'Support', href: '/support/' },
    ],
  },
  {
    heading: 'Legal',
    links: [
      { label: 'Privacy', href: '/privacy/' },
      { label: 'About', href: '/about/' },
      { label: 'Licence', href: '/about/#licence' },
    ],
  },
] as const;

/**
 * Prefixes a site-root path with Astro's configured `base`, so links keep
 * working under the GitHub Pages project path. Always use this for internal
 * hrefs and asset paths.
 */
export function url(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, '');
  const clean = path.startsWith('/') ? path : `/${path}`;
  return `${base}${clean}`;
}
