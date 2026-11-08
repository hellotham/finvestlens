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
  version: '1.3',
  /** The date this version was released: the disk image's, until the App
   *  Store's own date (`releaseDate` in its record) replaces it. */
  released: '8 November 2026',
  /** Every system this version runs on, in words. */
  platforms: 'Mac, iPhone and iPad',
  /** The same, for the structured data. `minimumOsVersion` in the App Store record. */
  operatingSystem: 'macOS 27, iOS 27, iPadOS 27',
  /** One record for every platform (universal purchase). No storefront in the
   *  link, so Apple sends each reader to their own. */
  appStore: 'https://apps.apple.com/app/finvestlens/id6821468191',
  appStoreRequirements: 'macOS 27, iOS 27 or iPadOS 27, or later',
  /** Signed with Developer ID and notarized by Apple. */
  file: 'FinvestLens-1.3.dmg',
  sizeLabel: '18 MB',
  sha256: 'a37505b69213d02e5acdc473360f20e2c71e637c084db66bee6ed28fd4ca705f',
  /** Release assets live on GitHub, not in this repository. The file itself,
   *  by version, so the hash above always describes what the button downloads
   *  — `releases/latest` moved on before the page did. */
  url: 'https://github.com/hellotham/finvestlens/releases/download/v1.3/FinvestLens-1.3.dmg',
  notes: 'https://github.com/hellotham/finvestlens/releases/tag/v1.3',
  /** What the file above needs — not what the source tree builds for: read from
   *  the file (`LSMinimumSystemVersion`, `lipo -archs`). This line moves in the
   *  same change as `version`, `file` and `sha256`. */
  requirements: 'macOS 27 or later · Apple silicon',
  signedBy: 'Developer ID Application: Hello Tham Pty. Ltd. (RPL5R637DS)',
  /** The last release for older systems, which stays on GitHub. */
  previous: {
    version: '1.1',
    url: 'https://github.com/hellotham/finvestlens/releases/tag/v1.1',
    requirements: 'macOS 26.5 or later, on Apple silicon or Intel',
  },
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
